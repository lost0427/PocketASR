import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/data/db.dart';
import 'package:pocket_asr/data/search_repo.dart';
import 'package:pocket_asr/data/semantic_indexer.dart';
import 'package:pocket_asr/data/transcript_repo.dart';
import 'package:pocket_asr/engine/crisp_embedder.dart';
import 'package:pocket_asr/engine/embedder.dart';

/// Controllable [Embedder]: fixed vectors per text, records which role
/// (query/document) each text arrived through, and can run a side effect
/// mid-embed to simulate a delete racing the indexer.
class _FakeEmbedder implements Embedder {
  _FakeEmbedder({required this.id});

  @override
  final String id;
  @override
  final int dim = 2;

  final Map<String, Float32List> vectors = {};
  Float32List Function(String text)? custom;
  void Function(String text)? onEmbed;

  final List<String> queryTexts = [];
  final List<String> documentTexts = [];

  @override
  Float32List embed(String text) => embedDocument(text);

  @override
  Float32List embedQuery(String text) {
    queryTexts.add(text);
    return _vector(text);
  }

  @override
  Float32List embedDocument(String text) {
    documentTexts.add(text);
    onEmbed?.call(text);
    return _vector(text);
  }

  Float32List _vector(String text) =>
      custom?.call(text) ?? vectors[text] ?? Float32List(dim);

  @override
  Future<void> dispose() async {}
}

Float32List _v2(double a, double b) => Float32List.fromList([a, b]);

