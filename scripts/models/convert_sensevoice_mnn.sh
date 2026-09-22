#!/usr/bin/env bash
#
# Convert the pinned sherpa-onnx SenseVoice FP32 export to an MNN weight-quantized
# model, then prove that the result can be loaded and decoded by the same pinned
# sherpa-mnn source used by PocketASR.
#
# This script never downloads a model. Callers provide the three pinned inputs:
#   1. FP32 model.onnx
#   2. tokens.txt
#   3. one test WAV
#
# Usage:
#   bash scripts/models/convert_sensevoice_mnn.sh \
#     /path/to/model.onnx /path/to/tokens.txt /path/to/en.wav /path/to/output
set -euo pipefail

MNN_URL="https://github.com/alibaba/MNN"
MNN_VERSION="3.6.1"
MNN_COMMIT="d407447ed56c4121a11ccbd266dc184ca1ead0c2"

MODEL_SHA256="977016bd9c79f9eb343430b5cc305e07ab64d5212dff41b0dcfa1694bee9a8cb"
TOKENS_SHA256="f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"
TEST_WAV_SHA256="eb1eb008904465b74c304aad8342e8c7d3c6e61ffe9f66adcaca9cf0f76a93f4"

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 MODEL_ONNX TOKENS TEST_WAV OUTPUT_DIR" >&2
  exit 2
fi

MODEL_ONNX="$(realpath "$1")"
TOKENS="$(realpath "$2")"
TEST_WAV="$(realpath "$3")"
OUTPUT_DIR="$(realpath -m "$4")"

for input in "$MODEL_ONNX" "$TOKENS" "$TEST_WAV"; do
  [ -f "$input" ] || { echo "FATAL: missing input: $input" >&2; exit 1; }
done

log() { echo "convert_sensevoice_mnn: $*"; }
verify_sha256() { # file expected
  local actual
  actual="$(sha256sum "$1" | cut -d' ' -f1)"
  if [ "$actual" != "$2" ]; then
    echo "FATAL: SHA-256 mismatch for $1" >&2
    echo "  expected: $2" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

log "verifying pinned inputs"
verify_sha256 "$MODEL_ONNX" "$MODEL_SHA256"
verify_sha256 "$TOKENS" "$TOKENS_SHA256"
verify_sha256 "$TEST_WAV" "$TEST_WAV_SHA256"

mkdir -p "$OUTPUT_DIR"
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pocketasr-sensevoice-mnn.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

clone_at() { # url commit destination
  git init -q "$3"
  git -C "$3" remote add origin "$1"
  git -C "$3" fetch -q --depth 1 origin "$2"
  git -C "$3" checkout -q FETCH_HEAD
  git -C "$3" submodule update --init --recursive
}

log "cloning MNN $MNN_VERSION at $MNN_COMMIT"
clone_at "$MNN_URL" "$MNN_COMMIT" "$WORK/mnn"
MNN_RESOLVED="$(git -C "$WORK/mnn" rev-parse HEAD)"
[ "$MNN_RESOLVED" = "$MNN_COMMIT" ] || {
  echo "FATAL: MNN checkout $MNN_RESOLVED != $MNN_COMMIT" >&2
  exit 1
}

cmake_args=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$WORK/mnn-install"
  -DMNN_BUILD_SHARED_LIBS=OFF
  -DMNN_SEP_BUILD=OFF
  -DMNN_LOW_MEMORY=ON
  -DMNN_BUILD_CONVERTER=ON
  -DMNN_BUILD_PROTOBUFFER=ON
  -DMNN_BUILD_TRAIN=OFF
  -DMNN_BUILD_TOOLS=OFF
  -DMNN_BUILD_TEST=OFF
  -DMNN_BUILD_DEMO=OFF
  -DMNN_BUILD_QUANTOOLS=OFF
  -DMNN_BUILD_BENCHMARK=OFF
  -DMNN_BUILD_OPENCV=OFF
  -DMNN_BUILD_LLM=OFF
  -DMNN_BUILD_DIFFUSION=OFF
  -DMNN_BUILD_AUDIO=OFF
  -DMNN_VULKAN=OFF
  -DMNN_OPENCL=OFF
  -DMNN_OPENGL=OFF
  -DMNN_METAL=OFF
  -DMNN_NNAPI=OFF
  -DMNN_CUDA=OFF
)
if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-$PWD/.ccache-sherpa-mnn-model}"
  export CCACHE_COMPRESS=1
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-3G}"
  export CCACHE_COMPILERCHECK=content
  mkdir -p "$CCACHE_DIR"
  cmake_args+=(
    -DCMAKE_C_COMPILER_LAUNCHER=ccache
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
  )
