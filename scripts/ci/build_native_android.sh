#!/usr/bin/env bash
#
# Build the 16KB-page-aligned native Android libraries for PocketASR from
# pinned upstream sources, and stage them into the Flutter app's jniLibs.
#
# This REPLACES the retired fetch of upstream prebuilt tarballs
# (scripts/ci/fetch_native_android.sh, deleted): the pinned v0.8.32 /
# v0.16.1 prebuilt assets were SHA-256-genuine but only 4KB LOAD-aligned
# (measured: p_align=0x1000), which is not safe to ship for Android 16's
# 16KB-page devices. Some Android 16 devices run a 4KB compat mode, so we
# never claimed "cannot install" — we simply refuse to rely on it.
# 16KB ELF alignment is a LINK-TIME property (lld -z,max-page-size): there
# is no supported post-hoc fix, so the libraries must be rebuilt. No
# patchelf, no packaging tricks.
#
# Sources are pinned by full commit SHA (tags dereferenced, recorded 2026-09):
#   CrispASR   v0.8.32  -> e2a356146e36bc1cc0410edefb01990448766979
#   CrispEmbed v0.16.1  -> e6411e48bfd2572cc29a7c04eccee8a8153bef2e
# Each repo pins its OWN ggml fork commit (5049ebb… vs 0714117…), i.e. two
# different ggml trees. A matching exported-symbol set does NOT prove ABI
# compatibility between ggml builds, so the two ggml versions must never be
# shared between the libraries: each engine embeds its own pinned ggml
# statically and no libggml*.so sibling is ever shipped. Mechanisms,
# verified against the CMakeLists.txt of the pinned tags:
#   CrispEmbed: -DBUILD_SHARED_LIBS=OFF leaves its ggml targets static while
#     `crispembed-shared` is declared with an explicit SHARED keyword ->
#     libcrispembed.so bakes its ggml in. -fvisibility=hidden is safe because
#     crispembed.h marks the whole C API with CRISPEMBED_API
#     __attribute__((visibility("default"))) under CRISPEMBED_BUILD.
#   CrispASR: `crispasr-lib` is a keywordless target (follows
#     BUILD_SHARED_LIBS), so a single knob cannot give shared-crispasr +
#     static-ggml. Its root CMake supports find_package(ggml) via
#     -DCRISPASR_USE_SYSTEM_GGML=ON, so we build the repo's OWN pinned ggml
#     submodule statically first and feed it back: libcrispasr.so links the
#     static ggml archives and gains no ggml DT_NEEDED. Package location must
#     be passed as -Dggml_DIR, NOT -DCMAKE_PREFIX_PATH: the NDK toolchain sets
#     CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY (CMake's Android-Initialize.cmake
#     does too), which re-roots every config-mode search path — including
#     CMAKE_PREFIX_PATH — under the NDK sysroot, so the freshly installed
#     prefix is never searched and find_package(ggml REQUIRED) fails with
#     "Could not find a package configuration file provided by ggml" even
#     though ggml-config.cmake was installed (android/ndk#2048). <pkg>_DIR is
#     used as-is and is the targeted workaround (the other one, because it
#     loosens host searching for every package, is
#     -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH). The tree is not
#     visibility-hidden (crispasr.h's CRISPASR_API path exists, but the C
#     API's annotation coverage was not verified; exporting more than needed
#     is the status quo of the old bundle and safe under RTLD_LOCAL since
#     libcrispembed.so is the only other ggml holder and its copies are
#     hidden).
#
# Models are NEVER downloaded or bundled here (or anywhere in CI): users
# supply model files at runtime (assets/model_allowlist.json).
#
# Usage (ubuntu-latest GitHub runner):
#   bash scripts/ci/build_native_android.sh [output-dir]
# Env overrides: NDK_VERSION, ANDROID_HOME.
set -euo pipefail

CRISPASR_URL="https://github.com/CrispStrobe/CrispASR"
CRISPASR_COMMIT="e2a356146e36bc1cc0410edefb01990448766979" # v0.8.32
CRISPASR_GGML="5049ebb8472fdc965eb3fb72c1cb111260726186"   # pinned gitlink (CrispStrobe/ggml)

CRISPEMBED_URL="https://github.com/CrispStrobe/CrispEmbed"
CRISPEMBED_COMMIT="e6411e48bfd2572cc29a7c04eccee8a8153bef2e" # v0.16.1
CRISPEMBED_GGML="0714117daca2471b00e09554c7eaa74a06b0b2c5"   # pinned gitlink (CrispStrobe/ggml)

# NDK r28+ defaults to 16KB alignment; explicit flags below preserve the
# requirement independently of upstream defaults.
NDK_VERSION="${NDK_VERSION:-30.0.16248370}" # r30 LTS
ANDROID_ABI="arm64-v8a"
ANDROID_API="24"                            # minSdk floor, unchanged
PAGE_LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/android/app/src/main/jniLibs/$ANDROID_ABI}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { echo "build_native_android: $*"; }

