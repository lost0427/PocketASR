/*
 * Host self-test for the decode chain (build with POCKETASR_BUILD_TESTS=ON).
 *
 *   cmake -S native/decode -B build/decode-test -G Ninja \
 *         -DPOCKETASR_BUILD_TESTS=ON -DCMAKE_C_COMPILER=gcc
 *   cmake --build build/decode-test --target pocketasr_chain_test
 *   ./build/decode-test/pocketasr_chain_test
 *
 * Covers the three things that would silently corrupt audio: resample frame
 * count, AGC bringing a quiet signal up, and AGC leaving silence alone.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "pocketasr_chain.h"

#define IN_RATE 48000
#define TARGET 16000
#define FRAMES IN_RATE /* one second */
#define PI 3.14159265358979323846

static long read_floats(const char *path, float **out) {
  FILE *f = fopen(path, "rb");
  if (!f) return -1;
  fseek(f, 0, SEEK_END);
  long bytes = ftell(f);
  fseek(f, 0, SEEK_SET);
  long n = bytes / (long)sizeof(float);
  float *buf = (float *)malloc((size_t)n * sizeof(float));
  if (!buf || fread(buf, sizeof(float), (size_t)n, f) != (size_t)n) {
    free(buf);
    fclose(f);
    return -1;
  }
  fclose(f);
  *out = buf;
  return n;
}

static double rms_from(const float *x, long start, long n) {
  double sum = 0.0;
  for (long i = start; i < n; i++) sum += (double)x[i] * x[i];
  return sqrt(sum / (double)(n - start));
}

static int feed_all(intptr_t h, const int16_t *pcm, long frames) {
  for (long i = 0; i < frames; i += 4096) {
    int chunk = (int)((frames - i) < 4096 ? (frames - i) : 4096);
    if (pocketasr_chain_feed(h, pcm + i, chunk * 2, POCKETASR_FMT_S16) !=
        POCKETASR_OK) {
      return 0;
    }
  }
  return 1;
}

int main(void) {
  setvbuf(stdout, NULL, _IONBF, 0);
  int failures = 0;
  PocketAsrAgcConfig cfg;
  pocketasr_agc_defaults(&cfg);

  /* Quiet 440 Hz tone: AGC must lift it toward the target level. The first
   * seconds are the AGC settle time, so the last quarter is measured. */
  {
    const long frames = 4L * IN_RATE;
    int16_t *pcm = (int16_t *)malloc((size_t)frames * sizeof(int16_t));
    for (long i = 0; i < frames; i++) {
      pcm[i] = (int16_t)(200.0 * sin(2.0 * PI * 440.0 * i / IN_RATE));
    }
    PocketAsrAgcConfig tone = cfg;
    tone.vad = 0; /* a steady tone is not speech; exercise the AGC math directly */
    intptr_t h = pocketasr_chain_begin("chain_tone.f32", IN_RATE, 1, TARGET, &tone);
    if (h <= 0 || !feed_all(h, pcm, frames)) {
      puts("FAIL: tone chain setup");
      failures++;
    } else {
      long count = pocketasr_chain_end(h);
      float *out = NULL;
      long n = read_floats("chain_tone.f32", &out);
      long want = frames / (IN_RATE / TARGET);
      int ok_count = count > want * 0.98 && count < want * 1.02;
      int ok_len = n == count;
      double r = n > 0 ? rms_from(out, n - n / 4, n) : 0.0;
      int ok_gain = r > 0.02 && r < 0.6; /* input tone RMS is ~0.004 */
      printf("tone: count=%ld (want~%ld) rms=%.3f\n", count, want, r);
      if (!(ok_count && ok_len && ok_gain)) {
        puts("FAIL: tone count/len/agc");
        failures++;
      }
      free(out);
    }
    free(pcm);
  }

  /* Pure silence: AGC must not invent a noise floor. */
  {
    int16_t *pcm = (int16_t *)calloc((size_t)FRAMES, sizeof(int16_t));
    intptr_t h = pocketasr_chain_begin("chain_sil.f32", IN_RATE, 1, TARGET, &cfg);
    if (h <= 0 || !feed_all(h, pcm, FRAMES)) {
      puts("FAIL: silence chain setup");
      failures++;
    } else {
      long count = pocketasr_chain_end(h);
      float *out = NULL;
      long n = read_floats("chain_sil.f32", &out);
      double r = n > 0 ? rms_from(out, 0, n) : 0.0;
      printf("silence: count=%ld rms=%.5f\n", count, r);
      if (!(count > TARGET * 0.98 && count < TARGET * 1.02 && r < 0.02)) {
        puts("FAIL: silence was amplified or truncated");
        failures++;
      }
      free(out);
    }
    free(pcm);
  }

  puts(failures == 0 ? "PASS" : "FAIL");
  remove("chain_tone.f32");
  remove("chain_sil.f32");
  return failures == 0 ? 0 : 1;
}
