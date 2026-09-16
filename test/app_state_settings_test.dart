import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/app/app_state.dart';
import 'package:pocket_asr/core/audio/chunk_planner.dart';
import 'package:pocket_asr/data/db.dart';

/// Chunking and the shared model path must survive a restart, and anything
/// unparseable or out of range must fall back to the defaults rather than
/// reaching [ChunkPlanner.validate] as a broken value.
void main() {
  test('chunk settings and the model path persist and restore', () {
    final db = AppDatabase.open();
    addTearDown(db.close);

    AppState(database: db)
      ..chunkMode = ChunkMode.energy
      ..chunkSeconds = 12
      ..energyThreshold = 0.02
      ..speechPadMs = 40
      ..modelPath = '/models/sensevoice.onnx';

    final restored = AppState(database: db);
    expect(restored.chunkMode, ChunkMode.energy);
    expect(restored.chunkSeconds, 12);
    expect(restored.energyThreshold, 0.02);
    expect(restored.speechPadMs, 40);
    expect(restored.modelPath, '/models/sensevoice.onnx');
    // Overlap is never exposed and stays off by default.
    expect(restored.chunkSettings.overlapSeconds, 0);
  });

  test('invalid stored values fall back to the defaults', () {
    final db = AppDatabase.open();
    addTearDown(db.close);
    db.setSetting('chunk_mode', 'nonsense');
    db.setSetting('chunk_seconds', '-3');
    db.setSetting('chunk_threshold', 'not-a-number');
    db.setSetting('chunk_pad_ms', '99999');

    final state = AppState(database: db);
    expect(state.chunkMode, ChunkMode.fixed);
    expect(state.chunkSeconds, AppState.defaultChunkSettings.chunkSeconds);
    expect(state.energyThreshold, AppState.defaultChunkSettings.energyThreshold);
    expect(state.speechPadMs, AppState.defaultChunkSettings.speechPadMs);
  });

  test('resetChunkSettings restores and persists the defaults', () {
    final db = AppDatabase.open();
    addTearDown(db.close);
    final state = AppState(database: db)
      ..chunkMode = ChunkMode.energy
      ..chunkSeconds = 10;

    state.resetChunkSettings();

    expect(state.chunkMode, ChunkMode.fixed);
    expect(state.chunkSeconds, AppState.defaultChunkSettings.chunkSeconds);
    final restored = AppState(database: db);
    expect(restored.chunkMode, ChunkMode.fixed);
    expect(restored.chunkSeconds, AppState.defaultChunkSettings.chunkSeconds);
  });

  test('sherpa whisper is flagged as needing a companion file it cannot get', () {
    final state = AppState();
    addTearDown(state.dispose);
    expect(state.engineId, 'sherpa');

    state.modelFamily = 'whisper';
    expect(state.selectionNeedsMissingCompanion, isTrue);

    state.modelFamily = 'sensevoice';
    expect(state.selectionNeedsMissingCompanion, isFalse);
  });
}
