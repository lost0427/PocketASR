/*
 * JNI entry points for the PocketASR Android decoder.
 *
 * File inputs (mp3/wav/flac) are decoded in-process by dr_libs and written to
 * the shared chain; AAC/M4A stay on MediaCodec and feed the same chain through
 * chainBegin/chainFeed/chainEnd. Copying raw PCM across the JNI boundary is
 * avoided by taking the MediaCodec direct ByteBuffer address directly.
 */
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

#include "pocketasr_chain.h"
#include "pocketasr_wav.h"

#define DR_MP3_IMPLEMENTATION
#define DR_WAV_IMPLEMENTATION
#define DR_FLAC_IMPLEMENTATION
#include "dr_mp3.h"
#include "dr_wav.h"
#include "dr_flac.h"

typedef struct {
  int fd;
} FdIo;

static size_t io_read(void *user, void *out, size_t bytes) {
  FdIo *io = (FdIo *)user;
  return (size_t)read(io->fd, out, bytes);
}

static int io_seek(void *user, int offset, int whence) {
  FdIo *io = (FdIo *)user;
  return lseek(io->fd, offset, whence) >= 0 ? 1 : 0;
}

static int io_tell(void *user, int64_t *cursor) {
  FdIo *io = (FdIo *)user;
  off_t pos = lseek(io->fd, 0, SEEK_CUR);
  if (pos < 0) return 0;
  *cursor = (int64_t)pos;
  return 1;
}

#define POCKETASR_WHENCE(SET, END, CUR) \
  (origin == (SET) ? SEEK_SET : origin == (END) ? SEEK_END : SEEK_CUR)

static size_t mp3_read(void *u, void *o, size_t n) { return io_read(u, o, n); }
static drmp3_bool32 mp3_seek(void *u, int off, drmp3_seek_origin origin) {
  return (drmp3_bool32)io_seek(
      u, off, POCKETASR_WHENCE(DRMP3_SEEK_SET, DRMP3_SEEK_END, DRMP3_SEEK_CUR));
}
static drmp3_bool32 mp3_tell(void *u, drmp3_int64 *c) {
  return (drmp3_bool32)io_tell(u, (int64_t *)c);
}

static size_t wav_read(void *u, void *o, size_t n) { return io_read(u, o, n); }
static drwav_bool32 wav_seek(void *u, int off, drwav_seek_origin origin) {
  return (drwav_bool32)io_seek(
      u, off, POCKETASR_WHENCE(DRWAV_SEEK_SET, DRWAV_SEEK_END, DRWAV_SEEK_CUR));
}
static drwav_bool32 wav_tell(void *u, drwav_int64 *c) {
  return (drwav_bool32)io_tell(u, (int64_t *)c);
}

static size_t flac_read(void *u, void *o, size_t n) { return io_read(u, o, n); }
static drflac_bool32 flac_seek(void *u, int off, drflac_seek_origin origin) {
  return (drflac_bool32)io_seek(u, off,
      POCKETASR_WHENCE(DRFLAC_SEEK_SET, DRFLAC_SEEK_END, DRFLAC_SEEK_CUR));
}
static drflac_bool32 flac_tell(void *u, drflac_int64 *c) {
  return (drflac_bool32)io_tell(u, (int64_t *)c);
}

static void parse_agc(JNIEnv *env, jintArray arr, PocketAsrAgcConfig *cfg) {
  pocketasr_agc_defaults(cfg);
  if (!arr) return;
  jsize n = (*env)->GetArrayLength(env, arr);
  if (n < 6) return;
  jint v[6];
  (*env)->GetIntArrayRegion(env, arr, 0, 6, v);
  cfg->target = v[0];
  cfg->max_gain_db = v[1];
  cfg->inc_db_s = v[2];
  cfg->dec_db_s = v[3];
  cfg->vad = v[4];
  cfg->enabled = v[5];
}

typedef size_t (*read_frames_fn)(void *ctx, int16_t *buf, size_t frames);

