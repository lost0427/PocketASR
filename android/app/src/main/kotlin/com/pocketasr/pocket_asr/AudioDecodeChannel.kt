package com.pocketasr.pocket_asr

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
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
 * executor: decode (PCM 16-bit or float output, whatever the codec reports),
 * mono downmix (mean, clamped), continuous linear resample to the target
 * rate, streaming into a little-endian float32 temp file in the app cache.
 * The reply is only `{path, sampleRate, count}` — bulk PCM never crosses
 * the channel. On any failure the temp file is deleted and the extractor,
 * descriptor and codec are released; Dart deletes the file after reading it.
 *
 * Memory is per codec buffer, not per file: two hours of audio touches the
 * same few KB of decode scratch (the full f32 temp file and the eventual
 * Dart-side Float32List are the O(duration) costs).
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
                val payload = decodeToTemp(path, targetRate)
                mainHandler.post { result.success(payload) }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error("decode_failed", t.message ?: t.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun decodeToTemp(source: String, targetRate: Int): Map<String, Any> {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var pfd: ParcelFileDescriptor? = null
        var sink: PcmSink? = null
        val out = File.createTempFile("pocketasr_", ".f32", context.cacheDir)
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

            val (decoder, floatRequested) = openDecoder(mime, trackFormat, inRate, channels)
            codec = decoder
            decoder.start()
            var useFloat = outputIsFloat(decoder, floatRequested)

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
                        val frameBytes = (if (useFloat) 4 else 2) * channels
                        val frames = info.size / frameBytes
                        if (frames > 0) {
                            framesSeen += frames
                            resampler.feed(downmix(ob, frames, channels, useFloat))
                        }
                    }
                    decoder.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                    }
                } else when (outIndex) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                        // Real decoders keep rate/channels stable; only the
                        // PCM encoding can differ from what was requested.
                        useFloat = outputIsFloat(decoder, useFloat)
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

    /** Returns the decoder and whether float output was successfully requested. */
    private fun openDecoder(
        mime: String,
        trackFormat: MediaFormat,
        rate: Int,
        channels: Int,
    ): Pair<MediaCodec, Boolean> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // createAudioFormat is API 29; below that we only configure from
            // the extractor's format and take whatever PCM the codec emits.
            var codec: MediaCodec? = null
            try {
                val requested = MediaFormat.createAudioFormat(mime, rate, channels).apply {
                    setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_FLOAT)
                }
                codec = MediaCodec.createDecoderByType(mime)
                codec.configure(requested, null, null, 0)
                return codec to true
            } catch (e: Exception) {
                runCatching { codec?.release() }
            }
        }
        val fallback = MediaCodec.createDecoderByType(mime)
        try {
            fallback.configure(trackFormat, null, null, 0)
        } catch (e: Exception) {
            runCatching { fallback.release() }
            throw e
        }
        return fallback to false
    }

    /** Trusts the codec's reported encoding; anything else is an honest failure. */
    private fun outputIsFloat(codec: MediaCodec, fallbackFloat: Boolean): Boolean {
        val encoding = try {
            codec.outputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
        } catch (e: Exception) {
            return fallbackFloat // Key absent: assume what was configured.
        }
        if (encoding == 0) return fallbackFloat // Some stacks report "unset" as 0.
        return when (encoding) {
            AudioFormat.ENCODING_PCM_FLOAT -> true
            AudioFormat.ENCODING_PCM_16BIT -> false
            else -> throw IOException("Decoder output PCM encoding $encoding is not supported")
        }
    }

    /** Channel-interleaved decoder output to clamped mono frames. */
    private fun downmix(
        buf: ByteBuffer,
        frames: Int,
        channels: Int,
        isFloat: Boolean,
    ): FloatArray {
        val mono = FloatArray(frames)
        if (channels == 1) {
            for (f in 0 until frames) {
                mono[f] = if (isFloat) buf.float else buf.short / 32768f
            }
            return mono
        }
        for (f in 0 until frames) {
            var sum = 0f
            for (c in 0 until channels) {
                sum += if (isFloat) buf.float else buf.short / 32768f
            }
            mono[f] = (sum / channels).coerceIn(-1f, 1f)
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
