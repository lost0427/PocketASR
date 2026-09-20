import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

import '../core/text/text_chunker.dart';
import '../core/text/token_counter.dart';
import '../engine/embedder.dart';
import 'db.dart';

/// Lifecycle of the last indexer run, exposed as state — a failure is a
/// visible [SemanticIndexPhase.failed] with [SemanticIndexer.lastError], never
/// a fake-empty success.
enum SemanticIndexPhase { idle, running, failed }

/// Live counters for the indexing job in flight, next to [SemanticIndexer.phase].
///
/// Progress is measured in characters, not chunks: the encoder's cost tracks
/// text length (measured ~7.5 ms per character for the pinned 0.6B model up to
/// ~1k characters, worse above it), so the bar moves in proportion to real work
/// and the ETA means something. Every figure is measured — before the first
/// chunk completes the rates and the ETA are null and the UI shows nothing
/// rather than a placeholder.
class SemanticIndexProgress {
  const SemanticIndexProgress({
    required this.chunksDone,
    required this.chunksTotal,
    required this.graphemesDone,
    required this.graphemesTotal,
    required this.elapsed,
    required this.lastChunkGraphemesPerSecond,
    required this.averageGraphemesPerSecond,
  });

  /// A job with nothing scheduled (and the state before one starts).
  static const SemanticIndexProgress idle = SemanticIndexProgress(
    chunksDone: 0,
    chunksTotal: 0,
    graphemesDone: 0,
    graphemesTotal: 0,
    elapsed: Duration.zero,
    lastChunkGraphemesPerSecond: null,
    averageGraphemesPerSecond: null,
  );

  final int chunksDone;

  /// Chunks this job scheduled, counted before any encode so the figure does not
  /// grow while the user watches it.
  final int chunksTotal;

  final int graphemesDone;
  final int graphemesTotal;

  /// Wall clock since this job started, including the encode in flight.
  final Duration elapsed;

  /// Speed of the chunk that finished last — the "live" number, and the only
  /// one that moves while a long encode is still running.
  final double? lastChunkGraphemesPerSecond;

  /// Average over every chunk this job has finished: stable enough to derive
  /// the ETA from, unlike the instantaneous reading.
  final double? averageGraphemesPerSecond;

  /// Fraction of the job's characters done, or null when nothing is scheduled.
  double? get fraction =>
      graphemesTotal == 0 ? null : graphemesDone / graphemesTotal;

  /// Time left at the average rate so far, or null before the first chunk
  /// (nothing has been measured yet, so any figure would be invented).
  Duration? get remaining {
    final rate = averageGraphemesPerSecond;
    if (rate == null || rate <= 0) return null;
    final seconds = (graphemesTotal - graphemesDone) / rate;
    return seconds <= 0
        ? Duration.zero
        : Duration(milliseconds: (seconds * 1000).round());
  }
}

