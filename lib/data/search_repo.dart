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
  /// arbitrary input cannot raise a query error. Trashed transcripts are hidden
  /// unless [includeTrash] is set.
  List<Transcript> searchLiteral(String query, {bool includeTrash = false}) {
    final match = _matchExpression(query);
    if (match == null) return const [];

    final rows = _db.select(
      'SELECT t.* FROM transcript_fts '
      'JOIN transcript t ON t.id = transcript_fts.rowid '
      'WHERE transcript_fts MATCH ?'
      '${includeTrash ? '' : ' AND t.deleted_at IS NULL'} '
      'ORDER BY rank',
      [match],
    );
    return [for (final row in rows) transcriptFromRow(row)];
  }

  /// Combined literal + semantic search, best match first.
  ///
  /// Merges the two ranked lists with Reciprocal Rank Fusion (k = 60), which
  /// needs no score calibration between FTS5 rank and cosine similarity. With
  /// no [Embedder] this is [searchLiteral] re-ranked by the same formula.
  List<Transcript> searchHybrid(
    String query, {
    int topK = 20,
    bool includeTrash = false,
  }) {
    final literal = searchLiteral(query, includeTrash: includeTrash);
    final semantic = searchSemantic(
      query,
      topK: topK,
      includeTrash: includeTrash,
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
  /// Embeds [query] with the configured [Embedder] and ranks stored vectors by
  /// cosine similarity. Rows from a different model/dimension are skipped, so a
  /// half-migrated table cannot mix incomparable vectors. Returns nothing when
  /// no embedder is configured.
  List<Transcript> searchSemantic(
    String query, {
    int topK = 20,
    bool includeTrash = false,
  }) {
    final embedder = this.embedder;
    if (embedder == null) return const [];

    final rows = _db.select(
      'SELECT e.transcript_id, e.vec, t.* FROM embedding e '
      'JOIN transcript t ON t.id = e.transcript_id '
      'WHERE e.dim = ? AND e.model = ?'
      '${includeTrash ? '' : ' AND t.deleted_at IS NULL'}',
      [embedder.dim, embedder.id],
    );
    if (rows.isEmpty) return const [];

    final index = EmbeddingIndex(embedder.dim);
    final byId = <int, Transcript>{};
    for (final row in rows) {
      final blob = row['vec'] as Uint8List;
      final vector = blob.buffer.asFloat32List(blob.offsetInBytes, embedder.dim);
      final id = row['transcript_id'] as int;
      index.put(id, vector);
      byId[id] = transcriptFromRow(row);
    }

    return [
      for (final hit in index.search(embedder.embed(query), topK: topK))
        byId[hit.id]!,
    ];
  }

  static String? _matchExpression(String query) {
    final terms = query
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .map((term) => '"${term.replaceAll('"', '""')}"')
        .toList();
    return terms.isEmpty ? null : terms.join(' ');
  }
}
