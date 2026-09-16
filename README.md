# PocketASR

On-device speech recognition, built with Flutter.

Targets Android and Windows, with local transcription, microphone recording,
batch queues, searchable history, model downloads and a hidden benchmark page.

## Using the app

1. Download and select an ASR bundle on the Models page, or select local model files.
2. Pick audio or record from the microphone, then start transcription. Completed
   recordings remain in the application's documents directory; discarding an
   unfinished recording removes its file.
3. Results are saved in History. Select an embedding model for semantic search;
   literal search works without one. Configure loudness and chunking in Settings.

Android decodes formats supported by the device codecs; Windows currently
accepts PCM/float WAV. Microphone capture requests mono 16 kHz WAV on both.
Tap the version seven times in Settings to open benchmarks using your own audio.

## Current limits

- Desktop WAV decoding and loudness processing run off the UI thread. WAV output
  is written in bounded blocks, but decoded PCM is still held in memory: long
  recordings are **not** processed with bounded total memory yet.
- Windows bundles Sherpa's native runtime; CrispASR/CrispEmbed DLLs are not
  bundled by the release workflow. Their features require those native libraries.
- CPU is the supported inference backend. Vulkan and NPU are not implemented.
- Local automated tests and builds do not establish microphone/device behavior
  or real-model recognition quality. Android native source builds and 16 KB APK
  verification must succeed in CI before a release can be considered validated.

## Requirements

- Flutter 3.47.x (stable), Dart 3.13.x
- Android SDK for building/running

## Commands

```sh
flutter pub get     # install dependencies
flutter run         # run on a connected Android device or emulator
flutter analyze     # static analysis
flutter test        # run tests
```

## Native libraries

The CrispASR/CrispEmbed engine libraries are **not committed**. CI builds them
from pinned upstream commits with NDK r28+ so every shipped `.so` is
16KB-page-aligned, and gates the APK on ELF alignment, `DT_NEEDED` closure and
zipalign before any release is published:

```sh
bash scripts/ci/build_native_android.sh          # requires Linux + Android SDK
python3 scripts/ci/verify_apk_native.py app.apk  # the release gate
```

See `native/README.md` for pins, build flags and licenses. The `sherpa_onnx`
plugin bundles its own native libraries (including on Windows). Model files
are never downloaded by CI — users supply them at runtime.