void main() {
  group('SemanticIndexer', () {
    late AppDatabase db;
    late TranscriptRepo transcripts;
    late _FakeEmbedder embedder;
    late SemanticIndexer indexer;
    late SearchRepo search;

    setUp(() {
      db = AppDatabase.open();
      transcripts = TranscriptRepo(db);
      embedder = _FakeEmbedder(id: 'fake-a')
        ..vectors.addAll({
          'connect to the wifi network': _v2(1, 0),
          'beef noodles for lunch': _v2(0, 1),
          'query': _v2(0.9, 0.1),
        });
      indexer = SemanticIndexer(db, embedder: embedder);
      search = SearchRepo(db, embedder: embedder);
    });

    tearDown(() {
      indexer.dispose();
      db.close();
    });

    int embeddingCount({String? model}) => db.db
        .select(
          'SELECT COUNT(*) AS n FROM embedding'
          '${model == null ? '' : ' WHERE model = ?'}',
          [?model],
        )
        .single['n'] as int;

    test('indexPending writes vectors; semantic query ranks by them', () async {
      final wifi = transcripts.insert(title: 'W', text: 'connect to the wifi network');
      final lunch = transcripts.insert(title: 'L', text: 'beef noodles for lunch');

      await indexer.indexPending();

      expect(indexer.phase.value, SemanticIndexPhase.idle);
      expect(indexer.lastError, isNull);
      // Documents went in through embedDocument, the query through
      // embedQuery — the E5 prefix seam (never both, never plain embed).
      expect(embedder.documentTexts, containsAll(['connect to the wifi network', 'beef noodles for lunch']));
      final hits = search.searchSemantic('query');
      expect(hits.map((t) => t.id), [wifi, lunch]);
      expect(embedder.queryTexts, ['query']);
      expect(embedder.documentTexts, isNot(contains('query')));

      // Re-running finds nothing pending: no re-embeds.
      await indexer.indexPending();
      expect(embedder.documentTexts.length, 2);
    });

    test('indexTranscript indexes one row and is idempotent', () async {
      final id = transcripts.insert(title: 'W', text: 'connect to the wifi network');
      transcripts.insert(title: 'L', text: 'beef noodles for lunch');

      await indexer.indexTranscript(id);

      expect(embedder.documentTexts, ['connect to the wifi network']);
      expect(search.searchSemantic('query').single.id, id);

      await indexer.indexTranscript(id); // already vectorized: no-op
      expect(embedder.documentTexts.length, 1);
    });

    test('indexTranscript skips a trashed row without even encoding', () async {
      final id = transcripts.insert(title: 'T', text: 'connect to the wifi network');
      transcripts.softDelete(id);

      await indexer.indexTranscript(id);

      expect(embedder.documentTexts, isEmpty); // liveness checked pre-encode
      expect(embeddingCount(), 0); // no vector resurrected for a dead row
    });

    test('a query never compares another model\'s vectors', () async {
      // Hand-seed the table so the model filter is what decides, not ranking:
      // `near` holds a perfect match for the query tagged 'other-model',
      // `far` a weak match tagged with the query's own model.
      final near = transcripts.insert(title: 'N', text: 'foreign text');
      final far = transcripts.insert(title: 'F', text: 'connect to the wifi network');
      db.db.execute(
        'INSERT INTO embedding(transcript_id, dim, vec, model, created_at) '
        'VALUES(?,?,?,?,?)',
        [near, 2, _v2(0.9, 0.1).buffer.asUint8List(), 'other-model', 0],
      );
      db.db.execute(
        'INSERT INTO embedding(transcript_id, dim, vec, model, created_at) '
        'VALUES(?,?,?,?,?)',
        [far, 2, _v2(0, 1).buffer.asUint8List(), 'fake-a', 0],
      );

      // Without the `model = ?` filter, 'near' would rank first; isolation
      // means it is never even a candidate.
      expect(search.searchSemantic('query').map((t) => t.id), [far]);
    });

    test('rebuild deletes only this model\'s rows and never embeds the trashed', () async {
      final wifi = transcripts.insert(title: 'W', text: 'connect to the wifi network');
      await indexer.indexPending(); // wifi -> fake-a

      // A trashed transcript holding an 'other-model' vector: rebuild's DELETE
      // skips it (other model) and re-embedding skips it (not live), so it
      // survives untouched.
      final doomed = transcripts.insert(title: 'D', text: 'beef noodles for lunch');
      transcripts.softDelete(doomed);
      db.db.execute(
        'INSERT INTO embedding(transcript_id, dim, vec, model, created_at) '
        'VALUES(?,?,?,?,?)',
        [doomed, 2, _v2(1, 1).buffer.asUint8List(), 'other-model', 0],
      );

      await indexer.rebuild();

      expect(embeddingCount(model: 'other-model'), 1);
      expect(embeddingCount(model: 'fake-a'), 1);
      expect(search.searchSemantic('query').map((t) => t.id), [wifi]);
    });

    test('ceiling: one vector per transcript, the active model takes over live rows', () async {
      // `embedding` is keyed by transcript_id alone (db.dart schema), so two
      // models cannot coexist on one live row: fake-a's pending pass replaces
      // the foreign vector. Fails loudly if the PK becomes composite.
      final lunch = transcripts.insert(title: 'L', text: 'beef noodles for lunch');
      db.db.execute(
        'INSERT INTO embedding(transcript_id, dim, vec, model, created_at) '
        'VALUES(?,?,?,?,?)',
        [lunch, 2, _v2(1, 1).buffer.asUint8List(), 'other-model', 0],
      );

      await indexer.indexPending();

      expect(embeddingCount(model: 'other-model'), 0);
      expect(embeddingCount(model: 'fake-a'), 1);
    });

    test('a trash or purge racing the embed never resurrects a row', () async {
      final trashed = transcripts.insert(title: 'T', text: 'connect to the wifi network');
      final purged = transcripts.insert(title: 'P', text: 'beef noodles for lunch');

      // Mid-embed (after the pending snapshot, before the write txn) the row
      // dies: the in-transaction liveness check must catch it for a soft
      // delete, and the FK would catch it for a purge anyway.
      embedder.onEmbed = (text) {
        if (text == 'connect to the wifi network') {
          transcripts.softDelete(trashed);
        }
        if (text == 'beef noodles for lunch') {
          transcripts.softDelete(purged);
          transcripts.purge(purged);
        }
      };
      await indexer.indexPending();

      expect(embeddingCount(), 0);
      embedder.onEmbed = null;

      // And a trashed row is skipped by indexPending from the start, even
      // after restore comes later through a fresh indexPending.
      final late = transcripts.insert(title: 'L', text: 'connect to the wifi network');
      transcripts.softDelete(late);
      await indexer.indexPending();
      expect(embeddingCount(), 0);
    });

    test('bad vectors are refused, exposed as state, and retryable', () async {
      final id = transcripts.insert(title: 'W', text: 'connect to the wifi network');

      embedder.custom = (text) => _v2(double.nan, 0);
      await indexer.indexPending();
      expect(indexer.phase.value, SemanticIndexPhase.failed);
      expect(indexer.lastError, contains('non-finite'));
      expect(embeddingCount(), 0); // nothing half-stored

      embedder.custom = (text) => Float32List(3); // wrong dim for a dim-2 model
      await indexer.indexPending();
      expect(indexer.phase.value, SemanticIndexPhase.failed);
      expect(indexer.lastError, contains('expected 2'));

      // Retry with a good embedder: the same call now succeeds.
      embedder.custom = null;
      await indexer.indexPending();
      expect(indexer.phase.value, SemanticIndexPhase.idle);
      expect(indexer.lastError, isNull);
      expect(search.searchSemantic('query').single.id, id);
    });

    test('jobs serialize and each awaitable call completes its own work', () async {
      transcripts.insert(title: 'W', text: 'connect to the wifi network');
      transcripts.insert(title: 'L', text: 'beef noodles for lunch');

      await Future.wait([indexer.indexPending(), indexer.indexPending()]);

      // If the two jobs overlapped they'd both embed the same two rows.
      expect(embedder.documentTexts.length, 2);
      expect(indexer.phase.value, SemanticIndexPhase.idle);
    });

    test('truncated stored blobs are skipped, not trusted', () async {
      final good = transcripts.insert(title: 'W', text: 'connect to the wifi network');
      final bad = transcripts.insert(title: 'B', text: 'beef noodles for lunch');
      await indexer.indexPending();
      // Corrupt B's blob behind the indexer's back (legacy/hand-written row).
      db.db.execute(
        'UPDATE embedding SET vec = ? WHERE transcript_id = ?',
        [Uint8List(4), bad], // 1 float for a 2-dim model
      );

      final hits = search.searchSemantic('query');
      expect(hits.map((t) => t.id), [good]); // 'B' skipped, no crash
    });
  });

  group('CJK literal search', () {
    late AppDatabase db;
    late TranscriptRepo transcripts;
    late SearchRepo search;

    setUp(() {
      db = AppDatabase.open();
      transcripts = TranscriptRepo(db);
      search = SearchRepo(db);
    });

    tearDown(() => db.close());

    test('two-char substring matches inside a longer Han run', () {
      final wifi = transcripts.insert(title: '设置', text: '请打开无线网络的设置页面');
      final other = transcripts.insert(title: '菜单', text: '今天吃面条还是米饭');

      expect(search.searchLiteral('网络').map((t) => t.id), [wifi]);
      expect(search.searchLiteral('面条').map((t) => t.id), [other]);
      // Conjunction across terms still holds through the LIKE pass.
      expect(search.searchLiteral('网络 设置').map((t) => t.id), [wifi]);
      // Title-only hits match too.
      expect(search.searchLiteral('菜单').map((t) => t.id), [other]);
    });

    test('English-only queries keep exact-token FTS semantics', () {
      final exact = transcripts.insert(title: 'T', text: 'wifi password');
      transcripts.insert(title: 'S', text: 'awifi tokenization');

      expect(search.searchLiteral('wifi').map((t) => t.id), [exact]);
    });

    test('onlyTrash searches the trash alone', () {
      final live = transcripts.insert(title: 'L', text: '无线网络设置');
      final trashed = transcripts.insert(title: 'D', text: '网络连接状态');
      transcripts.softDelete(trashed);

      expect(search.searchLiteral('网络').map((t) => t.id), [live]);
      expect(
        search.searchLiteral('网络', includeTrash: true).map((t) => t.id),
        containsAll([live, trashed]),
      );
      expect(
        search.searchLiteral('网络', onlyTrash: true).map((t) => t.id),
        [trashed],
      );
      expect(
        search.searchSemantic('网络', onlyTrash: true),
        isEmpty, // no embedder configured: honest empty
      );
    });
  });

  group('TranscriptRepo change notifications', () {
    late AppDatabase db;
    late TranscriptRepo transcripts;

    setUp(() {
      db = AppDatabase.open();
      transcripts = TranscriptRepo(db);
    });

    tearDown(() {
      transcripts.dispose();
      db.close();
    });

    test('fires once per successful insert/delete/restore/purge', () {
      var notifications = 0;
      transcripts.addListener(() => notifications++);

      transcripts.insert(title: 'A', text: 'first'); // id 1
      expect(notifications, 1);

      transcripts.insert(title: 'B', text: 'second'); // id 2
      expect(notifications, 2);

      transcripts.softDelete(1);
      expect(notifications, 3);
      transcripts.restore(1);
      expect(notifications, 4);

      // The trash flow: delete then permanently purge id 1.
      transcripts.softDelete(1);
      transcripts.purge(1);
      expect(notifications, 6);
      expect(transcripts.list().map((t) => t.id), [2]);

      transcripts.softDelete(2);
      transcripts.purgeAll();
      expect(notifications, 8); // delete + purgeAll above
      expect(transcripts.listTrash(), isEmpty);
    });
  });

  group('CrispEmbedder identity', () {
    test('full path + size, never basename-only mixing of models', () {
      final dirA = Directory.systemTemp.createTempSync('embed-a');
      final dirB = Directory.systemTemp.createTempSync('embed-b');
      try {
        final a = File('${dirA.path}${Platform.pathSeparator}e5.gguf')
          ..writeAsBytesSync(List.filled(4, 1));
        final b = File('${dirB.path}${Platform.pathSeparator}e5.gguf')
          ..writeAsBytesSync(List.filled(8, 1));
        final c = File('${dirA.path}${Platform.pathSeparator}gemma.gguf')
          ..writeAsBytesSync(List.filled(4, 1));

        // Same basename, different paths → different identities.
        expect(CrispEmbedder.identityFor(a.path), isNot(CrispEmbedder.identityFor(b.path)));
        // Identity carries the path and the size, not just the name.
        expect(CrispEmbedder.identityFor(a.path), contains(a.path));
        expect(CrispEmbedder.identityFor(a.path), endsWith(':4'));
        // Same dir, same size, different file → still distinct.
        expect(CrispEmbedder.identityFor(a.path), isNot(CrispEmbedder.identityFor(c.path)));
        // An in-place model swap (same path, new content/size) is a new model.
        final before = CrispEmbedder.identityFor(a.path);
        a.writeAsBytesSync(List.filled(9, 1));
        expect(CrispEmbedder.identityFor(a.path), isNot(before));
        expect(CrispEmbedder.identityFor('a-nonexistent.gguf'),
            'crispembed:a-nonexistent.gguf'); // no throw on a bare name
      } finally {
        dirA.deleteSync(recursive: true);
        dirB.deleteSync(recursive: true);
      }
    });
  });
}
