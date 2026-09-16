import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/engine/model_catalog.dart';

void main() {
  group('parseModelAllowlist', () {
    test('reads required fields and keeps optional ones nullable', () {
      final entries = parseModelAllowlist('''
      {
        "version": 1,
        "models": [
          {
            "id": "a",
            "displayName": "Model A",
            "fileName": "a.onnx",
            "family": "sensevoice",
            "quant": "q8",
            "sizeBytes": 123
          },
          {"id": "b", "fileName": "b.onnx"}
        ]
      }
      ''');

      expect(entries, hasLength(2));
      expect(entries.first.id, 'a');
      expect(entries.first.displayName, 'Model A');
      expect(entries.first.family, 'sensevoice');
      expect(entries.first.quant, 'q8');
      expect(entries.first.sizeBytes, 123);
      // Missing displayName falls back to the id; missing size stays unknown.
      expect(entries.last.displayName, 'b');
      expect(entries.last.sizeBytes, isNull);
    });

    test('parses multi-file bundles with roles, engine, type, license', () {
      final entries = parseModelAllowlist('''
      {
        "models": [
          {
            "id": "w",
            "displayName": "Whisper",
            "engine": "sherpa",
            "type": "asr",
            "family": "whisper",
            "quant": "int8",
            "languages": ["en", "zh"],
            "license": "MIT",
            "files": [
              {"fileName": "enc.onnx", "role": "encoder",
               "url": "https://host/enc", "sizeBytes": 10,
               "sha256": "aaa"},
              {"fileName": "tok.txt", "role": "tokens",
               "url": "https://host/tok", "sizeBytes": 5,
               "sha256": "bbb"}
            ]
          }
        ]
      }
      ''');

      final entry = entries.single;
      expect(entry.engine, 'sherpa');
      expect(entry.type, 'asr');
      expect(entry.license, 'MIT');
      expect(entry.languages, ['en', 'zh']);
      expect(entry.files, hasLength(2));
      // Flat fields follow the first (primary when unmarked) file for
      // existing callers.
      expect(entry.fileName, 'enc.onnx');
      expect(entry.url, 'https://host/enc');
      expect(entry.sha256, 'aaa');
      // Bundle total sums verified file sizes only.
      expect(entry.sizeBytes, 15);
      expect(entry.bundleFiles.map((f) => f.role), ['encoder', 'tokens']);
      // No file claims the primary role, so the first one is primary.
      expect(entry.primaryFile.fileName, 'enc.onnx');
    });

    test('primary role wins over list order for the flat fields', () {
      final entry = parseModelAllowlist('''
      {"models": [{"id": "m", "files": [
        {"fileName": "tokens.txt", "role": "tokens"},
        {"fileName": "model.gguf", "role": "model", "url": "https://host/m"}
      ]}]}
      ''').single;

      expect(entry.fileName, 'model.gguf');
      expect(entry.url, 'https://host/m');
      expect(entry.type, 'asr'); // default
    });

    test('rejects malformed allowlists instead of dropping entries', () {
      expect(() => parseModelAllowlist('[]'), throwsFormatException);
      expect(
        () => parseModelAllowlist('{"models": {}}'),
        throwsFormatException,
      );
      expect(
        () => parseModelAllowlist('{"models": [{"fileName": "x"}]}'),
        throwsFormatException,
      );
      expect(
        () => parseModelAllowlist(
          '{"models": [{"id": "a", "fileName": "a", "sizeBytes": -1}]}',
        ),
        throwsFormatException,
      );
    });

    test('rejects file names and ids that could escape the bundle dir', () {
      expect(
        () => parseModelAllowlist(
          '{"models": [{"id": "a", "fileName": "x", "files": '
          '[{"fileName": "../evil.onnx"}]}]}',
        ),
        throwsFormatException,
      );
      expect(
        () => parseModelAllowlist(
          '{"models": [{"id": "a", "fileName": "sub/x.onnx"}]}',
        ),
        throwsFormatException,
      );
      expect(
        () => parseModelAllowlist(
          '{"models": [{"id": "../escape", "fileName": "x.onnx"}]}',
        ),
        throwsFormatException,
      );
      expect(
        () => parseModelAllowlist(
          '{"models": [{"id": "a", "fileName": "x", "files": '
          '[{"fileName": "ok", "sizeBytes": "big"}]}]}',
        ),
        throwsFormatException,
      );
    });

    test('the shipped asset parses with unique ids', () {
      final source = File(modelAllowlistAsset).readAsStringSync();
      final entries = parseModelAllowlist(source);
      expect(entries, isNotEmpty);
      expect(entries.map((e) => e.id).toSet(), hasLength(entries.length));
    });

    test('the shipped asset lists only verified bundles with real facts', () {
      final source = File(modelAllowlistAsset).readAsStringSync();
      final entries = parseModelAllowlist(source);
      expect(entries, hasLength(5));
      for (final entry in entries) {
        // Every allowlist file must carry a verified size and checksum —
        // the store and downloader gate on both.
        for (final file in entry.bundleFiles) {
          expect(file.sizeBytes, isNotNull, reason: file.fileName);
          expect(file.sha256, isNotNull, reason: file.fileName);
          // ASR/embedding live on Hugging Face; the Silero VAD comes from a
          // (mutable) k2-fsa GitHub release tag — the sha256 is the gate.
          expect(file.url, startsWith('https://'), reason: file.fileName);
        }
        expect(entry.engine, isNotNull);
        expect(entry.type, anyOf('asr', 'embedding', 'vad'));
      }
      // The two multi-file sherpa bundles keep their companions distinct.
      final whisper = entries.firstWhere((e) => e.family == 'whisper');
      expect(
        whisper.bundleFiles.map((f) => f.role),
        containsAll(['encoder', 'decoder', 'tokens']),
      );
    });
  });

  group('LocalModelStore', () {
    const entry = ModelEntry(id: 'a', displayName: 'A', fileName: 'a.onnx');
    const bundle = ModelEntry(
      id: 'w',
      displayName: 'Whisper',
      fileName: 'unused',
      family: 'whisper',
      files: [
        ModelFile(
          fileName: 'model.onnx',
          role: 'model',
          sizeBytes: 4,
        ),
        ModelFile(fileName: 'tokens.txt', role: 'tokens', sizeBytes: 2),
      ],
    );

    late Directory dir;
    late LocalModelStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('pocket_asr_models');
      store = LocalModelStore(dir);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    void writeFile(ModelEntry e, ModelFile file, List<int> bytes) {
      final path = store.pathToFile(e, file);
      File(path).parent.createSync(recursive: true);
      File(path).writeAsBytesSync(bytes);
    }

    test('reports presence and sums only downloaded files', () {
      expect(store.isDownloaded(entry), isFalse);
      expect(store.diskUsageBytes([entry]), 0);

      writeFile(entry, entry.bundleFiles.single, List.filled(2048, 0));
      expect(store.isDownloaded(entry), isTrue);
      expect(store.diskUsageBytes([entry]), 2048);
    });

    test('bundles isolate directories so file names cannot collide', () {
      const a = ModelEntry(id: 'a', displayName: 'A', fileName: 'tokens.txt');
      const b = ModelEntry(id: 'b', displayName: 'B', fileName: 'tokens.txt');

      writeFile(a, a.bundleFiles.single, [1]);
      expect(store.isDownloaded(a), isTrue);
      expect(store.isDownloaded(b), isFalse);
      expect(store.pathFor(a), isNot(store.pathFor(b)));
    });

    test('bundle is ready only with every companion at the right size', () {
      writeFile(bundle, bundle.files.first, [0, 0, 0, 0]);
      expect(store.isDownloaded(bundle), isFalse); // companion missing

      writeFile(bundle, bundle.files.last, [0]); // wrong size (wants 2)
      expect(store.isDownloaded(bundle), isFalse);

      writeFile(bundle, bundle.files.last, [0, 0]);
      expect(store.isDownloaded(bundle), isTrue);
      expect(store.diskUsageBytes([bundle]), 6);
    });

    test('delete removes the whole bundle including .part debris', () async {
      writeFile(bundle, bundle.files.first, [0, 0, 0, 0]);
      writeFile(bundle, bundle.files.last, [0, 0]);
      File('${store.pathToFile(bundle, bundle.files.first)}.part')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([9]);

      await store.delete(bundle);

      expect(store.isDownloaded(bundle), isFalse);
      expect(Directory(store.bundleDirFor(bundle)).existsSync(), isFalse);
      await store.delete(bundle); // must not throw
    });

    test('delete removes the file and is a no-op when missing', () async {
      writeFile(entry, entry.bundleFiles.single, [1, 2, 3]);
      await store.delete(entry);
      expect(store.isDownloaded(entry), isFalse);
      await store.delete(entry); // must not throw
    });

    test('refuses file names that would escape the bundle dir', () {
      const smuggled = ModelEntry(
        id: 'a',
        displayName: 'A',
        fileName: 'x',
        files: [ModelFile(fileName: '../evil.onnx', role: 'model')],
      );
      expect(() => store.pathFor(smuggled), throwsStateError);
    });

    test('specFor maps bundle roles onto EngineModelSpec', () {
      final spec = store.specFor(bundle);
      expect(spec.path, store.pathToFile(bundle, bundle.files.first));
      expect(spec.family, 'whisper');
      expect(spec.tokensPath, store.pathToFile(bundle, bundle.files.last));
      expect(
        store.specFor(entry).path,
        store.pathToFile(entry, entry.bundleFiles.single),
      );
    });
  });
}
