#!/usr/bin/env bash
#
# SPIKE / EXPERIMENT (branch feat/sherpa-mnn-native) — not wired into release.
#
# Build the sherpa-mnn C API for Android arm64-v8a from pinned MNN source, so
# the Phase 0 questions get answered from CI logs instead of guesswork:
#   - does MNN/sherpa-mnn still reference onnxruntime at configure time?
#   - which FetchContent deps get pulled (kaldi-native-fbank v1.21.1, ...)?
#   - what does libsherpa-mnn-c-api.so actually DT_NEEDED?
#   - is it 16KB LOAD-aligned?
#   - does it export SherpaMnnCreateOfflineRecognizer?
#
# sherpa-mnn lives inside the MNN repo at apps/frameworks/sherpa-mnn, so a
# single pinned clone feeds two cmake configure/build passes:
#   1. MNN runtime  -> $WORK/mnn-install (include/MNN/*.h + lib/libMNN.so)
#   2. sherpa-mnn   -> libsherpa-mnn-c-api.so (BUILD_SHARED_LIBS=ON)
#
# Decisions for the spike:
#   - MNN shipped SHARED (libMNN.so) exactly like the upstream README, to avoid
#     static-link unknown-symbol surprises; revisit if the APK gate complains.
#   - MNN_SEP_BUILD=OFF -> one libMNN.so instead of a pile of backend .so files.
#   - TTS/diarization/websocket/portaudio/GPU all OFF (only ASR is wanted; TTS
#     would drag in espeak-ng, GPL).
#   - MNN_BUILD_PROTOBUFFER=OFF: protobuf is a converter/tools concern; a shared
#     libMNN.so must not gain a libprotobuf.so DT_NEEDED we would have to stage.
#
# Models are NEVER downloaded or bundled here.
#
# Usage: bash scripts/ci/build_native_sherpa_mnn.sh [output-dir]
# Env overrides: MNN_REF, NDK_VERSION, ANDROID_HOME.
set -euo pipefail

MNN_URL="https://github.com/alibaba/MNN"
# Tag, not a SHA: the log prints the resolved commit, so the real pin is
# recorded on every run. Bump deliberately.
MNN_REF="${MNN_REF:-3.6.1}"

NDK_VERSION="${NDK_VERSION:-30.0.16248370}" # r30 LTS
ANDROID_ABI="arm64-v8a"
ANDROID_API="24"
PAGE_LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/android/app/src/main/jniLibs/$ANDROID_ABI}"
WORK="$ROOT/.native-work-sherpa-mnn"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

log() { echo "build_native_sherpa_mnn: $*"; }

# --- ccache ---
export CCACHE_DIR="${CCACHE_DIR:-$ROOT/.ccache-sherpa-mnn}"
export CCACHE_BASEDIR="$ROOT"
export CCACHE_COMPRESS=1
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-3G}"
export CCACHE_COMPILERCHECK=content
USE_CCACHE=0
if command -v ccache >/dev/null 2>&1; then
  USE_CCACHE=1
  mkdir -p "$CCACHE_DIR"
  ccache --zero-stats >/dev/null
else
  log "WARNING: ccache not on PATH, building without compiler cache"
fi

# --- NDK ---
: "${ANDROID_HOME:?ANDROID_HOME must be set (predefined on GitHub runners)}"
if [ ! -d "$ANDROID_HOME/ndk/$NDK_VERSION" ]; then
  SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
  [ -x "$SDKMANAGER" ] || SDKMANAGER="$ANDROID_HOME/tools/bin/sdkmanager"
  log "installing NDK $NDK_VERSION via sdkmanager"
  "$SDKMANAGER" --sdk_root="$ANDROID_HOME" "ndk;$NDK_VERSION" </dev/null
fi
NDK="$ANDROID_HOME/ndk/$NDK_VERSION"
TOOLCHAIN="$NDK/build/cmake/android.toolchain.cmake"
BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
SYSROOT="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
READELF="$BIN/llvm-readelf"
OBJDUMP="$BIN/llvm-objdump"
CLANG_RESOURCE_DIR="$("$BIN/clang++" -print-resource-dir)"

common_cmake=(
  -G Ninja
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN"
  -DANDROID_ABI="$ANDROID_ABI"
  -DANDROID_PLATFORM="android-$ANDROID_API"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DCMAKE_SHARED_LINKER_FLAGS="$PAGE_LDFLAGS"
)
if [ "$USE_CCACHE" = "1" ]; then
  common_cmake+=(
    -DCMAKE_C_COMPILER_LAUNCHER=ccache
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
  )
fi

clone_at() { # url ref dest
  git init -q "$3" && git -C "$3" remote add origin "$1"
  git -C "$3" fetch -q --depth 1 origin "refs/tags/$2"
  git -C "$3" checkout -q FETCH_HEAD
  git -C "$3" submodule update --init --recursive
}

# --- clone MNN (sherpa-mnn is inside it) ---
clone_at "$MNN_URL" "$MNN_REF" "$WORK/mnn"
MNN_COMMIT="$(git -C "$WORK/mnn" rev-parse HEAD)"
log "MNN $MNN_REF resolved to $MNN_COMMIT"
[ -d "$WORK/mnn/apps/frameworks/sherpa-mnn/sherpa-mnn" ] || {
  log "FATAL: apps/frameworks/sherpa-mnn missing at $MNN_REF"; exit 1; }

