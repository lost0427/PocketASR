#include "pocketasr_wav.h"

#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "pocketasr_chain.h"

/* Canonical file is always mono 16-bit; 44 bytes is the header Dart writes. */
#define WAV_HEADER_BYTES 44
#define WAV_MAX_SAMPLES 8192

static void put_u16(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v & 0xff);
  p[1] = (uint8_t)((v >> 8) & 0xff);
}

static void put_u32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v & 0xff);
  p[1] = (uint8_t)((v >> 8) & 0xff);
  p[2] = (uint8_t)((v >> 16) & 0xff);
  p[3] = (uint8_t)((v >> 24) & 0xff);
}

static void wav_header(uint8_t *h, uint32_t payload, uint32_t rate) {
  memcpy(h, "RIFF", 4);
  put_u32(h + 4, 36 + payload);
  memcpy(h + 8, "WAVEfmt ", 8);
  put_u32(h + 16, 16);
  put_u16(h + 20, 1); /* PCM */
  put_u16(h + 22, 1); /* mono */
  put_u32(h + 24, rate);
  put_u32(h + 28, rate * 2); /* byte rate */
  put_u16(h + 32, 2);        /* block align */
  put_u16(h + 34, 16);       /* bits per sample */
  memcpy(h + 36, "data", 4);
  put_u32(h + 40, payload);
}

/* Matches Dart's float32ToPcm16: non-finite -> silence, clamp, *32768, round. */
static int16_t to_pcm16(float sample) {
  double d = (double)sample;
  if (isnan(d) || isinf(d)) return 0;
  if (d > 1.0) d = 1.0;
  else if (d < -1.0) d = -1.0;
  double r = round(d * 32768.0);
  long v = (long)r;
  if (v > 32767) v = 32767;
  return (int16_t)v;
}

long pocketasr_write_wav(const char *src_path, const char *dst_path,
                         const int64_t *starts, const int64_t *ends, int count,
                         int src_fmt, int sample_rate) {
  if (!src_path || !dst_path || count < 0 || sample_rate <= 0) {
    return POCKETASR_ERR_ARG;
  }
  if (count > 0 && (!starts || !ends)) return POCKETASR_ERR_ARG;

  const size_t src_bytes =
      src_fmt == POCKETASR_FMT_F32 ? 4 : src_fmt == POCKETASR_FMT_S16 ? 2 : 0;
  if (src_bytes == 0) return POCKETASR_ERR_ARG;

  int64_t total = 0;
  for (int i = 0; i < count; i++) {
    if (starts[i] < 0 || ends[i] < starts[i]) return POCKETASR_ERR_ARG;
    total += ends[i] - starts[i];
  }
  /* A RIFF size field is 32-bit; refuse rather than write a corrupt header. */
  if (total > (int64_t)((0xffffffffu - 36u) / 2u)) return POCKETASR_ERR_ARG;

  FILE *in = fopen(src_path, "rb");
  if (!in) return POCKETASR_ERR_IO;
  FILE *out = fopen(dst_path, "wb");
  if (!out) {
    fclose(in);
    return POCKETASR_ERR_IO;
  }
  setvbuf(out, NULL, _IOFBF, 1 << 16);

  uint8_t header[WAV_HEADER_BYTES];
  wav_header(header, (uint32_t)(total * 2), (uint32_t)sample_rate);
  long rc = POCKETASR_ERR_IO;
  if (fwrite(header, 1, sizeof(header), out) != sizeof(header)) goto done;

  float fbuf[WAV_MAX_SAMPLES];
  int16_t sbuf[WAV_MAX_SAMPLES];
  uint8_t pcm[WAV_MAX_SAMPLES * 2];
  for (int i = 0; i < count; i++) {
    int64_t remaining = ends[i] - starts[i];
    int64_t offset = starts[i] * (int64_t)src_bytes;
    /* 32-bit long hosts (Windows) cannot fseek past 2 GiB. */
    if (offset > (int64_t)LONG_MAX) {
      rc = POCKETASR_ERR_ARG;
      goto done;
    }
    if (fseek(in, (long)offset, SEEK_SET) != 0) goto done;
    while (remaining > 0) {
      int64_t take = remaining < WAV_MAX_SAMPLES ? remaining : WAV_MAX_SAMPLES;
      if (src_fmt == POCKETASR_FMT_F32) {
        if (fread(fbuf, sizeof(float), (size_t)take, in) != (size_t)take) {
          goto done;
        }
        for (long k = 0; k < take; k++) {
          int16_t v = to_pcm16(fbuf[k]);
          pcm[2 * k] = (uint8_t)(v & 0xff);
          pcm[2 * k + 1] = (uint8_t)(((uint16_t)v >> 8) & 0xff);
        }
      } else {
        if (fread(sbuf, sizeof(int16_t), (size_t)take, in) != (size_t)take) {
          goto done;
        }
        memcpy(pcm, sbuf, (size_t)take * 2);
      }
      size_t out_bytes = (size_t)take * 2;
      if (fwrite(pcm, 1, out_bytes, out) != out_bytes) goto done;
      remaining -= take;
    }
  }
  rc = (long)total;

done:
  if (rc < 0) remove(dst_path);
  fclose(out);
  fclose(in);
  return rc;
}
