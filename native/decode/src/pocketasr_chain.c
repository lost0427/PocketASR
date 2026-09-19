/*
 * PocketASR decode chain implementation. See pocketasr_chain.h.
 *
 * The stage order matters: the AGC runs at the target rate so its 20 ms frame
 * is a fixed 320 samples regardless of the source rate, and only the final
 * write converts to float.
 */
#include "pocketasr_chain.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "speex/speex_preprocess.h"
#include "speex/speex_resampler.h"

/*
 * preprocess.c references the echo canceller unconditionally. PocketASR never
 * attaches an echo state, so an inert definition avoids building all of mdf.c.
 */
typedef struct SpeexEchoState_ SpeexEchoState;
void speex_echo_get_residual(SpeexEchoState *st, int32_t *Yout, int len) {
  (void)st;
  (void)Yout;
  (void)len;
}

#define POCKETASR_CHUNK 4096
#define POCKETASR_OUT_FLOATS 8192
#define POCKETASR_AGC_MS 20

typedef struct {
  FILE *out;
  int in_rate;
  int channels;
  int target_rate;

  SpeexResamplerState *rs; /* NULL when in_rate == target_rate */
  SpeexPreprocessState *agc;

  int frame_size;
  int frame_fill;
  int16_t *frame;

  int16_t *mono;   /* POCKETASR_CHUNK frames */
  int16_t *rs_out; /* worst case resampler output for one chunk */
  int rs_out_cap;

  float *outbuf;
  int out_fill;

  long total;
} PocketAsrChain;

void pocketasr_agc_defaults(PocketAsrAgcConfig *cfg) {
  if (!cfg) return;
  cfg->target = 8000;
  cfg->max_gain_db = 24;
  cfg->inc_db_s = 12;
  cfg->dec_db_s = 40;
  cfg->vad = 1;
  cfg->enabled = 1;
}

static int bits_per_sample(int fmt) {
  switch (fmt) {
    case POCKETASR_FMT_S16: return 2;
    case POCKETASR_FMT_S32: return 4;
    case POCKETASR_FMT_F32: return 4;
    case POCKETASR_FMT_U8: return 1;
    case POCKETASR_FMT_S24: return 3;
    default: return 0;
  }
}

static int clamp16(int v) {
  if (v < -32768) return -32768;
  if (v > 32767) return 32767;
  return v;
}

static int write_floats(PocketAsrChain *c, const int16_t *src, int n) {
  for (int i = 0; i < n; i++) {
    c->outbuf[c->out_fill++] = (float)src[i] * (1.0f / 32768.0f);
    if (c->out_fill == POCKETASR_OUT_FLOATS) {
      if (fwrite(c->outbuf, sizeof(float), c->out_fill, c->out) !=
          (size_t)c->out_fill) {
        return POCKETASR_ERR_IO;
      }
      c->out_fill = 0;
    }
  }
  c->total += n;
  return POCKETASR_OK;
}

/* Queue samples into the AGC frame; each full frame is denoised/normalized. */
static int push_samples(PocketAsrChain *c, const int16_t *src, int n) {
  for (int i = 0; i < n; i++) {
    c->frame[c->frame_fill++] = src[i];
    if (c->frame_fill == c->frame_size) {
      if (c->agc) speex_preprocess_run(c->agc, c->frame);
      int rc = write_floats(c, c->frame, c->frame_size);
      if (rc != POCKETASR_OK) return rc;
      c->frame_fill = 0;
    }
  }
  return POCKETASR_OK;
}

