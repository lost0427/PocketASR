# AGENTS.md

## Build & release honesty

- No native CrispASR/CrispEmbed libraries exist in this repo. The app ships
  `UnavailableAsrEngine` and `DeterministicEmbedder` stand-ins.
- `.github/workflows/release.yml` (tag `v*`) builds Windows release and uploads
  an artifact. Do not claim or fake native ASR/embedding builds.
- Android release is reserved/commented in that workflow. `flutter build apk
  --release` would produce an installable APK that bundles no native library and
  reports "transcription is unavailable" at runtime — keep it disabled until the
  `.so` artifacts actually land in `android/`.
- CI (`ci.yml`) runs `flutter analyze`, `flutter test`, and a Windows debug build.
