import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/app/app_state.dart';
import 'package:pocket_asr/data/db.dart';
import 'package:pocket_asr/engine/embedder.dart';

/// Records the vectors it is asked to produce; no native library needed.
class _FakeEmbedder implements Embedder {
  _FakeEmbedder(this.id);

  @override
  final String id;
  @override
  final int dim = 2;

  final List<String> documents = [];
  final List<String> queries = [];

  @override
  Float32List embed(String text) => embedDocument(text);

  @override
  Float32List embedDocument(String text) {
    documents.add(text);
    return _vector(text);
  }

  @override
  Float32List embedQuery(String text) {
    queries.add(text);
    return _vector(text);
  }

  // A stable unit vector: enough to rank, no meaning implied.
  Float32List _vector(String text) => Float32List.fromList([1, 0]);

  @override
  Future<void> dispose() async {}
}

/// Factory that hands back one [_FakeEmbedder] per path, or throws.
class _Factory {
  final Map<String, _FakeEmbedder> created = {};
  bool fail = false;

  Embedder call(String path) {
    if (fail) {
      throw const EmbedderUnavailableException('native library missing');
    }
    return created.putIfAbsent(path, () => _FakeEmbedder('fake:$path'));
  }
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('pocket_asr_embed'));
  tearDown(() => dir.deleteSync(recursive: true));

  String dbPath() => '${dir.path}${Platform.pathSeparator}pocket.sqlite';

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('selecting an embedding model wires the indexer and search repo', () async {
    final db = AppDatabase.open();
    addTearDown(db.close);
    final factory = _Factory();
    final state = AppState(database: db, embedderFactory: factory);

    expect(state.embeddingReady, isFalse);
    expect(state.searchRepo.embedder, isNull);

    state.selectEmbedding(path: 'e5.gguf');

    expect(state.embeddingPath, 'e5.gguf');
    expect(state.embeddingReady, isTrue);
    expect(state.embeddingError, isNull);
    expect(state.searchRepo.embedder, isNotNull);
    expect(state.indexer, isNotNull);
    expect(factory.created.keys, contains('e5.gguf'));

    // The choice is persisted for the next start.
    expect(db.getSetting('embedding_path'), 'e5.gguf');
  });

  test('a new transcript is indexed without a manual call', () async {
    final db = AppDatabase.open();
    addTearDown(db.close);
    final factory = _Factory();
    final state = AppState(database: db, embedderFactory: factory);
    state.selectEmbedding(path: 'e5.gguf');
    await settle();

    final id = state.transcriptRepo.insert(title: 'W', text: 'connect to wifi');
    // Only the repo notification drives this; nothing else is awaited.
    await settle();

    final fake = factory.created['e5.gguf']!;
    expect(fake.documents, contains('connect to wifi'));
    expect(state.searchRepo.searchSemantic('wifi').map((t) => t.id), [id]);
  });

  test('the choice is restored on the next start', () async {
    final factory = _Factory();
    final first = AppState(
      database: AppDatabase.open(path: dbPath()),
      embedderFactory: factory,
    );
    first.selectEmbedding(path: 'e5.gguf');
    await settle();

    final second = AppState(
      database: AppDatabase.open(path: dbPath()),
      embedderFactory: factory,
    );
    addTearDown(second.dispose);
    addTearDown(first.dispose);

    expect(second.embeddingPath, 'e5.gguf');
    expect(second.embeddingReady, isTrue);
  });

  test('a load failure is state, never a deterministic fallback', () {
    final db = AppDatabase.open();
    addTearDown(db.close);
    final factory = _Factory()..fail = true;
    final state = AppState(database: db, embedderFactory: factory);

    state.selectEmbedding(path: 'broken.gguf');

    expect(state.embeddingPath, 'broken.gguf'); // the choice is remembered
    expect(state.embeddingReady, isFalse);
    expect(state.embeddingError, contains('native library missing'));
    expect(state.searchRepo.embedder, isNull); // not swapped for a fake
    expect(state.indexer, isNull);
  });

  test('clearing the embedding drops the indexer and search embedder', () async {
    final db = AppDatabase.open();
    addTearDown(db.close);
    final state = AppState(database: db, embedderFactory: _Factory());
    state.selectEmbedding(path: 'e5.gguf');
    await settle();

    state.clearEmbedding();

    expect(state.embeddingPath, isNull);
    expect(state.embeddingReady, isFalse);
    expect(state.searchRepo.embedder, isNull);
    expect(state.indexer, isNull);
    expect(db.getSetting('embedding_path'), '');
  });

  test('dispose unsubscribes the indexer and ignores later calls', () async {
    final db = AppDatabase.open();
    final state = AppState(
      database: db,
      embedderFactory: _Factory(),
    );
    state.selectEmbedding(path: 'e5.gguf');
    await settle();
    expect(state.transcriptRepo.hasListeners, isTrue);

    state.dispose();

    expect(state.transcriptRepo.hasListeners, isFalse);
    // Post-dispose calls are no-ops, not setState-after-dispose crashes.
    state.selectEmbedding(path: 'other.gguf');
    expect(state.transcriptRepo.hasListeners, isFalse);
  });
}