/* Interleaved PCM of `frames` frames -> mono int16 in c->mono. */
static void downmix(const PocketAsrChain *c, const uint8_t *src, int frames,
                    int fmt, int16_t *dst) {
  const int ch = c->channels;
  switch (fmt) {
    case POCKETASR_FMT_S16: {
      const int16_t *p = (const int16_t *)src;
      for (int f = 0; f < frames; f++) {
        int sum = 0;
        for (int k = 0; k < ch; k++) sum += p[(size_t)f * ch + k];
        dst[f] = (int16_t)clamp16(sum / ch);
      }
      break;
    }
    case POCKETASR_FMT_F32: {
      const float *p = (const float *)src;
      for (int f = 0; f < frames; f++) {
        float sum = 0.0f;
        for (int k = 0; k < ch; k++) sum += p[(size_t)f * ch + k];
        float v = sum / ch;
        if (!(v == v)) v = 0.0f; /* NaN from a damaged frame -> silence */
        dst[f] = (int16_t)clamp16((int)(v * 32767.0f));
      }
      break;
    }
    case POCKETASR_FMT_S32: {
      const int32_t *p = (const int32_t *)src;
      for (int f = 0; f < frames; f++) {
        int sum = 0;
        for (int k = 0; k < ch; k++) sum += (int)(p[(size_t)f * ch + k] >> 16);
        dst[f] = (int16_t)clamp16(sum / ch);
      }
      break;
    }
    case POCKETASR_FMT_U8: {
      for (int f = 0; f < frames; f++) {
        int sum = 0;
        for (int k = 0; k < ch; k++) {
          sum += ((int)src[(size_t)f * ch + k] - 128) << 8;
        }
        dst[f] = (int16_t)clamp16(sum / ch);
      }
      break;
    }
    case POCKETASR_FMT_S24: {
      for (int f = 0; f < frames; f++) {
        int sum = 0;
        for (int k = 0; k < ch; k++) {
          const uint8_t *b = src + ((size_t)f * ch + k) * 3;
          int32_t v = (int32_t)(b[0] | (b[1] << 8) | (b[2] << 16));
          if (v & 0x800000) v |= ~0xFFFFFF;
          sum += (int)(v >> 8);
        }
        dst[f] = (int16_t)clamp16(sum / ch);
      }
      break;
    }
    default:
      break;
  }
}

intptr_t pocketasr_chain_begin(const char *out_path, int in_rate, int channels,
                           int target_rate, const PocketAsrAgcConfig *cfg) {
  if (!out_path || in_rate <= 0 || channels <= 0 || target_rate <= 0) {
    return POCKETASR_ERR_ARG;
  }
  PocketAsrAgcConfig defaults;
  if (!cfg) {
    pocketasr_agc_defaults(&defaults);
    cfg = &defaults;
  }

  PocketAsrChain *c = (PocketAsrChain *)calloc(1, sizeof(PocketAsrChain));
  if (!c) return POCKETASR_ERR;

  c->in_rate = in_rate;
  c->channels = channels;
  c->target_rate = target_rate;
  c->frame_size = target_rate * POCKETASR_AGC_MS / 1000;
  if (c->frame_size < 1) c->frame_size = 1;

  c->out = fopen(out_path, "wb");
  if (!c->out) goto fail;

  c->frame = (int16_t *)calloc((size_t)c->frame_size, sizeof(int16_t));
  c->mono = (int16_t *)malloc((size_t)POCKETASR_CHUNK * sizeof(int16_t));
  c->outbuf = (float *)malloc(POCKETASR_OUT_FLOATS * sizeof(float));
  if (!c->frame || !c->mono || !c->outbuf) goto fail;

  if (in_rate != target_rate) {
    int err = 0;
    c->rs = speex_resampler_init(1, (spx_uint32_t)in_rate,
                                 (spx_uint32_t)target_rate,
                                 SPEEX_RESAMPLER_QUALITY_DESKTOP, &err);
    if (!c->rs || err != 0) goto fail;
    /* Worst case one output frame per input frame, plus a small margin. */
    int ratio = (target_rate + in_rate - 1) / in_rate;
    if (ratio < 1) ratio = 1;
    c->rs_out_cap = POCKETASR_CHUNK * ratio + 64;
    c->rs_out = (int16_t *)malloc((size_t)c->rs_out_cap * sizeof(int16_t));
    if (!c->rs_out) goto fail;
  }

  if (cfg->enabled) {
    c->agc = speex_preprocess_state_init(c->frame_size, target_rate);
    if (!c->agc) goto fail;
    int v = cfg->enabled;
    speex_preprocess_ctl(c->agc, SPEEX_PREPROCESS_SET_AGC, &v);
    v = cfg->target;
    speex_preprocess_ctl(c->agc, SPEEX_PREPROCESS_SET_AGC_TARGET, &v);
    v = cfg->max_gain_db;
    speex_preprocess_ctl(c->agc, SPEEX_PREPROCESS_SET_AGC_MAX_GAIN, &v);
    v = cfg->inc_db_s;
    speex_preprocess_ctl(c->agc, SPEEX_PREPROCESS_SET_AGC_INCREMENT, &v);
    v = cfg->dec_db_s;
    speex_preprocess_ctl(c->agc, SPEEX_PREPROCESS_SET_AGC_DECREMENT, &v);
    v = cfg->vad;
    speex_preprocess_ctl(c->agc, SPEEX_PREPROCESS_SET_VAD, &v);
    v = 0;
    speex_preprocess_ctl(c->agc, SPEEX_PREPROCESS_SET_DENOISE, &v);
    speex_preprocess_ctl(c->agc, SPEEX_PREPROCESS_SET_DEREVERB, &v);
  }

  return (intptr_t)c;

fail:
  if (c->out) fclose(c->out);
  if (c->rs) speex_resampler_destroy(c->rs);
  if (c->agc) speex_preprocess_state_destroy(c->agc);
  free(c->frame);
  free(c->mono);
  free(c->rs_out);
  free(c->outbuf);
  free(c);
  return POCKETASR_ERR;
}

