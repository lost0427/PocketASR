import 'package:sqlite3/sqlite3.dart';

import 'db.dart';
import 'transcript_repo.dart';

/// Read-side search over stored transcripts.
class SearchRepo {
  SearchRepo(this._database);

  final AppDatabase _database;

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
  /// Stub until Phase 8: semantics are not wired yet, so this falls back to
  /// [searchLiteral] and only honours [topK]/[includeTrash]. Once embeddings
  /// land it will merge and re-rank both result sets.
  List<Transcript> searchHybrid(
    String query, {
    int topK = 20,
    bool includeTrash = false,
  }) => searchLiteral(
    query,
    includeTrash: includeTrash,
  ).take(topK).toList();

  /// Semantic search over the `embedding` table.
  ///
  /// Stub until Phase 8: it will embed [query] with CrispEmbed and rank by
  /// cosine similarity. Returns nothing meanwhile so callers can already wire
  /// the UI up.
  List<Transcript> searchSemantic(String query, {int topK = 20}) => const [];

  static String? _matchExpression(String query) {
    final terms = query
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .map((term) => '"${term.replaceAll('"', '""')}"')
        .toList();
    return terms.isEmpty ? null : terms.join(' ');
  }
}
