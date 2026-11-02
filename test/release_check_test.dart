import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/update/release_check.dart';

void main() {
  Map<String, Object?> release({
    required String tag,
    List<Map<String, Object?>> assets = const [],
    bool draft = false,
    bool prerelease = false,
  }) => {
    'tag_name': tag,
    'draft': draft,
    'prerelease': prerelease,
    'body': 'notes',
    'html_url': 'https://github.com/lost0427/PocketASR/releases/tag/$tag',
    'assets': assets,
  };

  test('finds the newest application release and the legacy APK', () async {
    final checker = ReleaseChecker(
      currentVersion: '1.0.27',
      fetch: () async => [
        release(tag: 'model-sherpa-mnn-sensevoice-q8-v2'),
        release(
          tag: 'v1.0.29',
          assets: [
            {
              'name': 'pocket-asr-android-v1.0.29.apk',
              'browser_download_url': 'https://example.com/i8mm.apk',
            },
            {
              'name': 'pocket-asr-android-v1.0.29-legacy.apk',
              'browser_download_url': 'https://example.com/legacy.apk',
            },
          ],
        ),
      ],
    );

    final info = await checker.check();
    expect(info, isNotNull);
    expect(info!.version, '1.0.29');
    expect(info.downloadUrl, 'https://example.com/legacy.apk');
    expect(info.notes, 'notes');
  });

  test('ignores drafts, prereleases and non-version tags', () async {
    final checker = ReleaseChecker(
      currentVersion: '1.0.27',
      fetch: () async => [
        release(tag: 'v1.0.31', draft: true),
        release(tag: 'v1.0.30', prerelease: true),
        release(tag: 'model-only-v9'),
        release(
          tag: 'v1.0.29',
          assets: [
            {
              'name': 'pocket-asr-android-v1.0.29-legacy.apk',
              'browser_download_url': 'https://example.com/legacy.apk',
            },
          ],
        ),
      ],
    );

    expect((await checker.check())?.version, '1.0.29');
  });

  test(
    'returns null when the latest application release is not newer',
    () async {
      final checker = ReleaseChecker(
        currentVersion: '1.0.27',
        fetch: () async => [release(tag: 'v1.0.27')],
      );
      expect(await checker.check(), isNull);
    },
  );

  test(
    'falls back to the release page when the APK asset is missing',
    () async {
      final checker = ReleaseChecker(
        currentVersion: '1.0.27',
        fetch: () async => [release(tag: 'v1.0.29')],
      );
      final info = await checker.check();
      expect(info!.downloadUrl, contains('/releases/tag/v1.0.29'));
    },
  );

  test('asset name follows the CPU variant', () {
    expect(
      ReleaseChecker.androidAssetName('v1.0.29', 'i8mm'),
      'pocket-asr-android-v1.0.29.apk',
    );
    expect(
      ReleaseChecker.androidAssetName('v1.0.29', 'legacy'),
      'pocket-asr-android-v1.0.29-legacy.apk',
    );
  });

  test('version comparison is numeric', () {
    expect(ReleaseChecker.isNewerVersion('1.0.29', '1.0.27'), isTrue);
    expect(ReleaseChecker.isNewerVersion('1.0.27', '1.0.27'), isFalse);
    expect(ReleaseChecker.isNewerVersion('1.0.9', '1.0.10'), isFalse);
    expect(ReleaseChecker.isNewerVersion('1.1.0', '1.0.99'), isTrue);
  });
}
