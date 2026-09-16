# AGENTS.md

## Build & release honesty

- Native CrispASR/CrispEmbed libraries are **not committed** to this repo.
  `.so` files stay gitignored. The Android release **builds them from pinned
  source** (commit SHAs, submodule pins asserted) — the old prebuilt-tarball
  fetch (`fetch_native_android.sh`) is deleted: its SHA-256s were genuine but
  the binaries were only 4KB LOAD-aligned, and 16KB alignment is a link-time
  property that cannot be fixed post-hoc (no patchelf, no pickFirst).
- `.github/workflows/release.yml` (tag `v*`) builds Windows and Android releases.
- **Windows** release bundles no native CrispASR/CrispEmbed: there is no Windows
  native build step, so the Crisp adapters report unavailable and the default
  engine/embedder are the `UnavailableAsrEngine` / `DeterministicEmbedder`
  stand-ins. That is not "no ASR on Windows": **SherpaEngine works there** —
  its DLLs are bundled by the `sherpa_onnx` plugin (`sherpa_onnx_windows`).
- **Android** release restores a matching native cache or runs
  `scripts/ci/build_native_android.sh` before `flutter build apk`: NDK r28+
  (r30 LTS pinned), arm64-v8a / android-24,
  16KB `max-page-size` link flags; each engine statically embeds its own
  pinned ggml (the two repos pin **different** ggml commits and the versions
  are never shared), and needed NDK runtimes (`libc++_shared.so` /
  `libomp.so`) are staged explicitly — AGP does not add them for jniLibs.
  Before any artifact is uploaded, `scripts/ci/verify_apk_native.py` checks
  every `lib/arm64-v8a/*.so` for `PT_LOAD` `p_align >= 16K` with
  offset≡vaddr (mod 16K), full `DT_NEEDED` closure and required exports, and
  `zipalign -c -P 16 4` must pass. A failed gate fails the job, so **no
  release is published**. Do not describe the `crispembed` plugin as fetching
  anything: its `fetchCrispembedLibs` task uses the `Project.exec` API removed
  in Gradle 9 and is disabled in `android/app/build.gradle.kts`.
- **Models are never built or downloaded by any workflow.** The APKs ship engine
  libraries only; users must supply model files at runtime (see
  `assets/model_allowlist.json`). Never present a build artifact as a model
  bundle or fabricate a model download.
- CI (`ci.yml`) runs `flutter analyze` and `flutter test` on `windows-latest`.
  Release builds Windows and Android in parallel, then publishes only after
  both jobs succeed; CI does not build or upload debug artifacts.
- API 36 / AGP 9.1 / Gradle 9.3.1 is the intended toolchain; do not downgrade
  to work around plugin issues — disable the offending task and stage outputs.
- The retired 4KB-aligned prebuilts are **not** "cannot install" claims: some
  Android 16 devices offer 4KB back-compat, so say "4KB-aligned, 16KB devices
  not guaranteed" — never the stronger or the weaker lie.