/// Write-side semantic indexing: embeds stored transcripts into the
/// `embedding` table with the injected [Embedder].
///
/// Minimal by design: no job queue, no vector DB — [indexPending], [rebuild]
/// and [indexTranscript] chain onto one serial future, each awaitable to its
/// own completion. The production embedder encodes on its worker isolate, so
/// each [Embedder.embedDocument] is awaited — the UI thread never blocks on
/// native FFI, and the DB reads/writes stay on the root isolate where the
/// database lives. Errors end the current job as [SemanticIndexPhase.failed] +
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
  final ValueNotifier<SemanticIndexPhase> phase = ValueNotifier(
    SemanticIndexPhase.idle,
  );

  /// Observable progress for the job in flight. A second notifier so [phase]
  /// keeps its exact contract for existing listeners.
  final ValueNotifier<SemanticIndexProgress> progress = ValueNotifier(
    SemanticIndexProgress.idle,
  );

  /// Job-scoped counters, reset by [_enqueue] at the start of every run.
  Stopwatch _clock = Stopwatch();
  int _chunksDone = 0;
  int _chunksTotal = 0;
  int _graphemesDone = 0;
  int _graphemesTotal = 0;
  double? _lastChunkRate;
  double? _averageRate;

  String? _lastError;

  /// Failure of the last job, cleared when a new job starts. Non-null with
  /// [phase] == [SemanticIndexPhase.failed]; retry by calling the same API.
  String? get lastError => _lastError;

  Future<void> _tail = Future<void>.value();

  /// Embeds every stored transcript this model has no vector for, including
  /// recycle-bin rows because that view also supports semantic search.
  Future<void> indexPending() => _enqueue(_runPending);

  /// Re-indexes from scratch for *this model*: the rows tagged with this
  /// model's id are deleted first, then every stored transcript is re-embedded.
  ///
  /// Isolation ceiling (a choice, not the schema): one model owns the index at a
  /// time — [indexTranscript] deletes a transcript's rows outright, whichever
  /// model wrote them, so switching replaces rather than coexists. Queries stay
  /// strictly model-filtered, so a foreign vector can never answer a query from
  /// the wrong model. ponytail: coexisting models need `model` in the primary
  /// key and a `WHERE model = ?` on that delete; add it when model switching
  /// stops being rare enough to re-embed.
  Future<void> rebuild() => _enqueue(() async {
    _db.execute('DELETE FROM embedding WHERE model = ?', [_embedder.id]);
    await _runPending();
  });

  /// Embeds one transcript now if it still exists and is unvectorized by this
  /// model; no-op otherwise (the next [indexPending] picks up anything
  /// skipped).
  Future<void> indexTranscript(int id) => _enqueue(() async {
    final rows = _db.select('SELECT text FROM transcript WHERE id = ?', [id]);
    if (rows.isEmpty) return; // permanently deleted: never recreate anything
    final existing = _db.select(
      'SELECT 1 FROM embedding WHERE transcript_id = ? AND model = ?',
      [id, _embedder.id],
    );
    if (existing.isNotEmpty) return;
    final text = rows.single['text'] as String;
    _sizeJob([text]);
    await _embedAndStore(id, text);
  });

  /// Releases the notifier; does not dispose the injected embedder, whose
  /// lifetime belongs to whoever built it (typically AppState/engineRegistry).
  /// After dispose, in-flight jobs stop before their next DB write, so a
  /// replaced model can never be indexed into by a stale job.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    phase.dispose();
    progress.dispose();
  }

  bool _disposed = false;

  Future<void> _enqueue(Future<void> Function() job) {
    // Every job is serial and self-contained: failures become state instead of
    // rejecting the chain, so one bad vector cannot wedge all later indexing.
    _tail = _tail.then((_) async {
      if (_disposed) {
        return; // superseded model: the queue drains, writes nothing
      }
      _lastError = null;
      _clock = Stopwatch()..start();
      _chunksDone = 0;
      _chunksTotal = 0;
      _graphemesDone = 0;
      _graphemesTotal = 0;
      _lastChunkRate = null;
      _averageRate = null;
      progress.value = SemanticIndexProgress.idle;
      phase.value = SemanticIndexPhase.running;
      try {
        await job();
        if (!_disposed) phase.value = SemanticIndexPhase.idle;
      } catch (error) {
        _lastError = error.toString();
        if (!_disposed) phase.value = SemanticIndexPhase.failed;
      }
    });
    return _tail;
  }

  Future<void> _runPending() async {
    // NOT EXISTS rather than LEFT JOIN: a transcript holds one row per chunk, so
    // a join would list a transcript once per row of a *foreign* model's index
    // and re-embed it that many times per pass.
    final pending = _db.select(
      'SELECT t.id, t.text FROM transcript t '
      'WHERE NOT EXISTS (SELECT 1 FROM embedding e '
      'WHERE e.transcript_id = t.id AND e.model = ?) '
      'ORDER BY t.id',
      [_embedder.id],
    );
    _sizeJob([for (final row in pending) row['text'] as String]);
    for (final row in pending) {
      // The await on the worker embed already yields the UI thread its frame;
      // no extra delay is needed (and the native encode no longer blocks at
      // all — it runs on the embedding worker isolate).
      await _embedAndStore(row['id'] as int, row['text'] as String);
    }
  }

  Future<void> _embedAndStore(int id, String text) async {
    // One row per chunk, so a long transcript is never encoded as a single
    // sequence: that costs ~3x more on the measured model (attention is
    // quadratic) and the native tokenizer silently drops everything past the
    // model's context length, which would make a transcript's tail unsearchable.
    final chunks = chunkForEmbedding(text);
    if (chunks.isEmpty) return; // nothing searchable: stays unvectorized

    final vectors = <Float32List>[];
    for (final chunk in chunks) {
      final clock = Stopwatch()..start();
      final vector = await _embedder.embedDocument(chunk);
      clock.stop();
      // A model switch or AppState teardown may have landed while the worker was
      // encoding: a stale job must not write into the (now other model's) index.
      if (_disposed) return;
      _check(vector);
      vectors.add(vector);
      _recordChunk(chunk, clock.elapsed);
    }

    _db.execute('BEGIN');
    try {
      // Re-check existence inside the transaction: the transcript may have
      // been permanently deleted while the worker was encoding. Moving it to
      // the recycle bin is not a reason to drop the vector because semantic
      // search is available there too.
      final stored = _db.select('SELECT 1 FROM transcript WHERE id = ?', [id]);
      if (stored.isEmpty) {
        _db.execute('ROLLBACK');
        return;
      }
      // Replace this transcript's rows wholesale: editing the text shorter
      // would otherwise leave orphaned high ordinals searchable.
      _db.execute('DELETE FROM embedding WHERE transcript_id = ?', [id]);
      final created = DateTime.now().millisecondsSinceEpoch;
      for (var chunk = 0; chunk < vectors.length; chunk++) {
        final vector = vectors[chunk];
        final blob = vector.buffer.asUint8List(
          vector.offsetInBytes,
          vector.lengthInBytes,
        );
        _db.execute(
          'INSERT INTO embedding(transcript_id, chunk, dim, vec, model, '
          'created_at) VALUES(?,?,?,?,?,?)',
          [id, chunk, _embedder.dim, blob, _embedder.id, created],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Sets this job's denominators by chunking every text up front. Chunking is
  /// pure Dart and O(n), so doing it once here (and again per transcript in
  /// [_embedAndStore]) costs nothing next to a single native encode — and it
  /// buys a bar and an ETA that do not move on their own.
  void _sizeJob(Iterable<String> texts) {
    var chunks = 0;
    var graphemes = 0;
    for (final text in texts) {
      for (final chunk in chunkForEmbedding(text)) {
        chunks++;
        graphemes += graphemeCount(chunk);
      }
    }
    _chunksTotal = chunks;
    _graphemesTotal = graphemes;
    _publish();
  }

  /// Folds one finished chunk into the live counters: the instantaneous rate
  /// from this chunk's own wall clock, the average from the job's, and the ETA
  /// that the UI derives from the average.
  void _recordChunk(String chunk, Duration took) {
    final graphemes = graphemeCount(chunk);
    _chunksDone++;
    _graphemesDone += graphemes;
    _lastChunkRate = graphemesPerSecond(chunk, took);
    final millis = _clock.elapsedMilliseconds;
    _averageRate = millis <= 0 ? null : _graphemesDone * 1000 / millis;
    _publish();
  }

  void _publish() {
    progress.value = SemanticIndexProgress(
      chunksDone: _chunksDone,
      chunksTotal: _chunksTotal,
      graphemesDone: _graphemesDone,
      graphemesTotal: _graphemesTotal,
      elapsed: _clock.elapsed,
      lastChunkGraphemesPerSecond: _lastChunkRate,
      averageGraphemesPerSecond: _averageRate,
    );
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
