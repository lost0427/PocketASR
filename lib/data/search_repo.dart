import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../engine/embedder.dart';
import '../engine/embedding_index.dart';
import 'db.dart';
import 'transcript_repo.dart';

/// Read-side search over stored transcripts.
class SearchRepo {
  SearchRepo(this._database, {this.embedder});

  final AppDatabase _database;

  /// Optional local embedder. When null, semantic search is unavailable and
  /// [searchSemantic] returns nothing rather than inventing results.
  final Embedder? embedder;

  Database get _db => _database.db;

  /// Literal (word) search backed by FTS5, best match first.
  ///
  /// Each whitespace-separated user term is quoted, so FTS5 operator syntax in
  /// arbitrary input cannot raise a query error. When a query contains Han
  /// characters, FTS's `unicode61` tokenizer has indexed them as one whole-run
  /// token (see db.dart), so FTS alone cannot match a 2-char substring like
  /// `网络`; a parameterized-`LIKE` pass supplements FTS for exactly that case
  /// (English queries keep pure FTS semantics). FTS hits come first, LIKE-only
  /// hits are appended newest-first.
  ///
  /// Trashed transcripts are hidden unless [includeTrash] is set;
  /// [onlyTrash] inverts the scope to search the trash *alone* (no live rows
  /// leak in). [onlyTrash] wins if both are set.
  List<Transcript> searchLiteral(
    String query, {
    bool includeTrash = false,
    bool onlyTrash = false,
  }) {
    final terms = _terms(query);
    if (terms.isEmpty) return const [];
    final trash = _trashFilter(includeTrash, onlyTrash);
    final out = <Transcript>[];
    final seen = <int>{};
    void add(List<Row> rows) {
      for (final row in rows) {
        final transcript = transcriptFromRow(row);
        if (seen.add(transcript.id)) out.add(transcript);
      }
    }

    add(
      _db.select(
        'SELECT t.* FROM transcript_fts '
        'JOIN transcript t ON t.id = transcript_fts.rowid '
        'WHERE transcript_fts MATCH ?$trash ORDER BY rank',
        [terms.map(_quoteTerm).join(' ')],
      ),
    );

    if (terms.any(_isHan)) {
      final like = List.filled(
        terms.length,
        r"(t.text LIKE ? ESCAPE '\' OR t.title LIKE ? ESCAPE '\')",
      ).join(' AND ');
      final params = [
        for (final term in terms) ...[_likePattern(term), _likePattern(term)],
      ];
      add(
        _db.select(
          'SELECT t.* FROM transcript t WHERE $like$trash '
          'ORDER BY t.created_at DESC, t.id DESC',
          params,
        ),
      );
    }
    return out;
  }

  /// Combined literal + semantic search, best match first.
  ///
  /// Merges the two ranked lists with Reciprocal Rank Fusion (k = 60), which
  /// needs no score calibration between FTS5 rank and cosine similarity. With
  /// no [Embedder] this is [searchLiteral] re-ranked by the same formula.
  /// Trash scoping works as in [searchLiteral]. Asynchronous only because the
  /// semantic leg awaits the query embed (a worker round-trip).
  Future<List<Transcript>> searchHybrid(
    String query, {
    int topK = 20,
    bool includeTrash = false,
    bool onlyTrash = false,
  }) async {
    final literal = searchLiteral(
      query,
      includeTrash: includeTrash,
      onlyTrash: onlyTrash,
    );
    final semantic = await searchSemantic(
      query,
      topK: topK,
      includeTrash: includeTrash,
      onlyTrash: onlyTrash,
    );

    const k = 60;
    final scores = <int, double>{};
    final byId = <int, Transcript>{};
    void rank(List<Transcript> rows) {
      for (var i = 0; i < rows.length; i++) {
        final id = rows[i].id;
        scores[id] = (scores[id] ?? 0) + 1 / (k + i + 1);
        byId[id] = rows[i];
      }
    }

    rank(literal);
    rank(semantic);

    final ordered = scores.keys.toList()
      ..sort((a, b) => scores[b]!.compareTo(scores[a]!));
    return [for (final id in ordered.take(topK)) byId[id]!];
  }

