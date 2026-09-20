import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/data/db.dart';
import 'package:pocket_asr/data/search_repo.dart';
import 'package:pocket_asr/data/transcript_repo.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late AppDatabase database;
  late TranscriptRepo transcripts;
  late SearchRepo search;

  setUp(() {
    database = AppDatabase.open(); // in-memory
    transcripts = TranscriptRepo(database);
    search = SearchRepo(database);
  });

  tearDown(() => database.close());

  test('insert, FTS hit, trash visibility, restore, purge', () {
    final tea = transcripts.insert(title: 'Tea', text: 'how to brew green tea');
    final wifi = transcripts.insert(
      title: 'WiFi',
      text: 'connect to the wifi network',
    );
    final lunch = transcripts.insert(
      title: 'Lunch',
      text: 'beef noodles for lunch',
    );

    expect(
      transcripts.list().map((t) => t.id),
      containsAll([tea, wifi, lunch]),
    );

    expect(search.searchLiteral('tea').map((t) => t.id), [tea]);
    expect(search.searchLiteral('wifi').single.id, wifi);
    expect(search.searchLiteral('noodles').single.id, lunch);

    // Soft delete: out of the list, visible in trash, hidden from search.
    transcripts.softDelete(wifi);
    expect(transcripts.list().map((t) => t.id), isNot(contains(wifi)));
    expect(transcripts.listTrash().single.id, wifi);
    expect(transcripts.listTrash().single.isTrashed, isTrue);
    expect(search.searchLiteral('wifi'), isEmpty);

    // Restore returns it to both sides.
    transcripts.restore(wifi);
    expect(transcripts.listTrash(), isEmpty);
    expect(search.searchLiteral('wifi').single.id, wifi);

    // Purge is a no-op for a live row...
    transcripts.purge(wifi);
    expect(transcripts.list().map((t) => t.id), contains(wifi));

    // ...and erases a trashed row plus its FTS entry.
    transcripts.softDelete(lunch);
    transcripts.purge(lunch);
    expect(transcripts.list().map((t) => t.id), isNot(contains(lunch)));
    expect(search.searchLiteral('noodles'), isEmpty);

    transcripts.softDelete(tea);
    transcripts.softDelete(wifi);
    transcripts.purgeAll();
    expect(transcripts.list(), isEmpty);
    expect(transcripts.listTrash(), isEmpty);
  });

  test('purge cascades to segment and embedding rows', () {
    final id = transcripts.insert(
      title: 'Meeting',
      text: 'hello',
      segments: const [
        SegmentDraft(startMs: 0, endMs: 500, text: 'hello'),
        SegmentDraft(startMs: 500, endMs: 1200, text: 'world'),
      ],
    );
    database.db.execute(
      'INSERT INTO embedding(transcript_id, dim, vec, model, created_at) '
      'VALUES(?,?,?,?,?)',
      [
        id,
        4,
        Uint8List.fromList([0, 0, 0, 0]),
        'test',
        0,
      ],
    );

    expect(
      database.db.select('SELECT * FROM segment WHERE transcript_id = ?', [id]),
      hasLength(2),
    );

    transcripts.softDelete(id);
    transcripts.purge(id);

    expect(
      database.db.select('SELECT * FROM segment WHERE transcript_id = ?', [id]),
      isEmpty,
    );
    expect(
      database.db.select('SELECT * FROM embedding WHERE transcript_id = ?', [
        id,
      ]),
      isEmpty,
    );
  });

  test('settings round-trip', () {
    expect(database.getSetting('themeMode'), isNull);
    database.setSetting('themeMode', 'dark');
    expect(database.getSetting('themeMode'), 'dark');
    database.setSetting('themeMode', 'light');
    expect(database.getSetting('themeMode'), 'light');
  });

  test('arbitrary user input cannot inject FTS syntax', () {
    transcripts.insert(title: 'Note', text: 'safe text');

    expect(
      () => search.searchLiteral('"; DROP TABLE transcript; --'),
      returnsNormally,
    );
    expect(search.searchLiteral('   '), isEmpty);
    expect(transcripts.list(), hasLength(1)); // table still there
  });

  test('CJK whole-run queries match; substrings ride the LIKE pass', () {
    final id = transcripts.insert(title: 'Meeting notes', text: '连接无线网络设置');

    expect(search.searchLiteral('连接无线网络设置').single.id, id);
    // unicode61 still indexes one token per CJK run (see db.dart); SearchRepo
    // supplements Han queries with a literal LIKE pass, so substrings match.
    expect(search.searchLiteral('网络').single.id, id);
  });

  test(
    'searchHybrid falls back to literal results with topK/trash shape',
    () async {
      final a = transcripts.insert(title: 'A', text: 'shared keyword alpha');
      final b = transcripts.insert(title: 'B', text: 'shared keyword beta');
      final c = transcripts.insert(title: 'C', text: 'shared keyword gamma');

      expect(
        (await search.searchHybrid('shared')).map((t) => t.id),
        containsAll([a, b, c]),
      );
      expect(await search.searchHybrid('shared', topK: 2), hasLength(2));

      transcripts.softDelete(c);
      expect(
        (await search.searchHybrid('shared')).map((t) => t.id),
        isNot(contains(c)),
      );
      expect(
        (await search.searchHybrid(
          'shared',
          includeTrash: true,
        )).map((t) => t.id),
        contains(c),
      );
    },
  );

  test('opening a database newer than schemaVersion throws', () {
    final dir = Directory.systemTemp.createTempSync('pocket_asr_db_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/newer.db';

    final raw = sqlite3.open(path);
    raw.execute('PRAGMA user_version = ${schemaVersion + 1}');
    raw.close();

    expect(() => AppDatabase.open(path: path), throwsA(isA<StateError>()));
  });

  test('a v1 index migrates to per-chunk rows and drops the old vectors', () {
    final dir = Directory.systemTemp.createTempSync('pocket_asr_db_v1');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/v1.db';

    // A v1 database, carrying only the table the v2 step touches: the upgrade
    // drops and recreates `embedding`, so nothing else has to be present.
    final raw = sqlite3.open(path);
    raw.execute('CREATE TABLE transcript(id INTEGER PRIMARY KEY)'); // FK target
    raw.execute('INSERT INTO transcript(id) VALUES(1)');
    raw.execute(
      'CREATE TABLE embedding('
      'transcript_id INTEGER PRIMARY KEY, dim INTEGER NOT NULL, '
      'vec BLOB NOT NULL, model TEXT NOT NULL, created_at INTEGER NOT NULL)',
    );
    raw.execute(
      'INSERT INTO embedding(transcript_id, dim, vec, model, created_at) '
      'VALUES(1, 2, ?, ?, 0)',
      [Uint8List(8), 'old-model'],
    );
    raw.execute('PRAGMA user_version = 1');
    raw.close();

    final migrated = AppDatabase.open(path: path);
    addTearDown(migrated.close);

    expect(
      migrated.db.select('PRAGMA user_version').first.values.first,
      schemaVersion,
    );
    // Derived data: the stale mean vector is gone, so the next indexPending
    // pass re-embeds every transcript.
    expect(migrated.db.select('SELECT * FROM embedding'), isEmpty);
    // The ordinal now belongs to the key, and the old 5-column insert still
    // works (ordinal defaults to 0) for a transcript that fits one chunk.
    migrated.db.execute(
      'INSERT INTO embedding(transcript_id, dim, vec, model, created_at) '
      'VALUES(1, 2, ?, ?, 0)',
      [Uint8List(8), 'new-model'],
    );
    expect(
      migrated.db.select('SELECT chunk FROM embedding').single['chunk'],
      0,
    );
  });
}
