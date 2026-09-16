# PocketASR

On-device speech recognition, built with Flutter.

Currently a bare Flutter scaffold targeting Android only.

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
