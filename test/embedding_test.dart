import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/data/db.dart';
import 'package:pocket_asr/data/search_repo.dart';
import 'package:pocket_asr/data/transcript_repo.dart';
import 'package:pocket_asr/engine/embedder.dart';
import 'package:pocket_asr/engine/embedding_index.dart';

void main() {
  group('EmbeddingModelProfile', () {
    test('Qwen3 instructs queries and leaves documents unchanged', () {
      expect(
        EmbeddingModelProfile.qwen3.queryInput('无线网络'),
        'Instruct: Given a web search query, retrieve relevant passages that '
        'answer the query\nQuery:无线网络',
      );
      expect(EmbeddingModelProfile.qwen3.documentInput('会议记录'), '会议记录');
    });

    test('metadata profile applies prefixes declared by the GGUF', () {
      expect(
        EmbeddingModelProfile.metadata.queryInput(
          'wifi',
          metadataPrefix: 'query: ',
        ),
        'query: wifi',
      );
      expect(
        EmbeddingModelProfile.metadata.documentInput(
          'notes',
          metadataPrefix: 'passage: ',
        ),
        'passage: notes',
      );
    });
  });

  group('EmbeddingIndex', () {
    test('normalize makes a unit vector and keeps zero at zero', () {
      final unit = EmbeddingIndex.normalize(Float32List.fromList([3, 4]));
      expect(unit[0], closeTo(0.6, 1e-6));
      expect(unit[1], closeTo(0.8, 1e-6));

      final zero = EmbeddingIndex.normalize(Float32List.fromList([0, 0]));
      expect(zero.every((value) => value == 0), isTrue);
    });

    test('dot product equals cosine for unit vectors', () {
      final a = EmbeddingIndex.normalize(Float32List.fromList([1, 0]));
      final b = EmbeddingIndex.normalize(Float32List.fromList([0, 1]));
      final c = EmbeddingIndex.normalize(Float32List.fromList([1, 1]));

      expect(EmbeddingIndex.dot(a, b), closeTo(0, 1e-6)); // orthogonal
      expect(EmbeddingIndex.dot(a, a), closeTo(1, 1e-6)); // identical
      expect(EmbeddingIndex.dot(a, c), closeTo(0.7071, 1e-4)); // 45 degrees
    });

    test('search returns topK by cosine, best first', () {
      final index = EmbeddingIndex(2)
        ..put(1, Float32List.fromList([1, 0]))
        ..put(2, Float32List.fromList([0, 1]))
        ..put(3, Float32List.fromList([1, 1]));

      final hits = index.search(Float32List.fromList([1, 0.1]));
      expect(hits.map((h) => h.id), [1, 3, 2]);
      expect(hits.first.score, closeTo(1 / math.sqrt(1.01), 1e-6));

      expect(index.search(Float32List.fromList([1, 0]), topK: 2), hasLength(2));
      expect(index.search(Float32List.fromList([1, 0]), topK: 0), isEmpty);
    });

    test('rejects wrong dimension', () {
      final index = EmbeddingIndex(2)..put(1, Float32List(2));
      expect(() => index.put(1, Float32List(3)), throwsArgumentError);
      expect(() => index.search(Float32List(3)), throwsArgumentError);
    });
  });

  group('DeterministicEmbedder', () {
    test('is a pure function of the text', () {
      final a = DeterministicEmbedder().embed('WiFi 连接设置');
      final b = DeterministicEmbedder().embed('WiFi 连接设置');
      expect(a, b);
      expect(a.length, 128);
    });

    test('ranks overlapping text above unrelated text', () {
      final embedder = DeterministicEmbedder();
      final query = EmbeddingIndex.normalize(embedder.embed('连接无线网络设置'));
      final related = EmbeddingIndex.normalize(embedder.embed('无线网络连接'));
      final unrelated = EmbeddingIndex.normalize(
        embedder.embed('beef noodles lunch'),
      );

      expect(
        EmbeddingIndex.dot(query, related),
        greaterThan(EmbeddingIndex.dot(query, unrelated)),
      );
    });
  });

  group('SearchRepo semantic seam', () {
    late AppDatabase db;
    late TranscriptRepo transcripts;
    late DeterministicEmbedder embedder;
    late SearchRepo search;

    setUp(() {
      db = AppDatabase.open(); // in-memory
      transcripts = TranscriptRepo(db);
      embedder = DeterministicEmbedder();
      search = SearchRepo(db, embedder: embedder);
    });

    tearDown(() => db.close());

    int store(String title, String text) {
      final id = transcripts.insert(title: title, text: text);
      final vector = embedder.embed(text);
      db.db.execute(
        'INSERT INTO embedding(transcript_id, dim, vec, model, created_at) '
        'VALUES(?,?,?,?,?)',
        [
          id,
          embedder.dim,
          vector.buffer.asUint8List(vector.offsetInBytes, vector.lengthInBytes),
          embedder.id,
          0,
        ],
      );
      return id;
    }

    test(
      'searchSemantic ranks by similarity and hides trash by default',
      () async {
        final wifi = store('WiFi', 'connect to the wifi network');
        final lunch = store('Lunch', 'beef noodles for lunch');

        final hits = await search.searchSemantic('wifi network');
        expect(hits.first.id, wifi);
        expect(
          (await search.searchSemantic('wifi network', topK: 1)).single.id,
          wifi,
        );
        expect(hits.map((t) => t.id), contains(lunch)); // still comparable

        transcripts.softDelete(wifi);
        expect(
          (await search.searchSemantic('wifi network')).map((t) => t.id),
          isNot(contains(wifi)),
        );
        expect(
          (await search.searchSemantic(
            'wifi network',
            includeTrash: true,
          )).first.id,
          wifi,
        );
      },
    );

    test(
      'returns nothing without an embedder and skips other models',
      () async {
        final wifi = store('WiFi', 'wifi network');
        final other = transcripts.insert(title: 'Other', text: 'wifi network');
        db.db.execute(
          'INSERT INTO embedding(transcript_id, dim, vec, model, created_at) '
          'VALUES(?,?,?,?,?)',
          [
            other,
            3,
            Float32List.fromList([1, 0, 0]).buffer.asUint8List(),
            'other-model',
            0,
          ],
        );

        expect(await SearchRepo(db).searchSemantic('wifi'), isEmpty);
        expect((await search.searchSemantic('wifi')).map((t) => t.id), [wifi]);
      },
    );

    test('searchHybrid fuses literal and semantic matches', () async {
      final wifi = store('WiFi', 'connect to the wifi network');
      final tea = transcripts.insert(
        title: 'Tea',
        text: 'how to brew green tea',
      );

      final ids = (await search.searchHybrid('wifi')).map((t) => t.id);
      expect(ids, contains(wifi)); // literal + semantic both rank it
      expect(ids, isNot(contains(tea)));
      expect(await search.searchHybrid('wifi', topK: 1), hasLength(1));

      transcripts.softDelete(wifi);
      expect(await search.searchHybrid('wifi'), isEmpty);
      expect(
        (await search.searchHybrid(
          'wifi',
          includeTrash: true,
        )).map((t) => t.id),
        contains(wifi),
      );
    });
  });
}
