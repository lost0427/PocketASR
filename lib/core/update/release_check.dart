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
    this.releaseUrl = '',
    this.sha256,
    this.size,
  });

  final String version;
  final String notes;

  /// Direct asset URL for this platform, or the release page when the asset is
  /// missing.
  final String downloadUrl;

  final String releaseUrl;

  /// SHA-256 of the asset, from GitHub's release digest, when available.
  final String? sha256;

  final int? size;
}

typedef ReleaseFetcher = Future<List<Map<String, Object?>>> Function();

typedef AssetNameResolver = String? Function(String tag);

/// Finds the newest application release on GitHub and the asset for this
/// platform. Model-only releases (`model-*`) are ignored.
class ReleaseChecker {
  ReleaseChecker({
    required this.currentVersion,
    ReleaseFetcher? fetch,
    AssetNameResolver? assetName,
  }) : _fetch = fetch ?? _fetchReleases,
       _assetName = assetName ?? defaultAssetName;

  final String currentVersion;
  final ReleaseFetcher _fetch;
  final AssetNameResolver _assetName;

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
      final expected = _assetName(tag);
      String? download;
      String? sha256;
      int? size;
      for (final asset in assets) {
        if (expected == null || asset['name'] != expected) continue;
        download = asset['browser_download_url'] as String?;
        final digest = asset['digest'];
        if (digest is String && digest.startsWith('sha256:')) {
          sha256 = digest.substring(7).toLowerCase();
        }
        size = asset['size'] as int?;
        if (download != null) break;
      }
      final releaseUrl = release['html_url'] as String? ?? '';
      return ReleaseInfo(
        version: version,
        notes: release['body'] as String? ?? '',
        downloadUrl: download ?? releaseUrl,
        releaseUrl: releaseUrl,
        sha256: download == null ? null : sha256,
        size: download == null ? null : size,
      );
    }
    return null;
  }

  static String? defaultAssetName(String tag) {
    if (Platform.isAndroid) return androidAssetName(tag, kCpuVariant);
    if (Platform.isWindows) return windowsAssetName(tag);
    return null;
  }

  static String androidAssetName(String tag, String variant) =>
      'pocket-asr-android-$tag${variant == 'i8mm' ? '' : '-legacy'}.apk';

  static String windowsAssetName(String tag) => 'pocket-asr-windows-$tag.zip';

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