static long run_chain(const char *out, int rate, int channels, int target_rate,
                      const PocketAsrAgcConfig *cfg, void *ctx,
                      read_frames_fn read_frames) {
  if (rate <= 0 || channels <= 0) return POCKETASR_ERR;
  intptr_t h = pocketasr_chain_begin(out, rate, channels, target_rate, cfg);
  if (!POCKETASR_HANDLE_OK(h)) return POCKETASR_ERR;

  const size_t cap = 4096;
  int16_t *buf = (int16_t *)malloc(cap * (size_t)channels * sizeof(int16_t));
  if (!buf) {
    pocketasr_chain_abort(h);
    return POCKETASR_ERR;
  }
  long result = POCKETASR_ERR;
  for (;;) {
    size_t got = read_frames(ctx, buf, cap);
    if (got == 0) {
      result = pocketasr_chain_end(h);
      break;
    }
    if (pocketasr_chain_feed(h, buf, (int)(got * (size_t)channels * 2),
                            POCKETASR_FMT_S16) != POCKETASR_OK) {
      pocketasr_chain_abort(h);
      break;
    }
  }
  free(buf);
  return result;
}

static size_t read_mp3(void *ctx, int16_t *buf, size_t frames) {
  return (size_t)drmp3_read_pcm_frames_s16((drmp3 *)ctx, frames, buf);
}
static size_t read_wav(void *ctx, int16_t *buf, size_t frames) {
  return (size_t)drwav_read_pcm_frames_s16((drwav *)ctx, frames, buf);
}
static size_t read_flac(void *ctx, int16_t *buf, size_t frames) {
  return (size_t)drflac_read_pcm_frames_s16((drflac *)ctx, frames, buf);
}

static long decode_file(int fd, int kind, const char *out, int target_rate,
                        const PocketAsrAgcConfig *cfg) {
  FdIo io = {fd};
  if (kind == 0) {
    drmp3 mp3;
    if (!drmp3_init(&mp3, mp3_read, mp3_seek, mp3_tell, NULL, &io, NULL)) {
      return POCKETASR_ERR;
    }
    long rc = run_chain(out, (int)mp3.sampleRate, (int)mp3.channels,
                        target_rate, cfg, &mp3, read_mp3);
    drmp3_uninit(&mp3);
    return rc;
  }
  if (kind == 1) {
    drwav wav;
    if (!drwav_init(&wav, wav_read, wav_seek, wav_tell, &io, NULL)) {
      return POCKETASR_ERR;
    }
    long rc = run_chain(out, (int)wav.sampleRate, (int)wav.channels,
                        target_rate, cfg, &wav, read_wav);
    drwav_uninit(&wav);
    return rc;
  }
  if (kind == 2) {
    drflac *flac = drflac_open(flac_read, flac_seek, flac_tell, &io, NULL);
    if (!flac) return POCKETASR_ERR;
    long rc = run_chain(out, (int)flac->sampleRate, (int)flac->channels,
                        target_rate, cfg, flac, read_flac);
    drflac_close(flac);
    return rc;
  }
  return POCKETASR_ERR;
}

JNIEXPORT jlong JNICALL
Java_com_pocketasr_pocket_1asr_NativeDecode_decodeFd(
    JNIEnv *env, jclass clazz, jint fd, jint kind, jstring out_path,
    jint target_rate, jintArray agc) {
  (void)clazz;
  const char *out = (*env)->GetStringUTFChars(env, out_path, NULL);
  if (!out) return POCKETASR_ERR;
  PocketAsrAgcConfig cfg;
  parse_agc(env, agc, &cfg);
  long rc = decode_file((int)fd, (int)kind, out, (int)target_rate, &cfg);
  (*env)->ReleaseStringUTFChars(env, out_path, out);
  return (jlong)rc;
}

