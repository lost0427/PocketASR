import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'remote_auth.dart';
import 'remote_job_repo.dart';
import 'remote_protocol.dart';

abstract interface class RemoteHostBridge {
  String get hostId;
  String get hostName;
  String get remoteInboxDirectory;
  RemoteAuth get remoteAuth;
  RemoteJobRepo get remoteJobs;
  bool get engineBusy;
  void cancelRemoteJob(String id);
  void remoteJobQueued();
}

class RemoteHostServer extends ChangeNotifier {
  RemoteHostServer(this.bridge);

  final RemoteHostBridge bridge;

  HttpServer? _server;
  bool _starting = false;
  String? _pairCode;
  DateTime? _pairExpiry;
  final Map<String, List<DateTime>> _pairAttempts = {};

  bool get running => _server != null;

  int get port => _server?.port ?? remoteDefaultPort;

  String get pairCode =>
      _pairExpiry != null && DateTime.now().isBefore(_pairExpiry!)
      ? _pairCode!
      : '';

  Future<void> start({int port = remoteDefaultPort}) async {
    if (_server != null || _starting) return;
    _starting = true;
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _server = server;
      server.listen(_handle);
      notifyListeners();
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _pairCode = null;
    _pairExpiry = null;
    notifyListeners();
    await server?.close(force: true);
  }

  void startPairing() {
    _pairCode = newPairCode();
    _pairExpiry = DateTime.now().add(const Duration(minutes: 2));
    notifyListeners();
  }

