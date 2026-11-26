import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

import '../data/db.dart';

enum RemoteJobStatus { pending, running, done, failed, cancelled }

class RemoteJob {
  RemoteJob({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.title,
    required this.createdAt,
    this.audioPath,
    this.bytes = 0,
    this.audioSeconds,
    this.status = RemoteJobStatus.pending,
    this.stage,
    this.ratio,
    this.error,
    this.text,
    this.engine,
    this.modelFamily,
    this.modelQuant,
    this.modelPath,
    this.backend,
    this.rtf,
    this.totalMs,
    this.decoder,
    this.startedAt,
    this.finishedAt,
  });

  final String id;
  final String deviceId;
  final String deviceName;
  final String title;
  final DateTime createdAt;

  String? audioPath;
  int bytes;
  double? audioSeconds;
  RemoteJobStatus status;
  String? stage;
  double? ratio;
  String? error;
  String? text;
  String? engine;
  String? modelFamily;
  String? modelQuant;
  String? modelPath;
  String? backend;
  double? rtf;
  int? totalMs;
  String? decoder;
  DateTime? startedAt;
  DateTime? finishedAt;

  bool get finished =>
      status == RemoteJobStatus.done ||
      status == RemoteJobStatus.failed ||
      status == RemoteJobStatus.cancelled;

  Map<String, dynamic> toJson({bool withText = false}) => {
    'id': id,
    'title': title,
    'bytes': bytes,
    'status': status.name,
    'stage': stage,
    'ratio': ratio,
    'error': error,
    'audioSeconds': audioSeconds,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'startedAt': startedAt?.millisecondsSinceEpoch,
    'finishedAt': finishedAt?.millisecondsSinceEpoch,
    if (withText) ...{
      'text': text,
      'engine': engine,
      'modelFamily': modelFamily,
      'modelQuant': modelQuant,
      'modelPath': modelPath,
      'backend': backend,
      'rtf': rtf,
      'totalMs': totalMs,
      'decoder': decoder,
    },
  };

  factory RemoteJob.fromRow(Row row) => RemoteJob(
    id: row['id'] as String,
    deviceId: row['device_id'] as String,
    deviceName: row['device_name'] as String,
    title: row['title'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    audioPath: row['audio_path'] as String?,
    bytes: row['bytes'] as int? ?? 0,
    audioSeconds: (row['audio_seconds'] as num?)?.toDouble(),
    status: RemoteJobStatus.values.firstWhere(
      (value) => value.name == row['status'],
      orElse: () => RemoteJobStatus.failed,
    ),
    stage: row['stage'] as String?,
    ratio: (row['ratio'] as num?)?.toDouble(),
    error: row['error'] as String?,
    text: row['text'] as String?,
    engine: row['engine'] as String?,
    modelFamily: row['model_family'] as String?,
    modelQuant: row['model_quant'] as String?,
    modelPath: row['model_path'] as String?,
    backend: row['backend'] as String?,
    rtf: (row['rtf'] as num?)?.toDouble(),
    totalMs: row['total_ms'] as int?,
    decoder: row['decoder'] as String?,
    startedAt: row['started_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['started_at'] as int),
    finishedAt: row['finished_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['finished_at'] as int),
  );
}

class RemoteJobRepo extends ChangeNotifier {
  RemoteJobRepo(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  RemoteJob? byId(String id) {
    final rows = _db.select('SELECT * FROM remote_job WHERE id = ?', [id]);
    return rows.isEmpty ? null : RemoteJob.fromRow(rows.first);
  }

  List<RemoteJob> forDevice(String deviceId) => [
    for (final row in _db.select(
      'SELECT * FROM remote_job WHERE device_id = ? '
      'ORDER BY created_at ASC',
      [deviceId],
    ))
      RemoteJob.fromRow(row),
  ];

  List<RemoteJob> listAll() => [
    for (final row in _db.select(
      'SELECT * FROM remote_job ORDER BY created_at ASC',
    ))
      RemoteJob.fromRow(row),
  ];

  void insert(RemoteJob job) {
    _db.execute(
      'INSERT INTO remote_job(id, device_id, device_name, title, audio_path, '
      'bytes, status, created_at) VALUES(?,?,?,?,?,?,?,?)',
      [
        job.id,
        job.deviceId,
        job.deviceName,
        job.title,
        job.audioPath,
        job.bytes,
        job.status.name,
        job.createdAt.millisecondsSinceEpoch,
      ],
    );
    notifyListeners();
  }

  void save(RemoteJob job) {
    _db.execute(
      'UPDATE remote_job SET status=?, stage=?, ratio=?, error=?, text=?, '
      'engine=?, model_family=?, model_quant=?, model_path=?, backend=?, '
      'rtf=?, total_ms=?, decoder=?, audio_seconds=?, bytes=?, audio_path=?, '
      'started_at=?, finished_at=? WHERE id=?',
      [
        job.status.name,
        job.stage,
        job.ratio,
        job.error,
        job.text,
        job.engine,
        job.modelFamily,
        job.modelQuant,
        job.modelPath,
        job.backend,
        job.rtf,
        job.totalMs,
        job.decoder,
        job.audioSeconds,
        job.bytes,
        job.audioPath,
        job.startedAt?.millisecondsSinceEpoch,
        job.finishedAt?.millisecondsSinceEpoch,
        job.id,
      ],
    );
    notifyListeners();
  }

  void delete(String id) {
    _db.execute('DELETE FROM remote_job WHERE id = ?', [id]);
    notifyListeners();
  }

  int pendingCount() =>
      _db.select(
            'SELECT COUNT(*) AS n FROM remote_job WHERE status = ?',
            [RemoteJobStatus.pending.name],
          ).first['n']
          as int;

  void failInterrupted() {
    _db.execute(
      'UPDATE remote_job SET status = ?, error = ? WHERE status = ?',
      [
        RemoteJobStatus.failed.name,
        'The computer app stopped while this job was running.',
        RemoteJobStatus.running.name,
      ],
    );
    notifyListeners();
  }
}
