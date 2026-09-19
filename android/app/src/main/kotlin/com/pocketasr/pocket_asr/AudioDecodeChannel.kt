package com.pocketasr.pocket_asr

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.system.Os
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileDescriptor
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max

/**
 * Dart<->native audio decode boundary (`pocket_asr/audio_decode`).
 *
 * Method `decodeToPcm{path, targetSampleRate, decoderPreference,
 * outputDirectory}` accepts a local file path or a `content://` URI. The file
 * header is sniffed first: mp3/wav/flac are decoded in-process by
 * `libpocketasr_decode` (dr_libs), everything else by MediaExtractor +
 * MediaCodec. Both paths feed the shared SpeexDSP resample + AGC chain, which
 * writes little-endian float32 into a temp file in the job directory. Only
 * metadata crosses the channel; bulk PCM never does. On failure the temp file
 * is deleted and every native resource is released.
 */
class AudioDecodeChannel(
    messenger: BinaryMessenger,
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    companion object {
        /** Mirrors the Dart `audioDecodeChannel` constant. */
        const val NAME = "pocket_asr/audio_decode"

        private const val TIMEOUT_US = 10_000L

        // ~5 s of dequeue silence after all input is queued: a decoder that
        // never flags EOS must not spin forever.
        private const val MAX_IDLE_ROUNDS = 500

        // PocketAsrAgcConfig: target, max gain dB, rise dB/s, fall dB/s,
        // speech-gated, enabled.
        private val AGC = intArrayOf(8000, 24, 12, 40, 1, 1)
    }

    private val channel = MethodChannel(messenger, NAME)
    private val mainHandler = Handler(Looper.getMainLooper())

    // ponytail: one shared daemon thread; per-job threads only if the queue
    // ever needs concurrent decodes.
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "pocketasr-audio-decode").apply { isDaemon = true }
    }

    fun install() {
        channel.setMethodCallHandler(this)
    }

    fun shutdown() {
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "decodeToPcm") {
            result.notImplemented()
            return
        }
        val path = call.argument<String>("path")
        val targetRate = call.argument<Int>("targetSampleRate")
        val decoderPreference = call.argument<String>("decoderPreference") ?: "automatic"
        if (path.isNullOrBlank() || targetRate == null || targetRate <= 0) {
            result.error("bad_args", "path and positive targetSampleRate are required", null)
            return
        }
        executor.execute {
            try {
                val outputDirectory = call.argument<String>("outputDirectory")?.let { File(it) }
                    ?: context.cacheDir
                val root = context.applicationInfo.dataDir.let { File(it).canonicalFile }
                val directory = outputDirectory.canonicalFile
                if (!directory.isDirectory || !directory.path.startsWith(root.path + File.separator)) {
                    throw IOException("PCM output directory must be inside app storage")
                }
                val payload = decodeToTemp(path, targetRate, directory, decoderPreference)
                mainHandler.post { result.success(payload) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error("decode_failed", t.message ?: t.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun decodeToTemp(
        source: String,
        targetRate: Int,
        outputDirectory: File,
        decoderPreference: String,
    ): Map<String, Any> {
        val out = File.createTempFile("pocketasr_", ".f32", outputDirectory)
        var pfd: ParcelFileDescriptor? = null
        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        var chain = 0L
        var ok = false
        try {
            val descriptor = openSource(source)
            pfd = descriptor

            // In-process dr_libs decode for the formats it owns.
            val kind = sniff(descriptor.fileDescriptor)
            if (NativeDecode.available && kind >= 0) {
                val count = NativeDecode.decodeFd(
                    descriptor.fd, kind, out.absolutePath, targetRate, AGC,
                )
                if (count > 0) {
                    ok = true
                    val lib = nativeDecoderName(kind)
                    return payload(
                        out, targetRate, count, lib, "$lib + SpeexDSP AGC",
                        builtin = true, hardware = null, softwareOnly = null,
                    )
                }
                // Corrupt or unsupported despite the header: fall through to
                // MediaCodec rather than failing a decodable file.
                out.delete()
            }

            extractor = MediaExtractor()
            extractor.setDataSource(descriptor.fileDescriptor)
            val track = selectAudioTrack(extractor)
            val trackFormat = extractor.getTrackFormat(track)
            val mime = trackFormat.getString(MediaFormat.KEY_MIME)
                ?: throw IOException("Audio track has no mime type")
            val inRate = trackFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channels = max(1, trackFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
            if (inRate <= 0) throw IOException("Invalid source sample rate $inRate")

            codec = openDecoder(mime, trackFormat, decoderPreference)
            chain = NativeDecode.chainBegin(out.absolutePath, inRate, channels, targetRate, AGC)
            if (chain <= 0) throw IOException("Audio decode chain unavailable")

            var pcmEncoding = sourcePcmEncoding(mime, trackFormat)
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var idle = 0
            var framesSeen = 0L

            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(0L)
                    if (inIndex >= 0) {
                        val ib = codec.getInputBuffer(inIndex)
                            ?: throw IOException("Decoder lost its input buffer")
                        val size = extractor.readSampleData(ib, 0)
                        if (size < 0) {
                            inputDone = true
                            codec.queueInputBuffer(
                                inIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                if (outIndex >= 0) {
                    idle = 0
                    if (info.size > 0) {
                        val ob = codec.getOutputBuffer(outIndex)
                            ?: throw IOException("Decoder lost its output buffer")
                        val rc = NativeDecode.chainFeed(
                            chain, ob, info.offset, info.size, fmtOf(pcmEncoding),
                        )
                        if (rc != 0) throw IOException("Audio decode chain rejected PCM")
                        framesSeen += info.size
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                    }
                } else when (outIndex) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                        pcmEncoding = outputPcmEncoding(codec, pcmEncoding)
                    MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        idle += 1
                        if (inputDone && idle > MAX_IDLE_ROUNDS) {
                            if (framesSeen == 0L) throw IOException("Decoder produced no audio")
                            outputDone = true // hang guard: end early, keep what decoded
                        }
                    }
                    else -> Unit
                }
            }

            val count = NativeDecode.chainEnd(chain)
            chain = 0
            if (count <= 0) throw IOException("Decoder produced no audio")
            ok = true
            val info2 = codec.codecInfo
            return payload(
                out, targetRate, count, "MediaCodec",
                "${info2.name} + SpeexDSP AGC", builtin = false,
                hardware = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    info2.isHardwareAccelerated
                } else null,
                softwareOnly = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    info2.isSoftwareOnly
                } else null,
            )
        } finally {
            if (!ok) out.delete()
            if (chain > 0) NativeDecode.chainAbort(chain)
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            runCatching { extractor?.release() }
            runCatching { pfd?.close() }
        }
    }

    private fun openSource(source: String): ParcelFileDescriptor {
        if (source.startsWith("content://")) {
            return context.contentResolver.openFileDescriptor(Uri.parse(source), "r")
                ?: throw FileNotFoundException("Cannot open $source")
        }
        val file = File(source)
        if (!file.isFile) throw FileNotFoundException("Audio file not found: $source")
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    /** Header sniff so dr_libs can own mp3/wav/flac without an extractor. */
    private fun sniff(fd: FileDescriptor): Int {
        val head = ByteArray(12)
        val n = try {
            Os.pread(fd, head, 0, head.size, 0)
        } catch (_: Exception) {
            return -1
        }
        if (n >= 3 && head[0].toInt() == 'I'.code && head[1].toInt() == 'D'.code &&
            head[2].toInt() == '3'.code
        ) {
            return NativeDecode.KIND_MP3
        }
        if (n >= 2 && (head[0].toInt() and 0xFF) == 0xFF &&
            (head[1].toInt() and 0xE0) == 0xE0
        ) {
            return NativeDecode.KIND_MP3
        }
        if (n >= 12 && head[0].toInt() == 'R'.code && head[1].toInt() == 'I'.code &&
            head[2].toInt() == 'F'.code && head[3].toInt() == 'F'.code &&
            head[8].toInt() == 'W'.code && head[9].toInt() == 'A'.code &&
            head[10].toInt() == 'V'.code && head[11].toInt() == 'E'.code
        ) {
            return NativeDecode.KIND_WAV
        }
        if (n >= 4 && head[0].toInt() == 'f'.code && head[1].toInt() == 'L'.code &&
            head[2].toInt() == 'a'.code && head[3].toInt() == 'C'.code
        ) {
            return NativeDecode.KIND_FLAC
        }
        return -1
    }

    private fun selectAudioTrack(extractor: MediaExtractor): Int {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: ""
            if (mime.startsWith("audio/")) {
                extractor.selectTrack(i)
                return i
            }
        }
        throw IOException("No audio track")
    }

    private fun nativeDecoderName(kind: Int): String = when (kind) {
        NativeDecode.KIND_MP3 -> "dr_mp3"
        NativeDecode.KIND_WAV -> "dr_wav"
        else -> "dr_flac"
    }

    private fun payload(
        out: File,
        rate: Int,
        count: Long,
        name: String,
        codecName: String,
        builtin: Boolean,
        hardware: Boolean?,
        softwareOnly: Boolean?,
    ): Map<String, Any> {
        val result = mutableMapOf<String, Any>(
            "path" to out.absolutePath,
            "sampleRate" to rate,
            "count" to count,
            "decoderName" to name,
            "codecName" to codecName,
            "decoderKind" to if (builtin) "builtin" else "mediacodec",
        )
        if (hardware != null) result["hardwareAccelerated"] = hardware
        if (softwareOnly != null) result["softwareOnly"] = softwareOnly
        return result
    }

    private fun fmtOf(encoding: Int): Int = when (encoding) {
        AudioFormat.ENCODING_PCM_32BIT -> NativeDecode.FMT_S32
        AudioFormat.ENCODING_PCM_FLOAT -> NativeDecode.FMT_F32
        AudioFormat.ENCODING_PCM_8BIT -> NativeDecode.FMT_U8
        AudioFormat.ENCODING_PCM_24BIT_PACKED -> NativeDecode.FMT_S24
        else -> NativeDecode.FMT_S16
    }

    /** Selects, configures and starts a decoder, falling back to system auto. */
    private fun openDecoder(
        mime: String,
        trackFormat: MediaFormat,
        preference: String,
    ): MediaCodec {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && preference != "automatic") {
            val preferHardware = preference == "preferHardware"
            val preferSoftware = preference == "preferSoftware"
            if (preferHardware || preferSoftware) {
                val codecs = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                    .asSequence()
                    .filter { !it.isEncoder && !it.isAlias }
                    .filter { info ->
                        info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
                    }
                    .filter { info ->
                        if (preferHardware) info.isHardwareAccelerated else info.isSoftwareOnly
                    }
                    .filter { info ->
                        runCatching {
                            info.getCapabilitiesForType(mime).isFormatSupported(trackFormat)
                        }.getOrDefault(false)
                    }
                for (info in codecs) {
                    try {
                        return startDecoder(MediaCodec.createByCodecName(info.name), trackFormat)
                    } catch (_: Exception) {
                        // Try the next matching implementation, then system auto.
                    }
                }
            }
        }
        return startDecoder(MediaCodec.createDecoderByType(mime), trackFormat)
    }

    private fun startDecoder(decoder: MediaCodec, trackFormat: MediaFormat): MediaCodec {
        try {
            decoder.configure(trackFormat, null, null, 0)
            decoder.start()
        } catch (e: Exception) {
            runCatching { decoder.release() }
            throw e
        }
        return decoder
    }

    private fun sourcePcmEncoding(mime: String, format: MediaFormat): Int {
        if (mime != MediaFormat.MIMETYPE_AUDIO_RAW) return AudioFormat.ENCODING_PCM_16BIT
        return try {
            format.getInteger(MediaFormat.KEY_PCM_ENCODING)
        } catch (e: Exception) {
            AudioFormat.ENCODING_PCM_16BIT
        }
    }

    /** Uses the codec's actual output encoding, defaulting to Android's PCM16 contract. */
    private fun outputPcmEncoding(codec: MediaCodec, fallback: Int): Int {
        val encoding = try {
            codec.outputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
        } catch (e: Exception) {
            return fallback
        }
        return if (encoding == AudioFormat.ENCODING_INVALID) fallback else encoding
    }
}
