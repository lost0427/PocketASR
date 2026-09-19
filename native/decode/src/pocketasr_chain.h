/*
 * PocketASR decode chain: interleaved PCM -> mono -> SpeexDSP resample ->
 * SpeexDSP AGC -> little-endian float32 file.
 *
 * Pure C, no Android/FFI dependency, so the same code is used by the JNI
 * entry points. Frames stay 16-bit throughout; only the final file is float.
 * SpeexDSP is built floating point because its AGC is compiled out under
 * FIXED_POINT (see the "doesn't work yet with fixed-point" note upstream).
 */
#ifndef POCKETASR_CHAIN_H
#define POCKETASR_CHAIN_H

#include <stdint.h>

enum {
  POCKETASR_OK = 0,
  POCKETASR_ERR = -1,
  POCKETASR_ERR_IO = -2,
  POCKETASR_ERR_ARG = -3,
};

/*
 * A chain handle is an opaque pointer, not a signed number. Android's arm64
 * allocator (tagged pointers / MTE) returns addresses with bit 63 set, so a
 * live handle reads as a large negative value and a bare `handle > 0` test
 * rejects it. Only 0 and the small negative init-failure codes are invalid.
 */
#define POCKETASR_HANDLE_OK(h) \
  ((h) != 0 && ((intptr_t)(h) > 0 || (intptr_t)(h) < -(intptr_t)4096))

/* Interleaved input sample formats. */
enum {
  POCKETASR_FMT_S16 = 0,
  POCKETASR_FMT_S32 = 1,
  POCKETASR_FMT_F32 = 2,
  POCKETASR_FMT_U8 = 3,
  POCKETASR_FMT_S24 = 4,
};

typedef struct {
  int target;       /* AGC target level (16-bit RMS-ish), default 8000 */
  int max_gain_db;  /* max boost, default 24 */
  int inc_db_s;     /* max gain rise per second, default 12 */
  int dec_db_s;     /* max gain fall per second, default 40 */
  int vad;          /* gate AGC adaptation on speech, default 1 */
  int enabled;      /* 0 disables AGC (resample only), default 1 */
} PocketAsrAgcConfig;

/* Fall back to defaults when cfg is NULL. */
void pocketasr_agc_defaults(PocketAsrAgcConfig *cfg);

/* Begin a chain writing little-endian float32 to out_path. Returns a handle to
 * test with POCKETASR_HANDLE_OK, or 0 / a negative POCKETASR_ERR_*. */
intptr_t pocketasr_chain_begin(const char *out_path, int in_rate, int channels,
                           int target_rate, const PocketAsrAgcConfig *cfg);

/* Feed one buffer of interleaved PCM (bytes must divide evenly into frames). */
int pocketasr_chain_feed(intptr_t handle, const void *data, int bytes, int fmt);

/* Flush the resampler/AGC, close the file and return the emitted frame count. */
long pocketasr_chain_end(intptr_t handle);

/* Release everything without flushing (partial output is the caller's file). */
void pocketasr_chain_abort(intptr_t handle);

#endif
