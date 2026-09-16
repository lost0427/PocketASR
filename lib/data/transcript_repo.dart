import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

import 'db.dart';

/// A stored transcript row.
class Transcript {
  const Transcript({
    required this.id,
    required this.title,
    required this.text,
    required this.createdAt,
    this.audioPath,
    this.audioSeconds,
    this.lang,
    this.engine,
    this.modelFamily,
    this.modelPath,
    this.backend,
    this.rtf,
    this.tokens,
    this.totalMs,
    this.avgTokensPerSec,
    this.deletedAt,
  });

  final int id;
  final String title;
  final String text;
  final DateTime createdAt;
  final String? audioPath;
  final double? audioSeconds;
  final String? lang;
  final String? engine;
  final String? modelFamily;
  final String? modelPath;
  final String? backend;
  final double? rtf;
  final int? tokens;
  final int? totalMs;
  final double? avgTokensPerSec;

  /// Non-null while the transcript sits in the trash.
  final DateTime? deletedAt;

  bool get isTrashed => deletedAt != null;
}

/// A segment to write together with a new transcript.
class SegmentDraft {
  const SegmentDraft({this.startMs, this.endMs, this.text});

  final int? startMs;
  final int? endMs;
  final String? text;
}

/// Builds a [Transcript] from a `transcript` row. Shared with the search repo.
Transcript transcriptFromRow(Row row) => Transcript(
  id: row['id'] as int,
  title: row['title'] as String,
  text: row['text'] as String,
  createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
  audioPath: row['audio_path'] as String?,
  audioSeconds: (row['audio_seconds'] as num?)?.toDouble(),
  lang: row['lang'] as String?,
  engine: row['engine'] as String?,
  modelFamily: row['model_family'] as String?,
  modelPath: row['model_path'] as String?,
  backend: row['backend'] as String?,
  rtf: (row['rtf'] as num?)?.toDouble(),
  tokens: row['tokens'] as int?,
  totalMs: row['total_ms'] as int?,
  avgTokensPerSec: (row['avg_tokens_per_sec'] as num?)?.toDouble(),
  deletedAt: row['deleted_at'] == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(row['deleted_at'] as int),
);

/// CRUD over the `transcript` and `segment` tables, including the trash flow
/// (soft delete → restore, or purge to erase).
///
/// Notifies listeners after every successful mutation ([insert],
/// [softDelete], [restore], [purge], [purgeAll]) so the History page can
/// refresh and the semantic indexer can react to new, restored, and trashed
/// rows. Reuses Flutter's [ChangeNotifier] rather than inventing a second
/// event bus; a spurious refresh after a no-op delete is harmless and not
/// worth a row-count probe.
class TranscriptRepo extends ChangeNotifier {
  TranscriptRepo(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  /// Inserts a transcript and its [segments] in one transaction. Returns the
  /// new transcript id and, after the commit lands, [notifyListeners] fires —
  /// the single hook History and the semantic indexer hang off repo changes.
  int insert({
    required String title,
    required String text,
    String? audioPath,
    double? audioSeconds,
    String? lang,
    String? engine,
    String? modelFamily,
    String? modelPath,
    String? backend,
    double? rtf,
    int? tokens,
    int? totalMs,
    double? avgTokensPerSec,
    List<SegmentDraft> segments = const [],
    DateTime? createdAt,
  }) {
    final createdAtMs = (createdAt ?? DateTime.now()).millisecondsSinceEpoch;

    _db.execute('BEGIN');
    try {
      _db.execute(
        'INSERT INTO transcript(title, audio_path, audio_seconds, text, lang, '
        'engine, model_family, model_path, backend, rtf, tokens, total_ms, '
        'avg_tokens_per_sec, created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          title,
          audioPath,
          audioSeconds,
          text,
          lang,
          engine,
          modelFamily,
          modelPath,
          backend,
          rtf,
          tokens,
          totalMs,
          avgTokensPerSec,
          createdAtMs,
        ],
      );
      final id = _db.lastInsertRowId;

      for (final segment in segments) {
        _db.execute(
          'INSERT INTO segment(transcript_id, start_ms, end_ms, text) '
          'VALUES(?,?,?,?)',
          [id, segment.startMs, segment.endMs, segment.text],
        );
      }

      _db.execute('COMMIT');
      notifyListeners();
      return id;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Live transcripts, newest first.
  List<Transcript> list() => _select(
    'WHERE deleted_at IS NULL ORDER BY created_at DESC, id DESC',
  );

  /// Trashed transcripts, most recently deleted first.
  List<Transcript> listTrash() => _select(
    'WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC, id DESC',
  );

  /// Moves a transcript to the trash. Notifies on success; the indexer's
  /// next pass simply skips the trashed row (it never embeds dead rows).
  void softDelete(int id, {DateTime? at}) {
    _db.execute('UPDATE transcript SET deleted_at = ? WHERE id = ?', [
      (at ?? DateTime.now()).millisecondsSinceEpoch,
      id,
    ]);
    notifyListeners();
  }

  /// Takes a transcript back out of the trash. Notifies so the indexer can
  /// pick up a restored row that has (or lost) no vector.
  void restore(int id) {
    _db.execute('UPDATE transcript SET deleted_at = NULL WHERE id = ?', [id]);
    notifyListeners();
  }

  /// Permanently deletes one trashed transcript (segments and embedding go with
  /// it through `ON DELETE CASCADE`). No-op for live rows.
  void purge(int id) {
    _db.execute(
      'DELETE FROM transcript WHERE id = ? AND deleted_at IS NOT NULL',
      [id],
    );
    notifyListeners();
  }

  /// Empties the trash.
  void purgeAll() {
    _db.execute('DELETE FROM transcript WHERE deleted_at IS NOT NULL');
    notifyListeners();
  }

  List<Transcript> _select(String where) => [
    for (final row in _db.select('SELECT * FROM transcript $where'))
      transcriptFromRow(row),
  ];
}
