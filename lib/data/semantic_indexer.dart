import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

import '../engine/embedder.dart';
import 'db.dart';

/// Lifecycle of the last indexer run, exposed as state — a failure is a
/// visible [SemanticIndexPhase.failed] with [SemanticIndexer.lastError], never
/// a fake-empty success.
enum SemanticIndexPhase { idle, running, failed }

/// Write-side semantic indexing: embeds stored transcripts into the
/// `embedding` table with the injected [Embedder].
///
/// Minimal by design: no job queue, no vector DB — [indexPending], [rebuild]
/// and [indexTranscript] chain onto one serial future, each awaitable to its
/// own completion, and each [Embedder.embedDocument] call is one synchronous
/// encode. Errors end the current job as [SemanticIndexPhase.failed] +
/// [lastError]; calling again retries where it stopped (rows already stored
/// are not re-embedded, [rebuild] starts the model's rows over).
///
/// The embedder is injected and required — this class has no fallback of its
/// own, so production wiring that hands in a failed/unavailable embedder
/// surfaces as [EmbedderUnavailableException] at construction, upstream.
///
/// React to stored rows by riding [TranscriptRepo]'s ChangeNotifier — the
/// intended wiring is one line at the composition root:
/// `transcriptRepo.addListener(indexer.indexPending)` (each mutation notifies;
/// [indexPending] is idempotent, so spurious runs only pay one SELECT).
/// Awaiting [indexPending] directly after inserts is equally fine.
class SemanticIndexer {
  SemanticIndexer(this._database, {required this._embedder});

  final AppDatabase _database;
  final Embedder _embedder;

  Database get _db => _database.db;

  /// Observable phase for the UI (bind with a ValueListenableBuilder).
  final ValueNotifier<SemanticIndexPhase> phase =
      ValueNotifier(SemanticIndexPhase.idle);

  String? _lastError;

  /// Failure of the last job, cleared when a new job starts. Non-null with
  /// [phase] == [SemanticIndexPhase.failed]; retry by calling the same API.
  String? get lastError => _lastError;

  Future<void> _tail = Future<void>.value();

  /// Embeds every live transcript this model has no vector for.
  Future<void> indexPending() => _enqueue(_runPending);

  /// Re-indexes from scratch for *this model*: the rows tagged with this
  /// model's id are deleted first, then every live transcript is re-embedded.
  ///
  /// Isolation ceiling (schema, not accident): `embedding` has
  /// `transcript_id` as its primary key — one vector per transcript, total.
  /// Indexing a transcript with this model therefore *replaces* whatever
  /// other model's vector it held; rows held by another model on trashed
  /// transcripts are never deleted or replaced (they are not live and not
  /// pending). Queries stay strictly model-filtered, so a replaced/foreign
  /// vector can never answer a query from the wrong model.
  /// ponytail: two models coexisting needs a `PRIMARY KEY (transcript_id,
  /// model)` migration in db.dart — out of this lane's ownership; add it when
  /// model switching stops being rare enough to re-embed.
  Future<void> rebuild() => _enqueue(() async {
    _db.execute(
      'DELETE FROM embedding WHERE model = ?',
      [_embedder.id],
    );
    await _runPending();
  });

  /// Embeds one transcript now if live and still unvectorized by this model;
  /// no-op otherwise (the next [indexPending] picks up anything skipped).
  Future<void> indexTranscript(int id) => _enqueue(() async {
    final rows = _db.select(
      'SELECT text FROM transcript WHERE id = ? AND deleted_at IS NULL',
      [id],
    );
    if (rows.isEmpty) return; // trashed or purged: never resurrect
    final existing = _db.select(
      'SELECT 1 FROM embedding WHERE transcript_id = ? AND model = ?',
      [id, _embedder.id],
    );
    if (existing.isNotEmpty) return;
    _embedAndStore(id, rows.single['text'] as String);
  });

  /// Releases the notifier; does not dispose the injected embedder, whose
  /// lifetime belongs to whoever built it (typically AppState/engineRegistry).
  void dispose() => phase.dispose();

  Future<void> _enqueue(Future<void> Function() job) {
    // Every job is serial and self-contained: failures become state instead of
    // rejecting the chain, so one bad vector cannot wedge all later indexing.
    _tail = _tail.then((_) async {
      _lastError = null;
      phase.value = SemanticIndexPhase.running;
      try {
        await job();
        phase.value = SemanticIndexPhase.idle;
      } catch (error) {
        _lastError = error.toString();
        phase.value = SemanticIndexPhase.failed;
      }
    });
    return _tail;
  }

  Future<void> _runPending() async {
    final pending = _db.select(
      'SELECT t.id, t.text FROM transcript t '
      'LEFT JOIN embedding e ON e.transcript_id = t.id AND e.model = ? '
      'WHERE e.transcript_id IS NULL AND t.deleted_at IS NULL '
      'ORDER BY t.id',
      [_embedder.id],
    );
    for (final row in pending) {
      // Yield between embeds so taps get their frame. A native encode is
      // synchronous FFI and still blocks for its own call; moving the job to
      // an isolate needs DB+embedder access across the boundary.
      // ponytail: revisit only if single encodes measurably drop frames.
      await Future<void>.delayed(Duration.zero);
      _embedAndStore(row['id'] as int, row['text'] as String);
    }
  }

  void _embedAndStore(int id, String text) {
    final vector = _embedder.embedDocument(text);
    _check(vector);
    _db.execute('BEGIN');
    try {
      // Re-check liveness inside the transaction: the transcript may have been
      // trashed or purged while (slow) embedding was running. A purge would be
      // caught by the foreign key, a soft delete would not — this guard is
      // what keeps a trashed row from gaining a fresh vector.
      final alive = _db.select(
        'SELECT 1 FROM transcript WHERE id = ? AND deleted_at IS NULL',
        [id],
      );
      if (alive.isEmpty) {
        _db.execute('ROLLBACK');
        return;
      }
      final blob = vector.buffer.asUint8List(
        vector.offsetInBytes,
        vector.lengthInBytes,
      );
      _db.execute(
        'INSERT INTO embedding(transcript_id, dim, vec, model, created_at) '
        'VALUES(?,?,?,?,?) '
        'ON CONFLICT(transcript_id) DO UPDATE SET dim = excluded.dim, '
        'vec = excluded.vec, model = excluded.model, '
        'created_at = excluded.created_at',
        [
          id,
          _embedder.dim,
          blob,
          _embedder.id,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// A vector is only storable if it is the model's dimension and entirely
  /// finite (a NaN/Inf in the blob would poison cosine forever). The blob
  /// length is derived, not trusted: `dim * 4` bytes exactly.
  void _check(Float32List vector) {
    if (vector.length != _embedder.dim) {
      throw StateError(
        'Embedder "${_embedder.id}" returned ${vector.length} dimensions, '
        'expected ${_embedder.dim}.',
      );
    }
    for (final value in vector) {
      if (!value.isFinite) {
        throw StateError(
          'Embedder "${_embedder.id}" returned a non-finite value; '
          'refusing to store the vector.',
        );
      }
    }
  }
}
