# AGENTS.md

## Build & release honesty

- Native CrispASR/CrispEmbed libraries are **not committed** to this repo. They
  are pinned, SHA-256-verified, and fetched at CI build time; `.so` files stay
  gitignored.
- `.github/workflows/release.yml` (tag `v*`) builds Windows and Android releases.
- **Windows** release bundles no native CrispASR/CrispEmbed: there is no Windows
  native fetch step, so the app ships `UnavailableAsrEngine` /
  `DeterministicEmbedder` stand-ins on Windows. Do not claim otherwise.
- **Android** CI and release run `scripts/ci/fetch_native_android.sh` before
  `flutter build apk`. It stages the pinned CrispASR `libcrispasr.so`
  (arm64-v8a) into `android/app/src/main/jniLibs/`; the workflow then asserts the
  library is packaged in the APK. The `crispembed` plugin's own
  `fetchCrispembedLibs` Gradle task bundles `libcrispembed.so` during the build —
  that is the only confirmed CrispEmbed mechanism, and no unverified
  version/asset is substituted for it.
- **Models are never built or downloaded by any workflow.** The APKs ship engine
  libraries only; users must supply model files at runtime (see
  `assets/model_allowlist.json`). Never present a build artifact as a model
  bundle or fabricate a model download.
- CI (`ci.yml`) runs `flutter analyze`, `flutter test`, and a Windows debug build
  on `windows-latest`, plus an Android debug APK build on `ubuntu-latest` that
  fetches and verifies `libcrispasr.so`.
