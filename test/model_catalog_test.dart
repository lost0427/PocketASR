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

    test('the shipped asset parses with unique ids', () {
      final source = File(modelAllowlistAsset).readAsStringSync();
      final entries = parseModelAllowlist(source);
      expect(entries, isNotEmpty);
      expect(entries.map((e) => e.id).toSet(), hasLength(entries.length));
    });
  });

  group('LocalModelStore', () {
    const entry = ModelEntry(id: 'a', displayName: 'A', fileName: 'a.onnx');

    late Directory dir;
    late LocalModelStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('pocket_asr_models');
      store = LocalModelStore(dir);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('reports presence and sums only downloaded files', () {
      expect(store.isDownloaded(entry), isFalse);
      expect(store.diskUsageBytes([entry]), 0);

      File(store.pathFor(entry)).writeAsBytesSync(List.filled(2048, 0));
      expect(store.isDownloaded(entry), isTrue);
      expect(store.diskUsageBytes([entry]), 2048);
    });

    test('delete removes the file and is a no-op when missing', () async {
      File(store.pathFor(entry)).writeAsBytesSync([1, 2, 3]);
      await store.delete(entry);
      expect(store.isDownloaded(entry), isFalse);
      await store.delete(entry); // must not throw
    });
  });
}
