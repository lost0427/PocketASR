/*
 * Host self-test for the chunk WAV writer (build with POCKETASR_BUILD_TESTS=ON).
 *
 *   cmake -S native/decode -B build/decode-test -G Ninja \
 *         -DPOCKETASR_BUILD_TESTS=ON -DCMAKE_C_COMPILER=gcc
 *   cmake --build build/decode-test --target pocketasr_wav_test
 *   ./build/decode-test/pocketasr_wav_test
 *
 * The Dart side compares the same spans against PcmFile.writeWave, so this
 * pins the parts that would silently corrupt audio: the 44-byte header, the
 * range concatenation order, and the float32 -> PCM16 rounding rule.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pocketasr_chain.h"
#include "pocketasr_wav.h"

static int write_file(const char *path, const void *data, size_t bytes) {
  FILE *f = fopen(path, "wb");
  if (!f) return 0;
  int ok = fwrite(data, 1, bytes, f) == bytes;
  fclose(f);
  return ok;
}

static uint8_t *read_file(const char *path, long *bytes) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  *bytes = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *buf = (uint8_t *)malloc((size_t)*bytes);
  if (!buf || fread(buf, 1, (size_t)*bytes, f) != (size_t)*bytes) {
    free(buf);
    fclose(f);
    return NULL;
  }
  fclose(f);
  return buf;
}

static uint32_t u32_at(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static uint16_t u16_at(const uint8_t *p) {
  return (uint16_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8));
}

static int16_t s16_at(const uint8_t *p) {
  return (int16_t)u16_at(p);
}

/* The rule Dart's float32ToPcm16 uses, restated independently. */
static int16_t expect_pcm16(float sample) {
  double d = (double)sample;
  if (d > 1.0) d = 1.0;
  else if (d < -1.0) d = -1.0;
  long v = (long)round(d * 32768.0);
  if (v > 32767) v = 32767;
  return (int16_t)v;
}

int main(void) {
  setvbuf(stdout, NULL, _IONBF, 0);
  int failures = 0;

  /* float32 source: concatenated ranges, header, and rounding. */
  {
    const float src[] = {0.25f,     -0.5f, 1.0f, -1.0f,
                         1.0f / 32768.0f, -1.5f, 1.5f, 0.0f};
    const int64_t starts[] = {1, 6};
    const int64_t ends[] = {5, 8};
    if (!write_file("wav_src.f32", src, sizeof(src))) {
      puts("FAIL: cannot write wav_src.f32");
      failures++;
    } else {
      long count = pocketasr_write_wav("wav_src.f32", "wav_out.wav", starts,
                                       ends, 2, POCKETASR_FMT_F32, 16000);
      long bytes = 0;
      uint8_t *out = read_file("wav_out.wav", &bytes);
      const int64_t want[] = {1, 2, 3, 4, 6, 7}; /* samples 1..4 then 6..7 */
      int ok = count == 6 && out && bytes == 44 + 6 * 2;
      if (ok) {
        ok = memcmp(out, "RIFF", 4) == 0 && u32_at(out + 4) == 36 + 12 &&
             memcmp(out + 8, "WAVEfmt ", 8) == 0 && u32_at(out + 16) == 16 &&
             u16_at(out + 20) == 1 && u16_at(out + 22) == 1 &&
             u32_at(out + 24) == 16000 && u32_at(out + 28) == 32000 &&
             u16_at(out + 32) == 2 && u16_at(out + 34) == 16 &&
             memcmp(out + 36, "data", 4) == 0 && u32_at(out + 40) == 12;
      }
      for (int i = 0; ok && i < 6; i++) {
        ok = s16_at(out + 44 + i * 2) == expect_pcm16(src[want[i]]);
      }
      printf("f32: count=%ld bytes=%ld first=%d last=%d\n", count, bytes,
             out && bytes > 44 ? s16_at(out + 44) : 0,
             out && bytes > 44 ? s16_at(out + bytes - 2) : 0);
      if (!ok) {
        puts("FAIL: f32 ranges/header/rounding");
        failures++;
      }
      free(out);
    }
  }

  /* int16 source is copied through unchanged. */
  {
    const int16_t src[] = {100, -200, 300, -400};
    const int64_t starts[] = {0, 3};
    const int64_t ends[] = {2, 4};
    if (!write_file("wav_src.s16", src, sizeof(src))) {
      puts("FAIL: cannot write wav_src.s16");
      failures++;
    } else {
      long count = pocketasr_write_wav("wav_src.s16", "wav_out16.wav", starts,
                                       ends, 2, POCKETASR_FMT_S16, 8000);
      long bytes = 0;
      uint8_t *out = read_file("wav_out16.wav", &bytes);
      int ok = count == 3 && out && bytes == 44 + 3 * 2 &&
               u32_at(out + 24) == 8000 && u32_at(out + 28) == 16000 &&
               s16_at(out + 44) == 100 && s16_at(out + 46) == -200 &&
               s16_at(out + 48) == -400;
      printf("s16: count=%ld bytes=%ld\n", count, bytes);
      if (!ok) {
        puts("FAIL: s16 passthrough");
        failures++;
      }
      free(out);
    }
  }

  /* Rejections must not leave a half-written file behind. */
  {
    const int64_t starts[] = {2};
    const int64_t ends[] = {1};
    int ok = pocketasr_write_wav("wav_src.f32", "wav_bad.wav", starts, ends, 1,
                                 POCKETASR_FMT_F32, 16000) == POCKETASR_ERR_ARG;
    ok = ok && pocketasr_write_wav("wav_src.f32", "wav_bad.wav", starts, ends, 1,
                                   POCKETASR_FMT_S24, 16000) ==
                   POCKETASR_ERR_ARG;
    ok = ok && pocketasr_write_wav("wav_src.f32", "wav_bad.wav", NULL, NULL, 1,
                                   POCKETASR_FMT_F32, 16000) ==
                   POCKETASR_ERR_ARG;
    ok = ok && pocketasr_write_wav("wav_src.f32", "wav_bad.wav", starts, ends, 1,
                                   POCKETASR_FMT_F32, 0) == POCKETASR_ERR_ARG;
    ok = ok && pocketasr_write_wav("wav_missing.f32", "wav_bad.wav", NULL, NULL,
                                   0, POCKETASR_FMT_F32, 16000) ==
                   POCKETASR_ERR_IO;
    ok = ok && fopen("wav_bad.wav", "rb") == NULL;
    if (!ok) {
      puts("FAIL: argument/IO rejection");
      failures++;
    }
  }

  puts(failures == 0 ? "PASS" : "FAIL");
  remove("wav_src.f32");
  remove("wav_src.s16");
  remove("wav_out.wav");
  remove("wav_out16.wav");
  remove("wav_bad.wav");
  return failures == 0 ? 0 : 1;
}
