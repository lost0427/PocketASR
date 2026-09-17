import 'package:sqlite3/sqlite3.dart';

/// On-disk schema version, tracked with `PRAGMA user_version`.
const int schemaVersion = 1;

/// Opens the app's SQLite database and brings it up to [schemaVersion].
///
/// Omit [path] for an in-memory database (tests); the app passes a file under
/// its private data directory. `sqlite3` comes from `sqlite3_flutter_libs` on
/// device and from the host library in tests.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  factory AppDatabase.open({String? path}) {
    final raw = path == null ? sqlite3.openInMemory() : sqlite3.open(path);
    raw.execute('PRAGMA foreign_keys = ON');
    try {
      _migrate(raw);
    } catch (_) {
      raw.close();
      rethrow;
    }
    return AppDatabase._(raw);
  }

  void close() => db.close();

  /// Reads a [settings] value, or null when the key is unset.
  String? getSetting(String key) {
    final rows = db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  /// Inserts or overwrites a [settings] value.
  void setSetting(String key, String value) {
    db.execute(
      'INSERT INTO settings(key, value) VALUES(?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }
}

void _migrate(Database db) {
  final version = db.select('PRAGMA user_version').first.values.first! as int;
  if (version > schemaVersion) {
    throw StateError(
      'Database schema version $version is newer than the supported '
      'version $schemaVersion; refusing to open it (downgrade the app or '
      'migrate the file).',
    );
  }
  if (version == schemaVersion) return;

  db.execute('BEGIN');
  try {
    if (version < 1) db.execute(_schemaV1);
    db.execute('PRAGMA user_version = $schemaVersion');
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

// FTS5 stays in sync through the three triggers below; soft deletes keep the
// row and are filtered at query time (see SearchRepo).
//
// ponytail: `unicode61` indexes a whole run of CJK as one token, so Chinese
// substring search does not match (measured: '连接无线网络设置' is a single
// token). `trigram` only fixes queries of 3+ chars, so it does not help the
// common 2-char case either — both are intentional for now (plan R9), semantic
// search lands in Phase 8. Revisit with a per-character index or trigram+LIKE
// if literal CJK search turns out to matter.
const String _schemaV1 = '''
CREATE TABLE transcript(
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  audio_path TEXT,
  audio_seconds REAL,
  text TEXT NOT NULL DEFAULT '',
  lang TEXT,
  engine TEXT,
  model_family TEXT,
  model_path TEXT,
  backend TEXT,
  rtf REAL,
  total_ms INTEGER,
  created_at INTEGER NOT NULL,
  deleted_at INTEGER
);

CREATE TABLE segment(
  id INTEGER PRIMARY KEY,
  transcript_id INTEGER NOT NULL REFERENCES transcript(id) ON DELETE CASCADE,
  start_ms INTEGER,
  end_ms INTEGER,
  text TEXT
);

CREATE TABLE embedding(
  transcript_id INTEGER PRIMARY KEY REFERENCES transcript(id) ON DELETE CASCADE,
  dim INTEGER NOT NULL,
  vec BLOB NOT NULL,
  model TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE settings(
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE VIRTUAL TABLE transcript_fts USING fts5(
  text, title,
  content='transcript', content_rowid='id', tokenize='unicode61'
);

CREATE TRIGGER transcript_ai AFTER INSERT ON transcript BEGIN
  INSERT INTO transcript_fts(rowid, text, title)
    VALUES (new.id, new.text, new.title);
END;

CREATE TRIGGER transcript_ad AFTER DELETE ON transcript BEGIN
  INSERT INTO transcript_fts(transcript_fts, rowid, text, title)
    VALUES ('delete', old.id, old.text, old.title);
END;

CREATE TRIGGER transcript_au AFTER UPDATE ON transcript BEGIN
  INSERT INTO transcript_fts(transcript_fts, rowid, text, title)
    VALUES ('delete', old.id, old.text, old.title);
  INSERT INTO transcript_fts(rowid, text, title)
    VALUES (new.id, new.text, new.title);
END;
''';