int pocketasr_chain_feed(intptr_t handle, const void *data, int bytes, int fmt) {
  PocketAsrChain *c = (PocketAsrChain *)handle;
  if (!c) return POCKETASR_ERR_ARG;
  int bps = bits_per_sample(fmt);
  if (!bps) return POCKETASR_ERR_ARG;
  int stride = c->channels * bps;
  if (bytes < 0 || (bytes % stride) != 0) return POCKETASR_ERR_ARG;
  int frames = bytes / stride;
  const uint8_t *src = (const uint8_t *)data;

  while (frames > 0) {
    int n = frames > POCKETASR_CHUNK ? POCKETASR_CHUNK : frames;
    downmix(c, src, n, fmt, c->mono);

    if (c->rs) {
      spx_uint32_t in_len = (spx_uint32_t)n;
      spx_uint32_t out_len = (spx_uint32_t)c->rs_out_cap;
      if (speex_resampler_process_int(c->rs, 0, c->mono, &in_len, c->rs_out,
                                      &out_len) != RESAMPLER_ERR_SUCCESS) {
        return POCKETASR_ERR;
      }
      int rc = push_samples(c, c->rs_out, (int)out_len);
      if (rc != POCKETASR_OK) return rc;
    } else {
      int rc = push_samples(c, c->mono, n);
      if (rc != POCKETASR_OK) return rc;
    }

    src += (size_t)n * stride;
    frames -= n;
  }
  return POCKETASR_OK;
}

long pocketasr_chain_end(intptr_t handle) {
  PocketAsrChain *c = (PocketAsrChain *)handle;
  if (!c) return POCKETASR_ERR_ARG;

  /* Drain the resampler's internal history with zero-length input. */
  if (c->rs) {
    for (;;) {
      spx_uint32_t in_len = 0;
      spx_uint32_t out_len = (spx_uint32_t)c->rs_out_cap;
      if (speex_resampler_process_int(c->rs, 0, c->mono, &in_len, c->rs_out,
                                      &out_len) != RESAMPLER_ERR_SUCCESS ||
          out_len == 0) {
        break;
      }
      if (push_samples(c, c->rs_out, (int)out_len) != POCKETASR_OK) break;
    }
  }

  long total = POCKETASR_ERR;
  if (c->frame_fill > 0) {
    int real = c->frame_fill;
    memset(c->frame + real, 0, (size_t)(c->frame_size - real) * sizeof(int16_t));
    if (c->agc) speex_preprocess_run(c->agc, c->frame);
    int rc = write_floats(c, c->frame, real);
    c->frame_fill = 0;
    if (rc != POCKETASR_OK) goto done;
  }
  if (c->out_fill > 0) {
    if (fwrite(c->outbuf, sizeof(float), c->out_fill, c->out) !=
        (size_t)c->out_fill) {
      goto done;
    }
    c->out_fill = 0;
  }
  total = c->total;

done:
  if (c->out) fclose(c->out);
  if (c->rs) speex_resampler_destroy(c->rs);
  if (c->agc) speex_preprocess_state_destroy(c->agc);
  free(c->frame);
  free(c->mono);
  free(c->rs_out);
  free(c->outbuf);
  free(c);
  return total;
}

void pocketasr_chain_abort(intptr_t handle) {
  PocketAsrChain *c = (PocketAsrChain *)handle;
  if (!c) return;
  if (c->out) fclose(c->out);
  if (c->rs) speex_resampler_destroy(c->rs);
  if (c->agc) speex_preprocess_state_destroy(c->agc);
  free(c->frame);
  free(c->mono);
  free(c->rs_out);
  free(c->outbuf);
  free(c);
}
