import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app/app_state.dart';
import 'remote_client.dart';
import 'remote_protocol.dart';

const MethodChannel _pickerChannel = MethodChannel('pocket_asr/audio_picker');

enum OutboxStatus { uploading, waiting, running, done, failed, cancelled }

class OutboxItem {
  OutboxItem({
    required this.hostId,
    required this.title,
    required this.status,
    this.remoteId = '',
    this.sourcePath,
    this.totalBytes = 0,
  });

  final String hostId;
  String title;
  String remoteId;
  String? sourcePath;
  OutboxStatus status;
  String? stage;
  double? ratio;
  int uploadedBytes = 0;
  int totalBytes;
  String? error;
  String? text;
  bool imported = false;
}

class RemoteOutbox extends ChangeNotifier {
  RemoteOutbox(this.state);

  final AppState state;
  final List<OutboxItem> _items = [];
  Timer? _timer;
  bool _busy = false;
  DateTime _lastIdleCheck = DateTime.fromMillisecondsSinceEpoch(0);

  List<OutboxItem> get items => List.unmodifiable(_items);

  bool get _hasActive => _items.any(
    (item) =>
        item.status == OutboxStatus.uploading ||
        item.status == OutboxStatus.waiting ||
        item.status == OutboxStatus.running,
  );

  void start() {
    _timer ??= Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(tick()),
    );
    unawaited(tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> tick() async {
    if (_busy) return;
    final hosts = state.remoteHosts;
    if (hosts.isEmpty) return;
    if (!_hasActive &&
        DateTime.now().difference(_lastIdleCheck) <
            const Duration(seconds: 15)) {
      return;
    }
    _busy = true;
    if (!_hasActive) _lastIdleCheck = DateTime.now();
    try {
      for (final host in hosts) {
        if (host.token.isEmpty) continue;
        final client = RemoteClient(
          host: host.host,
          port: host.port,
          token: host.token,
        );
        try {
          final jobs = await client.jobs();
          state.noteHostReachable(host.id, true);
          await _merge(host, client, jobs);
        } on Object {
          state.noteHostReachable(host.id, false);
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<OutboxItem> submit(RemoteHost host, String path, String name) async {
    final item = OutboxItem(
      hostId: host.id,
      title: name,
      status: OutboxStatus.uploading,
      sourcePath: path,
    );
    _items.insert(0, item);
    notifyListeners();
    String? staged;
    try {
      staged = await _stage(path);
      final client = RemoteClient(
        host: host.host,
        port: host.port,
        token: host.token,
      );
      final result = await client.upload(
        staged,
        name,
        onProgress: (sent, total) {
          item.uploadedBytes = sent;
          item.totalBytes = total;
          notifyListeners();
        },
      );
      item.remoteId = result['id'] as String? ?? '';
      item.status = OutboxStatus.waiting;
      item.sourcePath = null;
      state.noteHostReachable(host.id, true);
    } on Object catch (error) {
      item.status = OutboxStatus.failed;
      item.error = '$error';
    } finally {
      if (staged != null && staged != path) {
        try {
          await File(staged).delete();
        } catch (_) {}
      }
      notifyListeners();
    }
    return item;
  }

  Future<void> retry(OutboxItem item) async {
    final host = _host(item.hostId);
    final path = item.sourcePath;
    if (host == null || path == null) return;
    _items.remove(item);
    await submit(host, path, item.title);
  }

  Future<void> withdraw(OutboxItem item) async {
    if (item.remoteId.isEmpty) return;
    final host = _host(item.hostId);
    if (host == null) return;
    try {
      await RemoteClient(
        host: host.host,
        port: host.port,
        token: host.token,
      ).cancel(item.remoteId);
    } on Object catch (error) {
      item.error = '$error';
    }
    item.status = OutboxStatus.cancelled;
    notifyListeners();
  }

  RemoteHost? _host(String id) {
    for (final host in state.remoteHosts) {
      if (host.id == id) return host;
    }
    return null;
  }

  void dismiss(OutboxItem item) {
    _items.remove(item);
    notifyListeners();
  }

  Future<void> _merge(
    RemoteHost host,
    RemoteClient client,
    List<Map<String, dynamic>> jobs,
  ) async {
    for (final json in jobs) {
      final id = json['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final item =
          _find(host.id, id) ??
          _adopt(host, id, json);
      item.title = json['title'] as String? ?? item.title;
      item.stage = json['stage'] as String?;
      item.ratio = (json['ratio'] as num?)?.toDouble();
      item.error = json['error'] as String?;
      switch (json['status']) {
        case 'pending':
          item.status = OutboxStatus.waiting;
        case 'running':
          item.status = OutboxStatus.running;
        case 'cancelled':
          item.status = OutboxStatus.cancelled;
        case 'failed':
          item.status = OutboxStatus.failed;
        case 'done':
          item.status = OutboxStatus.done;
          await _import(host, client, id, item);
      }
      notifyListeners();
    }
  }

  OutboxItem? _find(String hostId, String remoteId) {
    for (final item in _items) {
      if (item.hostId == hostId && item.remoteId == remoteId) return item;
    }
    return null;
  }

  OutboxItem _adopt(
    RemoteHost host,
    String id,
    Map<String, dynamic> json,
  ) {
    final item = OutboxItem(
      hostId: host.id,
      title: json['title'] as String? ?? id,
      status: OutboxStatus.waiting,
      remoteId: id,
      totalBytes: json['bytes'] as int? ?? 0,
    );
    _items.add(item);
    return item;
  }

  Future<void> _import(
    RemoteHost host,
    RemoteClient client,
    String id,
    OutboxItem item,
  ) async {
    if (item.imported) return;
    final detail = await client.job(id);
    final text = (detail['text'] as String? ?? '').trim();
    item.imported = true;
    if (text.isEmpty) {
      item.status = OutboxStatus.failed;
      item.error = 'The computer returned no text.';
      notifyListeners();
      return;
    }
    final inserted = state.transcriptRepo.insertRemoteOnce(
      remoteId: '${host.id}:$id',
      hostId: host.id,
      title: detail['title'] as String? ?? item.title,
      text: text,
      audioSeconds: (detail['audioSeconds'] as num?)?.toDouble(),
      engine: 'remote:${host.name}',
      modelFamily: detail['modelFamily'] as String?,
      modelPath: detail['modelPath'] as String?,
      backend: detail['backend'] as String?,
      rtf: (detail['rtf'] as num?)?.toDouble(),
      totalMs: detail['totalMs'] as int?,
    );
    item.text = text;
    if (inserted != null) notifyListeners();
    try {
      await client.ack(id);
    } on Object catch (error) {
      item.error = '$error';
    }
  }

  static Future<String> _stage(String source) async {
    if (!source.startsWith('content://')) return source;
    final path = await _pickerChannel.invokeMethod<String>(
      'copyToCache',
      {'uri': source},
    );
    if (path == null || path.isEmpty) {
      throw const RemoteClientException(
        'stage_failed',
        'Could not copy the picked audio.',
      );
    }
    return path;
  }
}
