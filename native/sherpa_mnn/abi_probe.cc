#include <cstddef>

#include "sherpa-mnn/c-api/c-api.h"

// These constants are the arm64 ABI consumed by the generated Dart FFI.
// This file is compiled with the pinned Android NDK toolchain against the
// freshly cloned, pinned upstream header. Any upstream ABI drift is fatal.

static_assert(sizeof(void*) == 8);

static_assert(sizeof(SherpaMnnFeatureConfig) == 8);
static_assert(offsetof(SherpaMnnFeatureConfig, sample_rate) == 0);
static_assert(offsetof(SherpaMnnFeatureConfig, feature_dim) == 4);

static_assert(sizeof(SherpaMnnOfflineSenseVoiceModelConfig) == 24);
static_assert(offsetof(SherpaMnnOfflineSenseVoiceModelConfig, model) == 0);
static_assert(offsetof(SherpaMnnOfflineSenseVoiceModelConfig, language) == 8);
static_assert(offsetof(SherpaMnnOfflineSenseVoiceModelConfig, use_itn) == 16);

static_assert(sizeof(SherpaMnnOfflineModelConfig) == 216);
static_assert(offsetof(SherpaMnnOfflineModelConfig, transducer) == 0);
static_assert(offsetof(SherpaMnnOfflineModelConfig, paraformer) == 24);
static_assert(offsetof(SherpaMnnOfflineModelConfig, nemo_ctc) == 32);
static_assert(offsetof(SherpaMnnOfflineModelConfig, whisper) == 40);
static_assert(offsetof(SherpaMnnOfflineModelConfig, tdnn) == 80);
static_assert(offsetof(SherpaMnnOfflineModelConfig, tokens) == 88);
static_assert(offsetof(SherpaMnnOfflineModelConfig, num_threads) == 96);
static_assert(offsetof(SherpaMnnOfflineModelConfig, debug) == 100);
static_assert(offsetof(SherpaMnnOfflineModelConfig, provider) == 104);
static_assert(offsetof(SherpaMnnOfflineModelConfig, model_type) == 112);
static_assert(offsetof(SherpaMnnOfflineModelConfig, modeling_unit) == 120);
static_assert(offsetof(SherpaMnnOfflineModelConfig, bpe_vocab) == 128);
static_assert(offsetof(SherpaMnnOfflineModelConfig, telespeech_ctc) == 136);
static_assert(offsetof(SherpaMnnOfflineModelConfig, sense_voice) == 144);
static_assert(offsetof(SherpaMnnOfflineModelConfig, moonshine) == 168);
static_assert(offsetof(SherpaMnnOfflineModelConfig, fire_red_asr) == 200);

static_assert(sizeof(SherpaMnnOfflineRecognizerConfig) == 296);
static_assert(offsetof(SherpaMnnOfflineRecognizerConfig, feat_config) == 0);
static_assert(offsetof(SherpaMnnOfflineRecognizerConfig, model_config) == 8);
static_assert(offsetof(SherpaMnnOfflineRecognizerConfig, lm_config) == 224);
static_assert(offsetof(SherpaMnnOfflineRecognizerConfig, decoding_method) == 240);
static_assert(offsetof(SherpaMnnOfflineRecognizerConfig, max_active_paths) == 248);
static_assert(offsetof(SherpaMnnOfflineRecognizerConfig, hotwords_file) == 256);
static_assert(offsetof(SherpaMnnOfflineRecognizerConfig, hotwords_score) == 264);
static_assert(offsetof(SherpaMnnOfflineRecognizerConfig, rule_fsts) == 272);
static_assert(offsetof(SherpaMnnOfflineRecognizerConfig, rule_fars) == 280);
static_assert(offsetof(SherpaMnnOfflineRecognizerConfig, blank_penalty) == 288);

static_assert(sizeof(SherpaMnnOfflineRecognizerResult) == 72);
static_assert(offsetof(SherpaMnnOfflineRecognizerResult, text) == 0);
static_assert(offsetof(SherpaMnnOfflineRecognizerResult, timestamps) == 8);
static_assert(offsetof(SherpaMnnOfflineRecognizerResult, count) == 16);
static_assert(offsetof(SherpaMnnOfflineRecognizerResult, tokens) == 24);
static_assert(offsetof(SherpaMnnOfflineRecognizerResult, tokens_arr) == 32);
static_assert(offsetof(SherpaMnnOfflineRecognizerResult, json) == 40);
static_assert(offsetof(SherpaMnnOfflineRecognizerResult, lang) == 48);
static_assert(offsetof(SherpaMnnOfflineRecognizerResult, emotion) == 56);
static_assert(offsetof(SherpaMnnOfflineRecognizerResult, event) == 64);