  void clearPairing() {
    _pairCode = null;
    _pairExpiry = null;
    notifyListeners();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final remote = request.connectionInfo?.remoteAddress;
      if (remote != null && !isPrivateAddress(remote)) {
        await _json(request.response, 403, {'code': 'forbidden'});
        return;
      }
      final path = request.uri.pathSegments;
      if (path.length < 2 || path[0] != 'v1') {
        await _json(request.response, 404, {'code': 'not_found'});
        return;
      }
      switch (path[1]) {
        case 'hello':
          await _hello(request);
        case 'pair':
          await _pair(request);
        case 'jobs':
          await _jobs(request, path);
        default:
          await _json(request.response, 404, {'code': 'not_found'});
      }
    } catch (error) {
      try {
        await _json(request.response, 500, {
          'code': 'internal',
          'message': '$error',
        });
      } catch (_) {}
    }
  }

  Future<void> _hello(HttpRequest request) async {
    final device = _authenticate(request);
    final body = <String, Object?>{
      'app': 'pocket-asr',
      'protocol': remoteProtocolVersion,
      'host': bridge.hostName,
      'hostId': bridge.hostId,
      'requiresToken': true,
    };
    if (device != null) {
      body['paired'] = true;
      body['busy'] = bridge.engineBusy;
      body['platform'] = Platform.operatingSystem;
    }
    await _json(request.response, 200, body);
  }

  Future<void> _pair(HttpRequest request) async {
    if (request.method != 'POST') {
      await _json(request.response, 405, {'code': 'method'});
      return;
    }
    final ip = request.connectionInfo?.remoteAddress.address ?? '';
    if (!_pairAllowed(ip)) {
      await _json(request.response, 429, {'code': 'rate_limited'});
      return;
    }
    final code = pairCode;
    if (code.isEmpty) {
      await _json(request.response, 410, {'code': 'pairing_closed'});
      return;
    }
    final body = await _readJson(request);
    final sent = '${body?['code'] ?? ''}';
    if (!constantTimeEquals(code, sent)) {
      await _json(request.response, 401, {'code': 'bad_code'});
      return;
    }
    _pairCode = null;
    _pairExpiry = null;
    notifyListeners();
    final token = newRemoteToken();
    final name = '${body?['deviceName'] ?? 'Android device'}';
    final device = bridge.remoteAuth.addDevice(name, token);
    await _json(request.response, 200, {
      'token': token,
      'hostId': bridge.hostId,
      'name': bridge.hostName,
      'deviceId': device.id,
    });
  }

  Future<void> _jobs(HttpRequest request, List<String> path) async {
    final device = _authenticate(request);
    if (device == null) {
      await _json(request.response, 401, {'code': 'unauthorized'});
      return;
    }
    if (path.length == 2) {
      if (request.method == 'GET') {
        final jobs = bridge.remoteJobs.forDevice(device.id);
        await _json(request.response, 200, {
          'jobs': [for (final job in jobs) job.toJson()],
        });
        return;
      }
      if (request.method == 'POST') {
        await _upload(request, device);
        return;
      }
      await _json(request.response, 405, {'code': 'method'});
      return;
    }
    final job = bridge.remoteJobs.byId(path[2]);
    if (job == null || job.deviceId != device.id) {
      await _json(request.response, 404, {'code': 'not_found'});
      return;
    }
    final action = path.length > 3 ? path[3] : '';
    switch (action) {
      case '':
        if (request.method != 'GET') {
          await _json(request.response, 405, {'code': 'method'});
          return;
        }
        await _json(request.response, 200, job.toJson(withText: true));
      case 'cancel':
        if (job.status == RemoteJobStatus.pending) {
          job.status = RemoteJobStatus.cancelled;
          job.finishedAt = DateTime.now();
          bridge.remoteJobs.save(job);
        } else if (job.status == RemoteJobStatus.running) {
          bridge.cancelRemoteJob(job.id);
        }
        await _json(request.response, 202, {'status': job.status.name});
      case 'ack':
        await _removeJob(job);
        await _json(request.response, 200, {'deleted': true});
      default:
        await _json(request.response, 404, {'code': 'not_found'});
    }
  }

  Future<void> _upload(HttpRequest request, RemoteDevice device) async {
    final length = request.contentLength;
    if (length < 0) {
      await _json(request.response, 411, {'code': 'length_required'});
      return;
    }
    if (length > remoteMaxJobBytes) {
      await _json(request.response, 413, {'code': 'payload_too_large'});
      return;
    }
    if (bridge.remoteJobs.pendingCount() >= remoteMaxPendingJobs) {
      await _json(request.response, 409, {'code': 'inbox_full'});
      return;
    }
    final rawName = request.headers.value(remoteFilenameHeader) ?? '';
    final title = _decodedName(rawName);
    final id = 'j_${randomHex(8)}';
    final file = File('${bridge.remoteInboxDirectory}/$id${_extension(title)}');
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    var bytes = 0;
    try {
      await for (final chunk in request) {
        bytes += chunk.length;
        if (bytes > remoteMaxJobBytes) {
          throw const FileSystemException('upload too large');
        }
        sink.add(chunk);
      }
      await sink.close();
    } catch (error) {
      await sink.close().catchError((_) {});
      try {
        await file.delete();
      } catch (_) {}
      await _json(request.response, 500, {
        'code': 'upload_failed',
        'message': '$error',
      });
      return;
    }
    final job = RemoteJob(
      id: id,
      deviceId: device.id,
      deviceName: device.name,
      title: title.isEmpty ? id : title,
      audioPath: file.path,
      bytes: bytes,
      createdAt: DateTime.now(),
    );
    bridge.remoteJobs.insert(job);
    bridge.remoteJobQueued();
    await _json(request.response, 201, job.toJson());
  }

  Future<void> _removeJob(RemoteJob job) async {
    bridge.remoteJobs.delete(job.id);
    final path = job.audioPath;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  RemoteDevice? _authenticate(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Bearer ')) return null;
    final device = bridge.remoteAuth.deviceForToken(
      header.substring('Bearer '.length).trim(),
    );
    if (device != null) bridge.remoteAuth.touch(device.id);
    return device;
  }

  bool _pairAllowed(String ip) {
    final now = DateTime.now();
    final list = _pairAttempts.putIfAbsent(ip, () => []);
    list.removeWhere(
      (at) => now.difference(at) > const Duration(minutes: 1),
    );
    if (list.length >= 5) return false;
    list.add(now);
    return true;
  }

  static String _decodedName(String raw) {
    try {
      return Uri.decodeComponent(raw).trim();
    } catch (_) {
      return raw.trim();
    }
  }

  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || name.length - dot > 8) return '.bin';
    final ext = name.substring(dot).toLowerCase();
    return RegExp(r'^\.[a-z0-9]+$').hasMatch(ext) ? ext : '.bin';
  }

  static Future<Map<String, dynamic>?> _readJson(HttpRequest request) async {
    try {
      final text = await utf8.decoder.bind(request).join();
      if (text.trim().isEmpty) return null;
      final value = jsonDecode(text);
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _json(
    HttpResponse response,
    int status,
    Object body,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}

bool isPrivateAddress(InternetAddress address) {
  if (address.isLoopback) return true;
  var raw = address.rawAddress;
  if (raw.length == 16 &&
      raw[0] == 0 &&
      raw[1] == 0 &&
      raw[2] == 0 &&
      raw[3] == 0 &&
      raw[4] == 0 &&
      raw[5] == 0 &&
      raw[6] == 0 &&
      raw[7] == 0 &&
      raw[8] == 0 &&
      raw[9] == 0 &&
      raw[10] == 0xff &&
      raw[11] == 0xff) {
    raw = raw.sublist(12);
  }
  if (raw.length == 4) {
    final a = raw[0];
    final b = raw[1];
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 169 && b == 254) ||
        (a == 127);
  }
  if (raw.length == 16) {
    if (raw.every((byte) => byte == 0)) return true;
    if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) return true;
    if ((raw[0] & 0xfe) == 0xfc) return true;
  }
  return false;
}
