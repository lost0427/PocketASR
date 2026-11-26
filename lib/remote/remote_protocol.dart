import 'dart:io';

const int remoteProtocolVersion = 1;
const int remoteDefaultPort = 47821;
const String remotePairScheme = 'pocketasr';
const int remoteMaxJobBytes = 2 * 1024 * 1024 * 1024;
const int remoteMaxPendingJobs = 20;
const String remoteFilenameHeader = 'x-pocketasr-filename';

class RemoteHost {
  const RemoteHost({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.token = '',
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String token;

  bool get paired => token.isNotEmpty;

  RemoteHost copyWith({String? name, String? host, int? port, String? token}) =>
      RemoteHost(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        token: token ?? this.token,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'token': token,
  };

  factory RemoteHost.fromJson(Map<String, dynamic> json) => RemoteHost(
    id: json['id'] as String,
    name: json['name'] as String? ?? json['host'] as String? ?? '',
    host: json['host'] as String? ?? '',
    port: json['port'] as int? ?? remoteDefaultPort,
    token: json['token'] as String? ?? '',
  );
}

class RemotePairLink {
  const RemotePairLink({
    required this.hostId,
    required this.name,
    required this.host,
    required this.port,
    required this.code,
  });

  final String hostId;
  final String name;
  final String host;
  final int port;
  final String code;

  Uri toUri() => Uri(
    scheme: remotePairScheme,
    host: 'pair',
    queryParameters: {
      'id': hostId,
      'n': name,
      'h': host,
      'p': '$port',
      'c': code,
    },
  );

  static RemotePairLink? parse(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != remotePairScheme) return null;
    final hostId = uri.queryParameters['id'];
    final host = uri.queryParameters['h'];
    final port = int.tryParse(uri.queryParameters['p'] ?? '');
    final code = uri.queryParameters['c'];
    if (hostId == null ||
        hostId.isEmpty ||
        host == null ||
        host.isEmpty ||
        port == null ||
        port <= 0 ||
        code == null ||
        code.isEmpty) {
      return null;
    }
    return RemotePairLink(
      hostId: hostId,
      name: uri.queryParameters['n'] ?? host,
      host: host,
      port: port,
      code: code,
    );
  }
}

String defaultDeviceName() {
  final name = Platform.localHostname;
  if (name.isEmpty || name == 'localhost') {
    return Platform.isAndroid ? 'Android device' : 'PocketASR';
  }
  return name;
}
