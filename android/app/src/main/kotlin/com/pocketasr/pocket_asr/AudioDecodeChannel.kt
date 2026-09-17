package com.pocketasr.pocket_asr

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.max

/**
 * Dart<->native audio decode boundary (`pocket_asr/audio_decode`).
 *
 * Method `decodeToPcm{path, targetSampleRate}` accepts a local file path or
 * a `content://` URI and runs MediaExtractor + MediaCodec on a background
 * executor: decode (the linear PCM format reported by the codec),
 * mono downmix (mean, clamped), continuous linear resample to the target
 * rate, streaming into a little-endian float32 temp file in the app cache.
 * The reply is only `{path, sampleRate, count}` — bulk PCM never crosses
 * the channel. On any failure the temp file is deleted and the extractor,
 * descriptor and codec are released; Dart retains PCM on disk until job cleanup.
 *
 * Memory is per codec buffer, not per file: two hours of audio touches the
 * same few KB of decode scratch. The f32 temporary disk file grows with duration.
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
                val payload = decodeToTemp(path, targetRate, directory)
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
    ): Map<String, Any> {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var pfd: ParcelFileDescriptor? = null
        var sink: PcmSink? = null
        val out = File.createTempFile("pocketasr_", ".f32", outputDirectory)
        var ok = false
        try {
            if (source.startsWith("content://")) {
                val fd = context.contentResolver.openFileDescriptor(Uri.parse(source), "r")
                    ?: throw FileNotFoundException("Cannot open $source")
                pfd = fd
                extractor.setDataSource(fd.fileDescriptor)
            } else {
                if (!File(source).isFile) {
                    throw FileNotFoundException("Audio file not found: $source")
                }
                extractor.setDataSource(source)
            }

            var track = -1
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    track = i
                    break
                }
            }
            if (track < 0) throw IOException("No audio track in $source")
            extractor.selectTrack(track)

            val trackFormat = extractor.getTrackFormat(track)
            val mime = trackFormat.getString(MediaFormat.KEY_MIME)
                ?: throw IOException("Audio track has no mime type")
            val inRate = trackFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channels = max(1, trackFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
            if (inRate <= 0) throw IOException("Invalid source sample rate $inRate")

            val decoder = openDecoder(mime, trackFormat)
            codec = decoder
            decoder.start()
            var pcmEncoding = outputPcmEncoding(
                decoder,
                sourcePcmEncoding(mime, trackFormat),
            )

            val pcmSink = PcmSink(out)
            sink = pcmSink
            val resampler = StreamResampler(inRate, targetRate, pcmSink)
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var idle = 0
            var framesSeen = 0L

            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = decoder.dequeueInputBuffer(0L)
                    if (inIndex >= 0) {
                        val ib = decoder.getInputBuffer(inIndex)
                            ?: throw IOException("Decoder lost its input buffer")
                        val size = extractor.readSampleData(ib, 0)
                        if (size < 0) {
                            inputDone = true
                            decoder.queueInputBuffer(
                                inIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                            )
                        } else {
                            decoder.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = decoder.dequeueOutputBuffer(info, TIMEOUT_US)
                if (outIndex >= 0) {
                    idle = 0
                    if (info.size > 0) {
                        val ob = decoder.getOutputBuffer(outIndex)
                            ?: throw IOException("Decoder lost its output buffer")
                        ob.position(info.offset)
                        ob.limit(info.offset + info.size)
                        ob.order(ByteOrder.nativeOrder())
                        val frameBytes = bytesPerSample(pcmEncoding) * channels
                        if (info.size % frameBytes != 0) {
                            throw IOException("Decoder output is not aligned to PCM frames")
                        }
                        val frames = info.size / frameBytes
                        if (frames > 0) {
                            framesSeen += frames
                            resampler.feed(downmix(ob, frames, channels, pcmEncoding))
                        }
                    }
                    decoder.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                    }
                } else when (outIndex) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                        // Real decoders keep rate/channels stable; only the PCM
                        // encoding may become more specific once output starts.
                        pcmEncoding = outputPcmEncoding(decoder, pcmEncoding)
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

            resampler.finish(framesSeen)
            pcmSink.flush()
            val written = resampler.emitted
            if (out.length() != written * 4) {
                throw IOException("Temp file truncated: ${out.length()} bytes for $written frames")
            }
            ok = true
            return mapOf(
                "path" to out.absolutePath,
                "sampleRate" to targetRate,
                "count" to written,
            )
        } finally {
            if (!ok) runCatching { out.delete() }
            runCatching { sink?.close() }
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            runCatching { extractor.release() }
            runCatching { pfd?.close() }
        }
    }

    /** Configures the decoder without changing the extractor's source format. */
    private fun openDecoder(
        mime: String,
        trackFormat: MediaFormat,
    ): MediaCodec {
        val decoder = MediaCodec.createDecoderByType(mime)
        try {
            decoder.configure(trackFormat, null, null, 0)
        } catch (e: Exception) {
            runCatching { decoder.release() }
            throw e
        }
        return decoder
    }

    /** PCM decoders use this key for both input and output, so preserve the source value. */
    private fun sourcePcmEncoding(mime: String, format: MediaFormat): Int {
        if (mime != MediaFormat.MIMETYPE_AUDIO_RAW) return AudioFormat.ENCODING_PCM_16BIT
        return try {
            format.getInteger(MediaFormat.KEY_PCM_ENCODING)
        } catch (e: Exception) {
            AudioFormat.ENCODING_PCM_16BIT
        }.let(::normalizePcmEncoding)
    }

    /** Uses the codec's actual output encoding, defaulting to Android's PCM16 contract. */
    private fun outputPcmEncoding(codec: MediaCodec, fallback: Int): Int {
        val encoding = try {
            codec.outputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
        } catch (e: Exception) {
            return fallback
        }
        if (encoding == AudioFormat.ENCODING_INVALID) return fallback
        return normalizePcmEncoding(encoding)
    }

    private fun normalizePcmEncoding(encoding: Int): Int = when (encoding) {
        AudioFormat.ENCODING_INVALID,
        AudioFormat.ENCODING_DEFAULT -> AudioFormat.ENCODING_PCM_16BIT
        AudioFormat.ENCODING_PCM_8BIT,
        AudioFormat.ENCODING_PCM_16BIT,
        AudioFormat.ENCODING_PCM_FLOAT,
        AudioFormat.ENCODING_PCM_24BIT_PACKED,
        AudioFormat.ENCODING_PCM_32BIT -> encoding
        else -> throw IOException("Decoder output PCM encoding $encoding is not supported")
    }

    private fun bytesPerSample(encoding: Int): Int = when (encoding) {
        AudioFormat.ENCODING_PCM_8BIT -> 1
        AudioFormat.ENCODING_PCM_16BIT -> 2
        AudioFormat.ENCODING_PCM_24BIT_PACKED -> 3
        AudioFormat.ENCODING_PCM_FLOAT,
        AudioFormat.ENCODING_PCM_32BIT -> 4
        else -> throw IOException("Decoder output PCM encoding $encoding is not supported")
    }

    private fun readPcmSample(buf: ByteBuffer, encoding: Int): Float {
        val value = when (encoding) {
            AudioFormat.ENCODING_PCM_8BIT -> ((buf.get().toInt() and 0xff) - 128) / 128f
            AudioFormat.ENCODING_PCM_16BIT -> buf.short / 32768f
            AudioFormat.ENCODING_PCM_FLOAT -> buf.float
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> {
                val first = buf.get().toInt() and 0xff
                val middle = buf.get().toInt() and 0xff
                val last = buf.get().toInt() and 0xff
                val raw = if (buf.order() == ByteOrder.LITTLE_ENDIAN) {
                    first or (middle shl 8) or (last shl 16)
                } else {
                    (first shl 16) or (middle shl 8) or last
                }
                val signed = if (raw and 0x800000 != 0) raw - 0x1000000 else raw
                signed / 8388608f
            }
            AudioFormat.ENCODING_PCM_32BIT -> buf.int / 2147483648f
            else -> throw IOException("Decoder output PCM encoding $encoding is not supported")
        }
        if (!value.isFinite()) throw IOException("Decoder produced a non-finite PCM sample")
        return value
    }

    /** Channel-interleaved decoder output to clamped mono frames. */
    private fun downmix(
        buf: ByteBuffer,
        frames: Int,
        channels: Int,
        encoding: Int,
    ): FloatArray {
        val mono = FloatArray(frames)
        if (channels == 1) {
            for (f in 0 until frames) {
                mono[f] = readPcmSample(buf, encoding).coerceIn(-1f, 1f)
            }
            return mono
        }
        for (f in 0 until frames) {
            var sum = 0.0
            for (c in 0 until channels) {
                sum += readPcmSample(buf, encoding)
            }
            mono[f] = (sum / channels).coerceIn(-1.0, 1.0).toFloat()
        }
        return mono
    }

    /** Streams little-endian float32 frames to [file]; memory bounded per stage. */
    private class PcmSink(file: File) : Closeable {
        private val os = BufferedOutputStream(FileOutputStream(file))
        private val stage = FloatArray(8192)
        private val bytes = ByteBuffer.allocate(stage.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        private var fill = 0
        var written = 0L
            private set

        fun put(value: Float) {
            if (!value.isFinite()) throw IOException("Resampler produced a non-finite PCM sample")
            stage[fill++] = value
            if (fill == stage.size) flushStage()
        }

        fun flush() {
            flushStage()
            os.flush()
        }

        private fun flushStage() {
            if (fill == 0) return
            bytes.clear()
            bytes.asFloatBuffer().put(stage, 0, fill)
            os.write(bytes.array(), 0, fill * 4)
            written += fill
            fill = 0
        }

        override fun close() = os.close()
    }

    /**
     * Continuous linear resampler: the interpolation pair
     * (floor(pos), floor(pos)+1) may straddle successive codec buffers via
     * the retained [tail] frame, so output matches one-shot resampling of
     * the whole stream. Holds one chunk plus one frame of history, no
     * matter how long the file is. Index arithmetic assumes [feed] frames
     * arrive in increasing global order with no gaps.
     */
    private class StreamResampler(
        inRate: Int,
        outRate: Int,
        private val sink: PcmSink,
    ) {
        private val ratio = inRate.toDouble() / outRate
        private var base = 0L // global frame index of the current chunk's frame 0
        private var tail = 0f // last frame of the previous chunk
        private var haveTail = false
        var emitted = 0L
            private set

        fun feed(mono: FloatArray) {
            val end = base + mono.size
            while (true) {
                val pos = emitted * ratio
                val left = pos.toLong()
                if (left + 1 >= end) break // pair spans the chunk edge: next feed
                val a = if (left < base) tail else mono[(left - base).toInt()]
                val b = mono[(left + 1 - base).toInt()]
                sink.put(a + (b - a) * (pos - left).toFloat())
                emitted++
            }
            tail = mono[mono.size - 1]
            haveTail = true
            base = end
        }

        /** Emits the remainder with the last frame clamped, like the Dart WavDecoder. */
        fun finish(totalIn: Long) {
            if (!haveTail) return
            while (emitted * ratio < totalIn) {
                sink.put(tail)
                emitted++
            }
        }
    }
}
