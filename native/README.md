# Native libraries

PocketASR's Dart adapters (`lib/engine/`) are pure FFI bindings. The actual
native libraries are **not** committed to this repo — they are pinned, fetched
by CI, and loaded at runtime. This file records where each engine comes from so
the versions and licenses are auditable.

| Adapter | Upstream | Dart package | Version | License | Native artifact |
|---|---|---|---|---|---|
| `CrispAsrEngine` | [CrispStrobe/CrispASR](https://github.com/CrispStrobe/CrispASR) | `crispasr` | 0.8.32 | MIT | `libcrispasr.so` / `libcrispasr.dylib` / `crispasr.dll` |
| `CrispEmbedder` | [CrispStrobe/CrispEmbed](https://github.com/CrispStrobe/CrispEmbed) | `crispembed` | 0.16.1 | MIT | `libcrispembed.so` / `libcrispembed.dylib` / `crispembed.dll` |
| `SherpaEngine` | [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | `sherpa_onnx` | 1.13.8 | Apache-2.0 | bundled by the plugin (`sherpa-onnx-c-api` + `onnxruntime`) |

## Current state

- **CrispASR / CrispEmbed**: no `.so`/`.dll` is bundled yet. The adapters report
  `EngineCapabilities.unavailable` with a clear reason and never fabricate text
  or embeddings. `CrispEmbedder` throws `EmbedderUnavailableException` instead
  of falling back to `DeterministicEmbedder`.
- **sherpa-onnx**: the `sherpa_onnx` Flutter plugin bundles native libraries
  itself — Windows DLLs via `sherpa_onnx_windows`, and per-ABI Android packages
  (`sherpa_onnx_android_arm64`, …). `SherpaEngine` becomes available once the
  app is built for a platform the plugin covers; in a bare `flutter test` it may
  or may not resolve the library, so no test depends on it.

## Android (arm64-v8a)

`android/app/build.gradle.kts` restricts ABIs to `arm64-v8a` and keeps the
app `src/main/jniLibs/<abi>/` source set, which is where fetched libs land.

Fetch the pinned CrispASR library (verifies SHA-256, extracts, copies `.so`
into `android/app/src/main/jniLibs/arm64-v8a/`):

```bash
scripts/ci/fetch_native_android.sh
```

The script deliberately does **not** re-download CrispEmbed: the `crispembed`
Flutter plugin's own `android/build.gradle` runs a `fetchCrispembedLibs` task on
`preBuild` that downloads its prebuilt `.so` (from `v0.16.0`, the version its
Gradle metadata declares) into its package `jniLibs`. Pass
`--with-crispembed` to force the pinned CrispEmbed `v0.16.1` asset instead.
`.so` files are gitignored and must never be committed.

Pinned CrispASR assets (from the `v0.8.32` release):

- `crispasr-android-arm64-v8a.tar.gz`
  sha256 `c1a3478ed7c0ad47077ecb8f8c600068b78674aa56c98a6c366108a3a09dd8fc`
- `libcrispasr-windows-x86_64.tar.gz`
  sha256 `3c2bccdd7e02ac5c526a744628f08b2ce6333f29c03804340fba8d131001b9b9`

Pinned CrispEmbed `v0.16.1` asset (opt-in):

- `crispembed-android-arm64-v8a.tar.gz`
  sha256 `bc6f61d501a95aeefb2dff54b82ca34e5e84ad21ed748604004e984f6a3b1334`

## Windows

The release workflow builds a Windows app. To enable CrispASR there, download
`libcrispasr-windows-x86_64.tar.gz` from the CrispASR `v0.8.32` release and put
its DLLs next to the built executable (`build/windows/x64/runner/Release/`).
CrispEmbed's Windows plugin looks for `windows/lib/crispembed.dll`; without a
staged `crispembed-windows-x86_64.zip` it warns and bundles nothing. sherpa-onnx
Windows DLLs are bundled automatically by the plugin.

## Why no fallback

Both adapters fail loudly. A missing ASR library must never emit placeholder
text, and a missing embedder must never fall back to `DeterministicEmbedder` —
that would make semantic search return plausible-but-meaningless hits. Honest
unavailability is a feature here, not a gap.