# --- ccache ---
# The build runs in a throwaway mktemp WORK dir, so every cache miss would
# otherwise recompile both engines and both pinned ggml trees from zero.
# ccache makes those compiles reusable across runs. Sources and NDK are
# pinned; CCACHE_COMPILERCHECK=content guards against a re-provisioned
# toolchain reusing stale object files.
export CCACHE_DIR="${CCACHE_DIR:-$ROOT/.ccache}"
export CCACHE_BASEDIR="$ROOT"
export CCACHE_COMPRESS=1
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}"
export CCACHE_COMPILERCHECK=content
command -v ccache >/dev/null 2>&1 || { log "FATAL: ccache not on PATH"; exit 1; }
mkdir -p "$CCACHE_DIR"
ccache --zero-stats >/dev/null

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
# OpenMP is a clang resource-dir artifact, NOT a sysroot library:
#   <resource-dir>/lib/linux/aarch64/libomp.so
# (libc++_shared.so, by contrast, really does live in the sysroot.) The
# resource dir is version/host-dependent (`lib` vs `lib64`, clang 12 vs 21),
# so ask the compiler instead of guessing the path.
CLANG_RESOURCE_DIR="$("$BIN/clang++" -print-resource-dir)"
common_cmake=(
  -G Ninja
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN"
  -DANDROID_ABI="$ANDROID_ABI"
  -DANDROID_PLATFORM="android-$ANDROID_API"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DCMAKE_C_COMPILER_LAUNCHER=ccache
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
  -DCMAKE_SHARED_LINKER_FLAGS="$PAGE_LDFLAGS"
)

clone_at() { # url commit dest
  git init -q "$3" && git -C "$3" remote add origin "$1"
  git -C "$3" fetch -q --depth 1 origin "$2"
  git -C "$3" checkout -q FETCH_HEAD
  git -C "$3" submodule update --init --recursive
}

# --- CrispASR: pinned ggml (static) -> libcrispasr.so with ggml baked in ---
clone_at "$CRISPASR_URL" "$CRISPASR_COMMIT" "$WORK/crispasr"
[ "$(git -C "$WORK/crispasr" rev-parse :ggml)" = "$CRISPASR_GGML" ] || {
  log "FATAL: CrispASR ggml gitlink != $CRISPASR_GGML"; exit 1; }

cmake -S "$WORK/crispasr/ggml" -B "$WORK/ggml-static" "${common_cmake[@]}" \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_BUILD_TESTS=OFF \
  -DGGML_BUILD_EXAMPLES=OFF \
  -DCMAKE_INSTALL_PREFIX="$WORK/ggml-static-prefix"
cmake --build "$WORK/ggml-static"
cmake --install "$WORK/ggml-static"

cmake -S "$WORK/crispasr" -B "$WORK/crispasr-build" "${common_cmake[@]}" \
  -DBUILD_SHARED_LIBS=ON \
  -DCRISPASR_USE_SYSTEM_GGML=ON \
  -Dggml_DIR="$WORK/ggml-static-prefix/lib/cmake/ggml" \
  -DCRISPASR_BUILD_TESTS=OFF \
  -DCRISPASR_BUILD_EXAMPLES=OFF \
  -DCRISPASR_BUILD_SERVER=OFF \
  -DCRISPASR_OPUS=OFF \
  -DCRISPASR_AMR=OFF \
  -DCMAKE_SHARED_LINKER_FLAGS="$PAGE_LDFLAGS -L$WORK/ggml-static-prefix/lib"
cmake --build "$WORK/crispasr-build" --target crispasr-lib

# --- CrispEmbed: one shared lib, its own ggml static + internals hidden ---
clone_at "$CRISPEMBED_URL" "$CRISPEMBED_COMMIT" "$WORK/crispembed"
[ "$(git -C "$WORK/crispembed" rev-parse :ggml)" = "$CRISPEMBED_GGML" ] || {
  log "FATAL: CrispEmbed ggml gitlink != $CRISPEMBED_GGML"; exit 1; }

cmake -S "$WORK/crispembed" -B "$WORK/crispembed-build" "${common_cmake[@]}" \
  -DBUILD_SHARED_LIBS=OFF \
  -DCRISPEMBED_BUILD_SHARED=ON \
  -DGGML_LLAMAFILE=OFF \
  -DGGML_OPENMP=OFF \
  -DCRISPEMBED_NATIVE=OFF \
  -DCMAKE_C_FLAGS="-fvisibility=hidden" \
  -DCMAKE_CXX_FLAGS="-fvisibility=hidden -fvisibility-inlines-hidden"
cmake --build "$WORK/crispembed-build" --target crispembed-shared

# --- stage (cp -L resolves CMake's unversioned .so symlinks to real files) ---
mkdir -p "$OUT"
cp -Lf "$(find "$WORK/crispasr-build/src" -maxdepth 1 -name 'libcrispasr.so*' -type f | sort | tail -1)" "$OUT/libcrispasr.so"
cp -Lf "$(find "$WORK/crispembed-build" -maxdepth 1 -name 'libcrispembed.so*' -type f | sort | tail -1)" "$OUT/libcrispembed.so"

# --- NDK runtime deps are NOT bundled by AGP for jniLibs inputs: stage
# whatever the built libraries actually request (libc++_shared.so / libomp.so
# land here; a DT_NEEDED that is neither of these fails the APK gate later).
for lib in "$OUT"/*.so; do
  "$READELF" --dynamic "$lib" | grep -oE '\(NEEDED\) +Shared library: \[[^]]+\]' || true
done > "$WORK/needed.txt"
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
log "ccache stats:"
ccache --show-stats

log "pre-check (the authoritative run happens against the built APK):"
python3 "$ROOT/scripts/ci/verify_apk_native.py" "$OUT" \
  --require libcrispasr.so --require libcrispembed.so \
  --require-symbol libcrispasr.so:whisper_full \
  --require-symbol libcrispembed.so:crispembed_init