fi

log "building pinned MNN runtime and MNNConvert"
cmake -S "$WORK/mnn" -B "$WORK/mnn-build" "${cmake_args[@]}"
cmake --build "$WORK/mnn-build" --target MNN MNNConvert --parallel 2
cmake --install "$WORK/mnn-build"

MNN_CONVERT="$(find "$WORK/mnn-build" -type f -name MNNConvert -perm -111 | head -1)"
[ -n "$MNN_CONVERT" ] || { echo "FATAL: MNNConvert was not built" >&2; exit 1; }
[ -f "$WORK/mnn-install/lib/libMNN.a" ] || {
  echo "FATAL: MNN install did not produce lib/libMNN.a" >&2
  exit 1
}

MODEL_OUTPUT="$OUTPUT_DIR/model.mnn"
MODEL_TEMP="$OUTPUT_DIR/model.mnn.incomplete"
rm -f "$MODEL_TEMP"
log "converting FP32 ONNX to weight-quantized MNN"
"$MNN_CONVERT" \
  -f ONNX \
  --modelFile "$MODEL_ONNX" \
  --MNNModel "$MODEL_TEMP" \
  --weightQuantBits=8 \
  --weightQuantBlock=64
[ -s "$MODEL_TEMP" ] || { echo "FATAL: converter produced no model" >&2; exit 1; }
mv -f "$MODEL_TEMP" "$MODEL_OUTPUT"

log "building the pinned host sherpa-mnn SenseVoice smoke test"
cmake -S "$WORK/mnn/apps/frameworks/sherpa-mnn" \
  -B "$WORK/sherpa-mnn-build" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DMNN_LIB_DIR="$WORK/mnn-install" \
  -DSHERPA_MNN_ENABLE_C_API=ON \
  -DSHERPA_MNN_ENABLE_BINARY=ON \
  -DSHERPA_MNN_BUILD_C_API_EXAMPLES=ON \
  -DSHERPA_MNN_ENABLE_TESTS=OFF \
  -DSHERPA_MNN_ENABLE_CHECK=OFF \
  -DSHERPA_MNN_ENABLE_PORTAUDIO=OFF \
  -DSHERPA_MNN_ENABLE_WEBSOCKET=OFF \
  -DSHERPA_MNN_ENABLE_TTS=OFF \
  -DSHERPA_MNN_ENABLE_SPEAKER_DIARIZATION=OFF \
  -DSHERPA_MNN_ENABLE_RKNN=OFF \
  -DSHERPA_MNN_ENABLE_GPU=OFF \
  -DSHERPA_MNN_ENABLE_DIRECTML=OFF \
  -DSHERPA_MNN_ENABLE_PYTHON=OFF
cmake --build "$WORK/sherpa-mnn-build" \
  --target sense-voice-cxx-api --parallel 2

SMOKE_BINARY="$WORK/sherpa-mnn-build/bin/sense-voice-cxx-api"
[ -x "$SMOKE_BINARY" ] || { echo "FATAL: smoke-test binary missing" >&2; exit 1; }

# The upstream example has a fixed relative fixture directory and filename.
# The loader reads MNN bytes, so the historical .onnx filename is harmless.
FIXTURE="$WORK/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
mkdir -p "$FIXTURE/test_wavs"
ln -s "$MODEL_OUTPUT" "$FIXTURE/model.int8.onnx"
cp "$TOKENS" "$FIXTURE/tokens.txt"
cp "$TEST_WAV" "$FIXTURE/test_wavs/en.wav"

log "running real SenseVoice recognition against the converted model"
(
  cd "$WORK"
  "$SMOKE_BINARY"
) 2>&1 | tee "$OUTPUT_DIR/smoke-test.log"
grep -Eq '^text: .+' "$OUTPUT_DIR/smoke-test.log" || {
  echo "FATAL: smoke test did not return non-empty text" >&2
  exit 1
}

cp "$TOKENS" "$OUTPUT_DIR/tokens.txt"
(
  cd "$OUTPUT_DIR"
  sha256sum model.mnn tokens.txt > SHA256SUMS
)

MODEL_OUTPUT_SHA256="$(sha256sum "$MODEL_OUTPUT" | cut -d' ' -f1)"
MODEL_OUTPUT_SIZE="$(stat -c '%s' "$MODEL_OUTPUT")"
log "model.mnn size: $MODEL_OUTPUT_SIZE bytes"
log "model.mnn sha256: $MODEL_OUTPUT_SHA256"
log "conversion and recognition smoke test passed"
