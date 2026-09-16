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

Android decodes formats supported by the device codecs. Windows uses bundled
FFmpeg for WAV, MP3, M4A and FLAC. Microphone capture requests mono 16 kHz WAV on both.
Tap the version seven times in Settings to open benchmarks using your own audio.

## Current limits

- Decoded audio stays in a temporary PCM file. Loudness scans, energy detection,
  VAD input and output use bounded buffers; ASR reads one configured window at a
  time (30 seconds by default). Audio-buffer memory no longer scales with file
  duration. Segment metadata and transcript text still grow with content, and
  temporary disk space grows with duration (16 kHz float32 is about 230 MB/hour).
- Cancellation is cooperative during Android decoding and an active native VAD
  or ASR call; the result is discarded and files cleaned after the call returns.
  Windows FFmpeg is terminated on cancellation.
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

For local Windows runs, stage the decoder after building (CI does this for both
debug artifacts and release ZIPs):

```powershell
flutter build windows --debug
./scripts/ci/stage_ffmpeg_windows.ps1 -Destination build/windows/x64/runner/Debug
```

The staging script verifies a pinned LGPL shared build's SHA-256 and bundles its
complete archive contents. See `native/FFMPEG-NOTICE.txt` for version and sources.

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
