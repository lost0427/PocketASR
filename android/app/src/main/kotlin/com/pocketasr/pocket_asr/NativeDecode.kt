package com.pocketasr.pocket_asr

import java.nio.ByteBuffer

/**
 * JNI bridge to `libpocketasr_decode` (native/decode).
 *
 * The library decodes mp3/wav/flac in-process with dr_libs and writes mono
 * 16 kHz float32 through the shared SpeexDSP resample + AGC chain. AAC/M4A and
 * any other format stay on MediaCodec and feed the same chain frame by frame
 * through [chainBegin]/[chainFeed]/[chainEnd], so every file leaves this class
 * at a consistent level without a second Dart pass.
 *
 * The library is Android-only and built by scripts/ci/build_native_android.sh;
 * when it is absent (unit tests, desktop) [available] is false and callers fall
 * back to MediaCodec.
 */
object NativeDecode {
    /** Decoder kinds accepted by [decodeFd]. */
    const val KIND_MP3 = 0
    const val KIND_WAV = 1
    const val KIND_FLAC = 2

    /** Sample formats accepted by [chainFeed]. */
    const val FMT_S16 = 0
    const val FMT_S32 = 1
    const val FMT_F32 = 2
    const val FMT_U8 = 3
    const val FMT_S24 = 4

    val available: Boolean = try {
        System.loadLibrary("pocketasr_decode")
        true
    } catch (_: Throwable) {
        false
    }

    /** Returns the emitted frame count, or a negative code on failure. */
    external fun decodeFd(
        fd: Int,
        kind: Int,
        outPath: String,
        targetRate: Int,
        agc: IntArray,
    ): Long

    external fun chainBegin(
        outPath: String,
        inRate: Int,
        channels: Int,
        targetRate: Int,
        agc: IntArray,
    ): Long

    external fun chainFeed(
        handle: Long,
        buffer: ByteBuffer,
        offset: Int,
        length: Int,
        fmt: Int,
    ): Int

    external fun chainEnd(handle: Long): Long

    external fun chainAbort(handle: Long)
}