JNIEXPORT jlong JNICALL
Java_com_pocketasr_pocket_1asr_NativeDecode_chainBegin(
    JNIEnv *env, jclass clazz, jstring out_path, jint in_rate, jint channels,
    jint target_rate, jintArray agc) {
  (void)clazz;
  const char *out = (*env)->GetStringUTFChars(env, out_path, NULL);
  if (!out) return POCKETASR_ERR;
  PocketAsrAgcConfig cfg;
  parse_agc(env, agc, &cfg);
  intptr_t h = pocketasr_chain_begin(out, (int)in_rate, (int)channels,
                                 (int)target_rate, &cfg);
  (*env)->ReleaseStringUTFChars(env, out_path, out);
  return (jlong)h;
}

JNIEXPORT jint JNICALL
Java_com_pocketasr_pocket_1asr_NativeDecode_chainFeed(
    JNIEnv *env, jclass clazz, jlong handle, jobject buffer, jint offset,
    jint length, jint fmt) {
  (void)clazz;
  void *base = (*env)->GetDirectBufferAddress(env, buffer);
  if (!base || length <= 0 || offset < 0) return POCKETASR_ERR_ARG;
  return (jint)pocketasr_chain_feed((intptr_t)handle, (const char *)base + offset,
                                    (int)length, (int)fmt);
}

JNIEXPORT jlong JNICALL
Java_com_pocketasr_pocket_1asr_NativeDecode_chainEnd(JNIEnv *env, jclass clazz,
                                                     jlong handle) {
  (void)env;
  (void)clazz;
  return (jlong)pocketasr_chain_end((intptr_t)handle);
}

JNIEXPORT void JNICALL
Java_com_pocketasr_pocket_1asr_NativeDecode_chainAbort(JNIEnv *env,
                                                       jclass clazz,
                                                       jlong handle) {
  (void)env;
  (void)clazz;
  pocketasr_chain_abort((intptr_t)handle);
}

/*
 * Splits the raw chain output into one chunk WAV. Spans are jlong, which is
 * int64_t on every JNI platform, so the arrays pass straight through.
 */
JNIEXPORT jlong JNICALL
Java_com_pocketasr_pocket_1asr_NativeDecode_writeWav(
    JNIEnv *env, jclass clazz, jstring source, jstring destination,
    jlongArray starts, jlongArray ends, jint sample_rate, jint fmt) {
  (void)clazz;
  if (!starts || !ends) return POCKETASR_ERR_ARG;
  jsize count = (*env)->GetArrayLength(env, starts);
  if ((*env)->GetArrayLength(env, ends) != count) return POCKETASR_ERR_ARG;

  const char *src = (*env)->GetStringUTFChars(env, source, NULL);
  if (!src) return POCKETASR_ERR;
  const char *dst = (*env)->GetStringUTFChars(env, destination, NULL);
  if (!dst) {
    (*env)->ReleaseStringUTFChars(env, source, src);
    return POCKETASR_ERR;
  }

  long rc = POCKETASR_ERR_ARG;
  int64_t *spans = NULL;
  if (count == 0) {
    rc = pocketasr_write_wav(src, dst, NULL, NULL, 0, (int)fmt,
                             (int)sample_rate);
  } else {
    /* Two arrays of count spans; freed below. */
    spans = (int64_t *)malloc((size_t)count * 2 * sizeof(int64_t));
    if (spans) {
      (*env)->GetLongArrayRegion(env, starts, 0, count, (jlong *)spans);
      (*env)->GetLongArrayRegion(env, ends, 0, count, (jlong *)(spans + count));
      if (!(*env)->ExceptionCheck(env)) {
        rc = pocketasr_write_wav(src, dst, spans, spans + count, (int)count,
                                 (int)fmt, (int)sample_rate);
      } else {
        (*env)->ExceptionClear(env);
      }
      free(spans);
    }
  }

  (*env)->ReleaseStringUTFChars(env, destination, dst);
  (*env)->ReleaseStringUTFChars(env, source, src);
  return (jlong)rc;
}