# --- stage 1: MNN runtime ---
log "configuring MNN runtime"
cmake -S "$WORK/mnn" -B "$WORK/mnn-build" "${common_cmake[@]}" \
  -DMNN_BUILD_SHARED_LIBS=ON \
  -DMNN_SEP_BUILD=OFF \
  -DMNN_LOW_MEMORY=ON \
  -DMNN_BUILD_CONVERTER=OFF \
  -DMNN_BUILD_TRAIN=OFF \
  -DMNN_BUILD_TOOLS=OFF \
  -DMNN_BUILD_TEST=OFF \
  -DMNN_BUILD_DEMO=OFF \
  -DMNN_BUILD_QUANTOOLS=OFF \
  -DMNN_BUILD_BENCHMARK=OFF \
  -DMNN_BUILD_PROTOBUFFER=OFF \
  -DMNN_BUILD_OPENCV=OFF \
  -DMNN_BUILD_LLM=OFF \
  -DMNN_BUILD_DIFFUSION=OFF \
  -DMNN_BUILD_AUDIO=OFF \
  -DMNN_JNI=OFF \
  -DMNN_VULKAN=OFF -DMNN_OPENCL=OFF -DMNN_OPENGL=OFF \
  -DMNN_METAL=OFF -DMNN_NNAPI=OFF -DMNN_CUDA=OFF \
  -DCMAKE_INSTALL_PREFIX="$WORK/mnn-install"
cmake --build "$WORK/mnn-build" --target MNN
cmake --install "$WORK/mnn-build"

log "MNN install tree:"
find "$WORK/mnn-install" -maxdepth 3 -type f | sort

# --- stage 2: sherpa-mnn C API ---
log "configuring sherpa-mnn C API"
cmake -S "$WORK/mnn/apps/frameworks/sherpa-mnn" -B "$WORK/sherpa-mnn-build" \
  "${common_cmake[@]}" \
  -DBUILD_SHARED_LIBS=ON \
  -DMNN_LIB_DIR="$WORK/mnn-install" \
  -DSHERPA_MNN_ENABLE_C_API=ON \
  -DSHERPA_MNN_ENABLE_BINARY=OFF \
  -DSHERPA_MNN_ENABLE_TESTS=OFF \
  -DSHERPA_MNN_ENABLE_CHECK=OFF \
  -DSHERPA_MNN_ENABLE_PORTAUDIO=OFF \
  -DSHERPA_MNN_ENABLE_WEBSOCKET=OFF \
  -DSHERPA_MNN_ENABLE_TTS=OFF \
  -DSHERPA_MNN_ENABLE_SPEAKER_DIARIZATION=OFF \
  -DSHERPA_MNN_ENABLE_RKNN=OFF \
  -DSHERPA_MNN_ENABLE_GPU=OFF \
  -DSHERPA_MNN_ENABLE_DIRECTML=OFF \
  -DSHERPA_MNN_ENABLE_PYTHON=OFF \
  -DSHERPA_MNN_BUILD_C_API_EXAMPLES=OFF
cmake --build "$WORK/sherpa-mnn-build" --target sherpa-mnn-c-api

# --- stage ---
mkdir -p "$OUT"
cp -Lf "$WORK/mnn-install/lib/libMNN.so" "$OUT/libMNN.so"
SHERPA_SO="$(find "$WORK/sherpa-mnn-build" -name 'libsherpa-mnn-c-api.so*' -type f | sort | tail -1)"
[ -n "$SHERPA_SO" ] || { log "FATAL: libsherpa-mnn-c-api.so not built"; exit 1; }
cp -Lf "$SHERPA_SO" "$OUT/libsherpa-mnn-c-api.so"

# NDK runtime deps AGP does not add for jniLibs inputs.
for lib in "$OUT"/*.so; do
  "$READELF" --dynamic "$lib" | grep -oE '\(NEEDED\) +Shared library: \[[^]]+\]' || true
done > "$WORK/needed.txt"
log "DT_NEEDED dump:"
cat "$WORK/needed.txt"
for dep in libc++_shared.so libomp.so; do
  grep -q "\[$dep\]" "$WORK/needed.txt" || continue
  case "$dep" in
    libc++_shared.so) src="$SYSROOT/usr/lib/aarch64-linux-android/$dep" ;;
    libomp.so)        src="$CLANG_RESOURCE_DIR/lib/linux/aarch64/$dep" ;;
  esac
  log "staging NDK runtime dependency $dep"
  cp -Lf "$src" "$OUT/$dep"
done

log "staged:"
ls -l "$OUT"

log "pre-check (authoritative run happens against the built APK):"
python3 "$ROOT/scripts/ci/verify_apk_native.py" "$OUT" \
  --require libsherpa-mnn-c-api.so \
  --require-symbol libsherpa-mnn-c-api.so:SherpaMnnCreateOfflineRecognizer \
  --report || log "NOTE: pre-check failed — inspect DT_NEEDED dump above"
