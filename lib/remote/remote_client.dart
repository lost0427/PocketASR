import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'remote_protocol.dart';

class RemoteClientException implements Exception {
  const RemoteClientException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class RemoteClient {
  RemoteClient({
    required this.host,
    required this.port,
    this.token = '',
    this.timeout = const Duration(seconds: 5),
  });

  final String host;
  final int port;
  final String token;
  final Duration timeout;

  Uri _uri(String path) =>
      Uri(scheme: 'http', host: host, port: port, path: path);

  Future<Map<String, dynamic>> hello() => _request('GET', '/v1/hello');

  Future<Map<String, dynamic>> pair({
    required String code,
    required String deviceName,
  }) => _request(
    'POST',
    '/v1/pair',
    body: {'code': code, 'deviceName': deviceName},
    authorize: false,
  );

  Future<List<Map<String, dynamic>>> jobs() async {
    final body = await _request('GET', '/v1/jobs');
    final list = body['jobs'];
    if (list is! List) return [];
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) item,
    ];
  }

  Future<Map<String, dynamic>> job(String id) =>
      _request('GET', '/v1/jobs/${Uri.encodeComponent(id)}');

  Future<void> cancel(String id) =>
      _request('POST', '/v1/jobs/${Uri.encodeComponent(id)}/cancel');

  Future<void> ack(String id) =>
      _request('POST', '/v1/jobs/${Uri.encodeComponent(id)}/ack');

  Future<Map<String, dynamic>> upload(
    String path,
    String filename, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final file = File(path);
    final total = await file.length();
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.openUrl('POST', _uri('/v1/jobs'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(remoteFilenameHeader, Uri.encodeComponent(filename));
      request.headers.contentType = ContentType.binary;
      request.contentLength = total;
      var sent = 0;
      await request.addStream(
        file.openRead().map((chunk) {
          sent += chunk.length;
          onProgress?.call(sent, total);
          return chunk;
        }),
      );
      return await _decode(await request.close());
    } on SocketException catch (error) {
      throw RemoteClientException('unreachable', error.message);
    } on TimeoutException {
      throw const RemoteClientException('timeout', 'The computer did not answer.');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Object? body,
    bool authorize = true,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.openUrl(method, _uri(path));
      if (authorize && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(timeout);
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(timeout);
      final decoded = text.isEmpty ? null : jsonDecode(text);
      if (response.statusCode >= 400) {
        final map = decoded is Map<String, dynamic>
            ? decoded
            : const <String, dynamic>{};
        throw RemoteClientException(
          map['code'] as String? ?? 'http_${response.statusCode}',
          map['message'] as String? ?? text,
        );
      }
      return decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{};
    } on SocketException catch (error) {
      throw RemoteClientException('unreachable', error.message);
    } on TimeoutException {
      throw const RemoteClientException('timeout', 'The computer did not answer.');
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> _decode(HttpClientResponse response) async {
    final text = await utf8.decoder.bind(response).join();
    final decoded = text.isEmpty ? null : jsonDecode(text);
    if (response.statusCode >= 400) {
      final map = decoded is Map<String, dynamic>
          ? decoded
          : const <String, dynamic>{};
      throw RemoteClientException(
        map['code'] as String? ?? 'http_${response.statusCode}',
        map['message'] as String? ?? text,
      );
    }
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }
}
