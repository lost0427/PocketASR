import 'dart:convert';
import 'dart:io';

/// Compile-time CPU variant of this APK, set by CI via
/// `--dart-define=POCKETASR_VARIANT=i8mm`; local builds default to the
/// baseline APK that installs on every arm64 device.
const String kCpuVariant = String.fromEnvironment(
  'POCKETASR_VARIANT',
  defaultValue: 'legacy',
);

class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.notes,
    required this.downloadUrl,
  });

  final String version;
  final String notes;

  /// Direct APK asset URL, or the release page when the asset is missing.
  final String downloadUrl;
}

typedef ReleaseFetcher = Future<List<Map<String, Object?>>> Function();

/// Finds the newest application release on GitHub and the APK for this
/// variant. Model-only releases (`model-*`) are ignored.
class ReleaseChecker {
  ReleaseChecker({required this.currentVersion, ReleaseFetcher? fetch})
    : _fetch = fetch ?? _fetchReleases;

  final String currentVersion;
  final ReleaseFetcher _fetch;

  Future<ReleaseInfo?> check() async {
    final releases = await _fetch();
    for (final release in releases) {
      if (release['draft'] == true || release['prerelease'] == true) continue;
      final tag = release['tag_name'];
      if (tag is! String) continue;
      final match = RegExp(r'^v(\d+\.\d+\.\d+)$').firstMatch(tag);
      if (match == null) continue;
      final version = match.group(1)!;
      if (!isNewerVersion(version, currentVersion)) return null;
      final assets = (release['assets'] as List? ?? const [])
          .whereType<Map>()
          .map((asset) => asset.cast<String, Object?>())
          .toList();
      final expected = androidAssetName(tag, kCpuVariant);
      String? download;
      for (final asset in assets) {
        if (asset['name'] == expected) {
          download = asset['browser_download_url'] as String?;
          if (download != null) break;
        }
      }
      final releaseUrl = release['html_url'] as String? ?? '';
      return ReleaseInfo(
        version: version,
        notes: release['body'] as String? ?? '',
        downloadUrl: download ?? releaseUrl,
      );
    }
    return null;
  }

  static String androidAssetName(String tag, String variant) =>
      'pocket-asr-android-$tag${variant == 'i8mm' ? '' : '-legacy'}.apk';

  static bool isNewerVersion(String candidate, String current) {
    final left = candidate.split('.').map(int.parse).toList();
    final right = current.split('.').map(int.parse).toList();
    for (var index = 0; index < 3; index++) {
      final a = index < left.length ? left[index] : 0;
      final b = index < right.length ? right[index] : 0;
      if (a != b) return a > b;
    }
    return false;
  }

  static Future<List<Map<String, Object?>>> _fetchReleases() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse(
          'https://api.github.com/repos/lost0427/PocketASR/releases?per_page=30',
        ),
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'PocketASR');
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('GitHub returned ${response.statusCode}');
      }
      final decoded = jsonDecode(await response.transform(utf8.decoder).join());
      if (decoded is! List) {
        throw const FormatException('Unexpected GitHub response');
      }
      return [
        for (final item in decoded.whereType<Map>())
          item.cast<String, Object?>(),
      ];
    } finally {
      client.close(force: true);
    }
  }
}