  /// Semantic search over the `embedding` table, best match first.
  ///
  /// Embeds [query] with the configured [Embedder]'s *query* prompt
  /// ([Embedder.embedQuery]) — awaited, because the production embedder runs
  /// the native encode on its worker isolate — and ranks stored vectors by
  /// cosine similarity. A transcript holds one row per chunk and is scored by
  /// its *best* chunk: "does this transcript contain the answer" is a maximum
  /// over its parts, and averaging them would let a mostly-unrelated transcript
  /// dilute its one relevant passage. Rows from a different model/dimension are
  /// skipped, so a half-migrated table cannot mix incomparable vectors, and rows
  /// whose blob is shorter than `dim` floats are skipped as not-indexable.
  /// Returns nothing when no embedder is configured. Trash scoping works as in
  /// [searchLiteral].
  ///
  /// ponytail: the scan is per chunk row, and each row carries the transcript's
  /// full text, so a large history re-reads text it already has. Select only
  /// `vec` here and fetch the top-K transcripts by id once this shows up in a
  /// profile — the query embed dominates today.
  Future<List<Transcript>> searchSemantic(
    String query, {
    int topK = 20,
    bool includeTrash = false,
    bool onlyTrash = false,
  }) async {
    final embedder = this.embedder;
    if (embedder == null) return const [];

    final rows = _db.select(
      'SELECT e.transcript_id, e.vec, t.* FROM embedding e '
      'JOIN transcript t ON t.id = e.transcript_id '
      'WHERE e.dim = ? AND e.model = ?${_trashFilter(includeTrash, onlyTrash, alias: 't')}',
      [embedder.dim, embedder.id],
    );
    if (rows.isEmpty) return const [];

    final index = EmbeddingIndex(embedder.dim);
    final byId = <int, Transcript>{};
    // Index key -> transcript id: the index scores rows, the fold below turns
    // those scores into one answer per transcript.
    final owners = <int>[];
    for (final row in rows) {
      final blob = row['vec'] as Uint8List;
      if (blob.lengthInBytes < embedder.dim * 4) continue; // truncated blob
      final vector = blob.buffer.asFloat32List(
        blob.offsetInBytes,
        embedder.dim,
      );
      final id = row['transcript_id'] as int;
      index.put(owners.length, vector);
      owners.add(id);
      byId.putIfAbsent(id, () => transcriptFromRow(row));
    }

    final queryVector = await embedder.embedQuery(query);
    final best = <int, double>{};
    for (final hit in index.search(queryVector, topK: owners.length)) {
      final id = owners[hit.id];
      final score = best[id];
      if (score == null || hit.score > score) best[id] = hit.score;
    }
    final ranked = best.keys.toList()
      ..sort((a, b) => best[b]!.compareTo(best[a]!));
    return [for (final id in ranked.take(topK)) byId[id]!];
  }

  static List<String> _terms(String query) =>
      query.split(RegExp(r'\s+')).where((term) => term.isNotEmpty).toList();

  static String _quoteTerm(String term) => '"${term.replaceAll('"', '""')}"';

  /// Han ideographs (BMP: Ext. A + Unified + the main block) — the script
  /// `unicode61` collapses into one token and the LIKE fallback exists for.
  /// Kana/Hangul and supplementary-plane rare ideographs keep whole-token FTS
  /// semantics; normal 2-char Chinese queries are all BMP.
  static final RegExp _han = RegExp(r'[㐀-䶿一-鿿]');

  static bool _isHan(String term) => _han.hasMatch(term);

  static String _likePattern(String term) =>
      '%${term
          .replaceAll(r'\', r'\\')
          .replaceAll('%', r'\%')
          .replaceAll('_', r'\_')}%';

  /// `' AND t.deleted_at ...'` SQL suffix shared by all three search modes.
  static String _trashFilter(
    bool includeTrash,
    bool onlyTrash, {
    String alias = 't',
  }) {
    if (onlyTrash) return ' AND $alias.deleted_at IS NOT NULL';
    return includeTrash ? '' : ' AND $alias.deleted_at IS NULL';
  }
}
