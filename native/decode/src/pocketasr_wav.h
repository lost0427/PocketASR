/*
 * Canonical PCM16 WAV writer for the decode chain's float32 output.
 *
 * The Android chunk splitter calls this once per window: it concatenates the
 * window's sample ranges straight from the raw chain file into the mono WAV
 * the engines read. Doing it here avoids a per-sample pass in Dart for every
 * window (see pocketasr_chain.c for why the chain file itself is float32).
 */
#ifndef POCKETASR_WAV_H
#define POCKETASR_WAV_H

#include <stdint.h>

/*
 * Writes a canonical mono 16-bit WAV of the concatenated [starts[i], ends[i])
 * sample ranges of src_path, in order. src_fmt is a POCKETASR_FMT_* value;
 * only F32 and S16 are accepted. Spans are int64 so JNI can pass jlong
 * directly.
 *
 * Returns the number of samples written, or a negative POCKETASR_ERR_*.
 */
long pocketasr_write_wav(const char *src_path, const char *dst_path,
                         const int64_t *starts, const int64_t *ends, int count,
                         int src_fmt, int sample_rate);

#endif
