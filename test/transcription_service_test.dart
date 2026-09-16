import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/audio_buffer.dart';
import 'package:pocket_asr/core/audio/audio_preprocessor.dart';
import 'package:pocket_asr/core/audio/audio_source.dart';
import 'package:pocket_asr/engine/asr_engine.dart';
import 'package:pocket_asr/features/transcribe/transcription_service.dart';

/// One second of silence at 16 kHz; the fake engine ignores the temp WAV.
class _FakeSource implements AudioSource {
  const _FakeSource();

  @override
  Future<AudioBuffer> read(String path) async => AudioBuffer(
    samples: Float32List(16000),
    sampleRate: 16000,
  );
}

class _FakeEngine implements AsrEngine {
  _FakeEngine(this.progress);

  final List<TranscribeProgress> progress;

  @override
  String get id => 'fake';

  @override
  Future<List<Backend>> availableBackends() async => const [Backend.cpu];

  @override
  Future<EngineCapabilities> capabilities() async =>
      const EngineCapabilities(available: true, backends: {Backend.cpu});

  @override
  Future<void> load(EngineModelSpec spec, Backend backend) async {}

  @override
  Stream<TranscribeProgress> transcribe(TranscribeRequest request) =>
      Stream<TranscribeProgress>.fromIterable(progress);

  @override
  Future<VadPlan> planVad(TranscribeRequest request) async =>
      const VadPlan.empty();

  @override
  Future<void> dispose() async {}
}

TranscriptionService _service(_FakeEngine engine) => TranscriptionService(
  engine: engine,
  source: const _FakeSource(),
  preprocessor: const AudioPreprocessor(enabled: false),
);

void main() {
  test('forwards every engine progress update to the optional callback', () async {
    final engine = _FakeEngine(const [
      TranscribeProgress(
        elapsed: Duration(milliseconds: 100),
        ratio: 0.5,
        partialText: 'he',
        tokens: 1,
      ),
      TranscribeProgress(
        elapsed: Duration(milliseconds: 200),
        ratio: 1,
        partialText: 'hello',
        tokens: 3,
      ),
    ]);
    final seen = <TranscribeProgress>[];

    final result = await _service(engine).transcribe(
      audioPath: 'ignored.wav',
      model: const EngineModelSpec(path: 'model.gguf'),
      onProgress: seen.add,
    );

    expect(seen.map((p) => p.ratio), [0.5, 1.0]);
    expect(seen.map((p) => p.partialText), ['he', 'hello']);
    expect(seen.map((p) => p.tokens), [1, 3]);

    // Forwarding must not change the returned result.
    expect(result.text, 'hello');
    expect(result.tokens, 3);
    expect(result.engine, 'fake');
    expect(result.audioDuration, const Duration(seconds: 1));
  });

  test('runs without a callback (backwards compatible)', () async {
    final engine = _FakeEngine(const [
      TranscribeProgress(
        elapsed: Duration(seconds: 1),
        ratio: 1,
        partialText: 'done',
      ),
    ]);

    final result = await _service(engine).transcribe(
      audioPath: 'ignored.wav',
      model: const EngineModelSpec(path: 'model.gguf'),
    );

    expect(result.text, 'done');
    expect(result.tokens, isNull);
  });

  test('an engine that emits no text still errors instead of faking', () async {
    final engine = _FakeEngine(const [
      TranscribeProgress(elapsed: Duration(seconds: 1), ratio: 1),
    ]);

    await expectLater(
      _service(engine).transcribe(
        audioPath: 'ignored.wav',
        model: const EngineModelSpec(path: 'model.gguf'),
      ),
      throwsA(isA<EngineUnavailableException>()),
    );
  });
}
