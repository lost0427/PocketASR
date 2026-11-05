# Native libraries

PocketASR's Dart adapters (`lib/engine/`) are pure FFI bindings. The actual
native libraries are **not** committed to this repo — CI **builds them from
pinned upstream sources** and stages the result into `jniLibs`; they are loaded
at runtime. This file records where each engine comes from, how it is built,
and under which licenses.

| Adapter | Upstream | Dart package | Version | License | Native artifact |
|---|---|---|---|---|---|
| `CrispEmbedder` | [CrispStrobe/CrispEmbed](https://github.com/CrispStrobe/CrispEmbed) | `crispembed` | 0.16.1 | MIT | `libcrispembed.so` / `libcrispembed.dylib` / `crispembed.dll` |
| `SherpaEngine` | [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | `sherpa_onnx` | 1.13.8 | Apache-2.0 | bundled by the plugin (`sherpa-onnx-c-api` + `onnxruntime`) |
| Android decode | [mackron/dr_libs](https://github.com/mackron/dr_libs) (dr_mp3/dr_wav/dr_flac) | (JNI, no Dart package) | commit `dfe8377` | public domain / MIT-0 | `libpocketasr_decode.so` |
| Android decode | [xiph/speexdsp](https://github.com/xiph/speexdsp) (resampler + AGC) | (JNI) | 1.2.1 | BSD-3-Clause | same `libpocketasr_decode.so` |

`libpocketasr_decode.so` is PocketASR's own C bridge
(`native/decode/`). It decodes mp3/wav/flac in-process with dr_libs and runs
every path — including MediaCodec-decoded AAC/M4A — through one SpeexDSP
resampler + AGC chain, writing mono 16 kHz float32. SpeexDSP is built
**floating point**: its own source compiles the AGC out under `FIXED_POINT`
("doesn't work yet with fixed-point"), so a fixed-point AGC is not available
upstream.

## Current state

- **CrispEmbed**: no `.so`/`.dll` is committed. Both the Android and Windows CI
  build it from source. A missing native artifact remains an explicit
  availability error. `CrispEmbedder` throws
  `EmbedderUnavailableException` instead of falling back to
  `DeterministicEmbedder`.
- **sherpa-onnx**: the `sherpa_onnx` Flutter plugin bundles native libraries
  itself — Windows DLLs via `sherpa_onnx_windows`, and per-ABI Android packages
  (`sherpa_onnx_android_arm64`, …). `SherpaEngine` becomes available once the
  app is built for a platform the plugin covers; in a bare `flutter test` it may
  or may not resolve the library, so no test depends on it.
- **Android decode**: the same script builds `libpocketasr_decode.so` from the
  pinned dr_libs/SpeexDSP commits. When it is missing, `AudioDecodeChannel`
  falls back to MediaCodec (no AGC chain); desktop stays on FFmpeg.

## Android (arm64-v8a): built from source, 16KB-aligned

`android/app/build.gradle.kts` restricts ABIs to `arm64-v8a` and keeps the app
`src/main/jniLibs/<abi>/` source set, where the build stages the libraries.

**Why a source build replaced the prebuilt fetch.** The old
`scripts/ci/fetch_native_android.sh` (deleted) downloaded the upstream
`v0.16.1` Android tarball; its SHA-256 pin was genuine, but
inspection of those exact binaries shows every `PT_LOAD` is `p_align=0x1000`
(4 KB), not 16 KB. ELF LOAD alignment is fixed at **link time** (lld's
`-z,max-page-size`); there is no supported post-hoc fix — so 16 KB compliance
requires a rebuild, which is what `scripts/ci/build_native_android.sh` does.
No `patchelf`, no `pickFirst`: the shipped bytes are compiled for the contract.
Some Android 16 devices run a 4 KB compat mode, so 4 KB libraries are not
categorically "cannot install" — they are also not something to ship and rely
on. The old bundle additionally had a defect a rebuild makes impossible:
`libcrispembed.so` DT_NEEDEDed three `libggml*.so` siblings its plugin's fetch
never unpacked.

Pinned source revision (tag dereferenced to a commit SHA; submodule gitlink
asserted by the script):

| Repo | Tag | Commit | Pinned ggml (CrispStrobe/ggml) |
|---|---|---|---|
| CrispEmbed | v0.16.1 | `e6411e48bfd2572cc29a7c04eccee8a8153bef2e` | `0714117daca2471b00e09554c7eaa74a06b0b2c5` |

CrispEmbed statically embeds its own pinned ggml and no `libggml*.so` is ever
packaged.

Build contract (options verified against the pinned tag's `CMakeLists.txt`):

- NDK **r30 LTS (`30.0.16248370`)** — any r28+ qualifies (lld 16 KB default
  landed in r27); ABI `arm64-v8a`, API `android-24`, CPU-only ggml backends,
  CMake + Ninja.
- Link flags: `-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384`.
- CrispEmbed: `-DBUILD_SHARED_LIBS=OFF -DCRISPEMBED_BUILD_SHARED=ON
  -DGGML_LLAMAFILE=OFF -DGGML_OPENMP=OFF -DCRISPEMBED_NATIVE=OFF`, target
  `crispembed-shared`. Its ggml goes static under that same
  `BUILD_SHARED_LIBS=OFF` (the shared target is declared with an explicit
  `SHARED` keyword), producing one self-contained `libcrispembed.so`. Built
  with `-fvisibility=hidden -fvisibility-inlines-hidden`; this is safe because
  every public symbol is marked `CRISPEMBED_API`
  (`__attribute__((visibility("default")))` under `CRISPEMBED_BUILD`, which the
  shared target defines).
- The `crispembed` plugin's `fetchCrispembedLibs` Gradle task uses the `Project.exec`
  API removed in Gradle 9 and is disabled in `android/app/build.gradle.kts`.
  Nothing in this project's build downloads CrispEmbed; do not describe the
  plugin as fetching anything.
- **NDK runtime deps are staged explicitly** (AGP does not add them for plain
  `jniLibs` inputs): `libc++_shared.so` / `libomp.so` are copied from the NDK
  sysroot only if a built library's `DT_NEEDED` actually requests one.

### Release gates (before any artifact upload)

1. `scripts/ci/verify_apk_native.py <apk>` — every `lib/arm64-v8a/*.so`:
   `PT_LOAD` `p_align >= 16384` and `p_offset ≡ p_vaddr (mod 16384)`; full
   `DT_NEEDED` closure against "bundled or known Android system library";
   required libraries and required exported symbols
   (`crispembed_init`, `pocketasr_chain_begin`). Covers
   third-party `.so` in the APK too (flutter, sherpa-onnx).
2. `zipalign -c -P 16 4 <apk>` from the newest installed build-tools.
3. A `.so` entry in the APK must be STORED (uncompressed) and 16KB-aligned
   within the archive (the offset padded by `zipalign -P 16`, so the loader
   can `mmap` it in place).

Any failure fails the job — `release.yml`'s `publish` job needs `android`, so a
failing gate means **no release is published**. The release workflow caches
`jniLibs/arm64-v8a` keyed on the build script's own hash. A cache hit reuses
those outputs; a miss rebuilds every native library from pinned source.

Historical prebuilt asset (audit record — **not** used by any current
workflow): `crispembed-android-arm64-v8a.tar.gz` (v0.16.1) sha256
`bc6f61d501a95aeefb2dff54b82ca34e5e84ad21ed748604004e984f6a3b1334`.

## Windows

The release workflow builds the x64 CPU `crispembed.dll` from CrispEmbed
v0.16.1 commit `e6411e48bfd2572cc29a7c04eccee8a8153bef2e` and asserts its
`ggml` gitlink is `0714117daca2471b00e09554c7eaa74a06b0b2c5`. The build uses
`BUILD_SHARED_LIBS=OFF`, so CrispEmbed's pinned ggml is linked into the DLL
rather than shipped as a second ABI surface. BLAS, CUDA, Vulkan, llamafile and
OpenMP are disabled, as are host-native and AVX512 compilation; the portable
Windows x64 build uses an AVX2 CPU baseline instead of inheriting the release
runner's instruction set. The ignored staging path is
`native/windows/crispembed.dll`; the application CMake installs it beside
`pocket_asr.exe`, where the Dart FFI loader resolves it by name.

`scripts/ci/verify_windows_native.ps1` loads the DLL from the final Release
bundle, which checks its immediate dependency closure, and verifies every
export eagerly bound by the Dart embedding constructor plus the query/passage
metadata-prefix exports. The release workflow caches the staged DLL by the
Windows build script hash. No model is downloaded or bundled.

Speech recognition on Windows runs through SherpaEngine, which is available
there because the `sherpa_onnx` plugin bundles its Windows DLLs
(`sherpa_onnx_windows`) automatically.

## Models are never built or downloaded

No workflow compiles or downloads any model. Every artifact above is an engine
library; users supply model files at runtime (see `assets/model_allowlist.json`).

## Why no fallback

Both adapters fail loudly. A missing ASR library must never emit placeholder
text, and a missing embedder must never fall back to `DeterministicEmbedder` —
that would make semantic search return plausible-but-meaningless hits. Honest
unavailability is a feature here, not a gap.
