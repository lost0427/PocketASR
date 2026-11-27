enum ModelMirror { official, hfMirror, custom }

class DownloadSource {
  const DownloadSource({
    this.modelMirror = ModelMirror.official,
    this.customHost = '',
    this.githubPrefix = '',
  });

  static const String hfMirrorHost = 'hf-mirror.com';

  final ModelMirror modelMirror;
  final String customHost;
  final String githubPrefix;

  String? get huggingFaceHost => switch (modelMirror) {
    ModelMirror.official => null,
    ModelMirror.hfMirror => hfMirrorHost,
    ModelMirror.custom => _parseHost(customHost)?.$1,
  };

  String get githubPrefixUrl => _normalizePrefix(githubPrefix);

  String rewrite(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return url;
    if (uri.host == 'huggingface.co') {
      final target = switch (modelMirror) {
        ModelMirror.official => null,
        ModelMirror.hfMirror => (hfMirrorHost, null),
        ModelMirror.custom => _parseHost(customHost),
      };
      if (target == null) return url;
      final rewritten = target.$2 == null
          ? uri.replace(host: target.$1)
          : uri.replace(host: target.$1, port: target.$2);
      return rewritten.toString();
    }
    if (uri.host == 'github.com' ||
        uri.host == 'objects.githubusercontent.com') {
      final prefix = githubPrefixUrl;
      return prefix.isEmpty ? url : '$prefix$url';
    }
    return url;
  }

  static (String, int?)? _parseHost(String raw) {
    final value = raw.trim().replaceFirst(RegExp(r'^https?://'), '');
    final hostPart = value.split('/').first;
    if (hostPart.isEmpty) return null;
    final parts = hostPart.split(':');
    final host = parts.first;
    if (host.isEmpty) return null;
    return (host, parts.length > 1 ? int.tryParse(parts[1]) : null);
  }

  static String _normalizePrefix(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    if (!value.contains('://')) return 'https://$value/';
    return value.endsWith('/') ? value : '$value/';
  }
}
