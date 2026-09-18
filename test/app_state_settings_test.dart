import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/app/app_state.dart';
import 'package:pocket_asr/data/db.dart';
import 'package:pocket_asr/engine/asr_engine.dart';
import 'package:pocket_asr/engine/model_catalog.dart';
import 'package:pocket_asr/core/audio/audio_source.dart';

/// Chunking and the shared model selection must survive a restart; anything
/// unparseable or out of range falls back to defaults, and a selection whose
/// files vanished is cleared rather than handed to an engine.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('pocket_asr_state'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// Writes [bytes] inside the temp dir and returns the absolute path.
  String write(String name, List<int> bytes) {
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file.path;
  }

  test('chunk settings and the model path persist and restore', () {
    final db = AppDatabase.open();
    addTearDown(db.close);

    final path = write('sensevoice.onnx', [1, 2, 3]);
    AppState(database: db)
      ..chunkStrategy = ChunkStrategy.energy
      ..chunkSeconds = 12
      ..energyThreshold = 0.02
      ..speechPadMs = 40
      ..modelPath = path;

    final restored = AppState(database: db);
    expect(restored.chunkStrategy, ChunkStrategy.energy);
    expect(restored.chunkSeconds, 12);
    expect(restored.energyThreshold, 0.02);
    expect(restored.speechPadMs, 40);
    expect(restored.audioDecoderPreference, AudioDecoderPreference.automatic);
    expect(restored.modelPath, path);
    // Overlap is never exposed and stays off by default.
    expect(restored.chunkSettings!.overlapSeconds, 0);
  });

  test('audio decoder preference persists and restores', () {
    final db = AppDatabase.open();
    addTearDown(db.close);
    final state = AppState(database: db)
      ..audioDecoderPreference = AudioDecoderPreference.preferHardware;

    expect(
      AppState(database: db).audioDecoderPreference,
      AudioDecoderPreference.preferHardware,
    );
    state.audioDecoderPreference = AudioDecoderPreference.preferSoftware;
    expect(
      AppState(database: db).audioDecoderPreference,
      AudioDecoderPreference.preferSoftware,
    );
  });

  test('invalid stored values fall back to the defaults', () {
    final db = AppDatabase.open();
    addTearDown(db.close);
    db.setSetting('chunk_mode', 'nonsense');
    db.setSetting('chunk_seconds', '-3');
    db.setSetting('chunk_threshold', 'not-a-number');
    db.setSetting('chunk_pad_ms', '99999');

    final state = AppState(database: db);
    expect(state.chunkStrategy, ChunkStrategy.fixed);
    expect(state.chunkSeconds, AppState.defaultChunkSettings.chunkSeconds);
    expect(
      state.energyThreshold,
      AppState.defaultChunkSettings.energyThreshold,
    );
    expect(state.speechPadMs, AppState.defaultChunkSettings.speechPadMs);
  });

  test('resetChunkSettings restores and persists the defaults', () {
    final db = AppDatabase.open();
    addTearDown(db.close);
    final state = AppState(database: db)
      ..chunkStrategy = ChunkStrategy.energy
      ..chunkSeconds = 10;

    state.resetChunkSettings();

    expect(state.chunkStrategy, ChunkStrategy.fixed);
    expect(state.chunkSeconds, AppState.defaultChunkSettings.chunkSeconds);
    final restored = AppState(database: db);
    expect(restored.chunkStrategy, ChunkStrategy.fixed);
    expect(restored.chunkSeconds, AppState.defaultChunkSettings.chunkSeconds);
  });

  test('a selected bundle restores engine, family, quant and companions', () {
    final db = AppDatabase.open();
    addTearDown(db.close);

    const entry = ModelEntry(
      id: 'w',
      displayName: 'Whisper',
      fileName: 'unused',
      family: 'whisper',
      quant: 'int8',
      engine: 'sherpa',
      files: [
        ModelFile(fileName: 'enc.onnx', role: 'encoder', sizeBytes: 2),
        ModelFile(fileName: 'dec.onnx', role: 'decoder', sizeBytes: 2),
        ModelFile(fileName: 'tok.txt', role: 'tokens', sizeBytes: 2),
      ],
    );
    final store = LocalModelStore(dir);
    for (final file in entry.bundleFiles) {
      File(store.pathToFile(entry, file))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([0, 0]);
    }

    final state = AppState(database: db)
      ..selectModel(
        spec: store.specFor(entry),
        engineId: 'sherpa',
        family: entry.family,
        quant: entry.quant,
      );
    expect(
      state.modelSpec!.decoderPath,
      store.pathToFile(entry, entry.files[1]),
    );
    expect(state.selectionNeedsMissingCompanion, isFalse);

    final restored = AppState(database: db);
    expect(restored.engineId, 'sherpa');
    expect(restored.modelFamily, 'whisper');
    expect(restored.modelQuant, 'int8');
    expect(restored.modelSpec, isNotNull);
    expect(restored.modelSpec!.tokensPath, isNotNull);
    expect(restored.modelSpec!.encoderPath, isNotNull);
    expect(restored.modelSpec!.decoderPath, isNotNull);
  });

  test('a hand-picked file maps to its format engine and restores', () {
    final db = AppDatabase.open();
    addTearDown(db.close);

    final path = write('voice.gguf', [1, 2, 3]);
    final state = AppState(database: db)
      ..modelFamily = 'sensevoice'
      ..modelPath = path;

    // A GGUF goes to CrispASR, not silently to the sherpa adapter.
    expect(state.engineId, 'crispasr');
    expect(state.modelPath, path);
    expect(state.modelSelectionIsManual, isTrue);
    // Family/quant come from the Settings controls, not a bundle.
    expect(state.modelSpec!.family, 'sensevoice');
    expect(state.modelSpec!.quant, 'q8_0');

    final restored = AppState(database: db);
    expect(restored.engineId, 'crispasr');
    expect(restored.modelPath, path);
    expect(restored.modelSelectionIsManual, isTrue);
    expect(restored.modelSpec!.quant, 'q8_0');
  });

  test('a vanished selection is cleared and flagged on restart', () {
    final db = AppDatabase.open();
    addTearDown(db.close);

    final path = write('gone.onnx', [1]);
    AppState(database: db).modelPath = path;
    File(path).deleteSync();

    final restored = AppState(database: db);
    expect(restored.modelPath, isNull);
    expect(restored.modelSpec, isNull);
    expect(restored.modelSelectionMissing, isTrue);
  });

  test('whisper is blocked only when the selection has no decoder', () {
    final db = AppDatabase.open();
    addTearDown(db.close);
    final state = AppState(database: db)..modelFamily = 'whisper';

    // Hand-picked encoder alone: genuinely unsupported.
    state.modelPath = write('whisper-encoder.onnx', [1]);
    expect(state.selectionNeedsMissingCompanion, isTrue);

    // A bundle spec that carries its decoder is not blocked.
    state.selectModel(
      spec: const EngineModelSpec(
        path: 'enc.onnx',
        family: 'whisper',
        decoderPath: 'dec.onnx',
      ),
      engineId: 'sherpa',
    );
    expect(state.selectionNeedsMissingCompanion, isFalse);
  });

  test('clearing the selection notifies and persists the empty choice', () {
    final db = AppDatabase.open();
    addTearDown(db.close);
    final state = AppState(database: db)..modelPath = write('m.onnx', [1]);

    var notified = 0;
    state.addListener(() => notified++);
    state.clearModelSelection();

    expect(notified, 1);
    expect(state.modelPath, isNull);
    expect(AppState(database: db).modelPath, isNull);
  });

  test('selectModel is refused while a run owns the engine', () {
    final db = AppDatabase.open();
    addTearDown(db.close);
    final state = AppState(database: db)..engineBusy = true;

    state.selectModel(
      spec: const EngineModelSpec(path: 'enc.onnx', family: 'whisper'),
      engineId: 'sherpa',
    );

    expect(state.modelSpec, isNull);
  });
}
