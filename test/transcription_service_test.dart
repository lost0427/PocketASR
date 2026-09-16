import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/audio_buffer.dart';
import 'package:pocket_asr/core/audio/audio_preprocessor.dart';
import 'package:pocket_asr/core/audio/audio_source.dart';
import 'package:pocket_asr/core/audio/chunk_planner.dart';
import 'package:pocket_asr/core/audio/wav.dart';
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

class _BufferSource implements AudioSource {
  const _BufferSource(this.audio);

  final AudioBuffer audio;

  @override
  Future<AudioBuffer> read(String path) async => audio;
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

/// Engine that decodes every request WAV back from disk, so tests verify the
/// actual PCM bytes the service wrote per chunk, plus load/cleanup behavior.
class _ChunkedEngine implements AsrEngine {
  _ChunkedEngine(this.responses, {this.failOnCall});

  /// One progress script per expected engine call.
  final List<List<TranscribeProgress>> responses;
  final int? failOnCall;

  int loadCount = 0;
  final requests = <String>[];
  final chunkSamples = <Float32List>[];

  @override
  String get id => 'chunked';

  @override
  Future<List<Backend>> availableBackends() async => const [Backend.cpu];

  @override
  Future<EngineCapabilities> capabilities() async =>
      const EngineCapabilities(available: true, backends: {Backend.cpu});

  @override
  Future<void> load(EngineModelSpec spec, Backend backend) async {
    loadCount++;
  }

  @override
  Stream<TranscribeProgress> transcribe(TranscribeRequest request) {
    requests.add(request.audioPath);
    chunkSamples.add(
      WavDecoder().decode(File(request.audioPath).readAsBytesSync()).samples,
    );
    if (failOnCall == requests.length) {
      return Stream<TranscribeProgress>.error(
        EngineUnavailableException('boom on call ${requests.length}'),
      );
    }
    return Stream<TranscribeProgress>.fromIterable(
      responses[requests.length - 1],
    );
  }

  @override
  Future<VadPlan> planVad(TranscribeRequest request) async =>
      const VadPlan.empty();

  @override
  Future<void> dispose() async {}
}

TranscriptionService _service(AsrEngine engine, [AudioBuffer? audio]) =>
    TranscriptionService(
      engine: engine,
      source: audio == null ? const _FakeSource() : _BufferSource(audio),
      preprocessor: const AudioPreprocessor(enabled: false),
    );

AudioBuffer _stereoLevels() {
  // 2 s at 16 kHz: first half constant 0.25, second half constant 0.5 —
  // exact under PCM16 round-trip, so decoded chunk values can be compared.
  final samples = Float32List(32000);
  samples.setRange(0, 16000, List<double>.filled(16000, 0.25));
  samples.setRange(16000, 32000, List<double>.filled(16000, 0.5));
  return AudioBuffer(samples: samples, sampleRate: 16000);
}

const _oneSecondFixed = ChunkSettings(chunkSeconds: 1, maxSpeechSeconds: 1);

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

  test('without chunkSettings the whole file is sent exactly once', () async {
    final engine = _ChunkedEngine([
      const [
        TranscribeProgress(
          elapsed: Duration(milliseconds: 50),
          ratio: 1,
          partialText: 'all',
        ),
      ],
    ]);

    final result = await _service(engine, _stereoLevels()).transcribe(
      audioPath: 'ignored.wav',
      model: const EngineModelSpec(path: 'model.gguf'),
    );

    expect(engine.loadCount, 1);
    expect(engine.requests, hasLength(1));
    expect(engine.chunkSamples.single, hasLength(32000));
    expect(result.text, 'all');
    expect(result.elapsed, const Duration(milliseconds: 50));
  });

  test('chunkSettings sends real per-chunk PCM and aggregates everything', () async {
    final engine = _ChunkedEngine([
      const [
        TranscribeProgress(
          elapsed: Duration(milliseconds: 100),
          ratio: 0.5,
          partialText: 'a?',
          tokens: 2,
        ),
        TranscribeProgress(
          elapsed: Duration(milliseconds: 100),
          ratio: 1,
          partialText: 'a',
          tokens: 2,
        ),
      ],
      const [
        TranscribeProgress(
          elapsed: Duration(milliseconds: 200),
          ratio: 1,
          partialText: 'b',
          tokens: 3,
        ),
      ],
    ]);
    final seen = <TranscribeProgress>[];

    final result = await _service(engine, _stereoLevels()).transcribe(
      audioPath: 'ignored.wav',
      model: const EngineModelSpec(path: 'model.gguf'),
      chunkSettings: _oneSecondFixed,
      onProgress: seen.add,
    );

    // Loaded once; each 16 kHz second went as its own request with exactly
    // its own samples (verified by decoding the written WAVs back).
    expect(engine.loadCount, 1);
    expect(engine.requests, hasLength(2));
    expect(engine.chunkSamples[0], hasLength(16000));
    expect(engine.chunkSamples[0].first, 0.25);
    expect(engine.chunkSamples[1], hasLength(16000));
    expect(engine.chunkSamples[1].first, 0.5);

    // Aggregated full text, cumulative engine-reported elapsed and tokens.
    expect(result.text, 'a b');
    expect(result.elapsed, const Duration(milliseconds: 300));
    expect(result.tokens, 5);
    expect(result.audioDuration, const Duration(seconds: 2));

    // Global progress over the planned audio, with cumulative text/tokens.
    expect(seen.map((p) => p.ratio), [0.25, 0.5, 1.0]);
    expect(seen.map((p) => p.partialText), ['a?', 'a', 'a b']);
    expect(seen.map((p) => p.tokens), [2, 2, 5]);
    expect(
      seen.map((p) => p.elapsed.inMilliseconds).toList(),
      [100, 100, 300],
    );

    // The whole temp directory (not just the chunk files) is gone.
    expect(File(engine.requests.first).parent.existsSync(), isFalse);
  });

  test('unknown token counts stay null instead of being estimated', () async {
    final engine = _ChunkedEngine([
      const [
        TranscribeProgress(
          elapsed: Duration(milliseconds: 100),
          ratio: 1,
          partialText: 'a',
        ),
      ],
      const [
        TranscribeProgress(
          elapsed: Duration(milliseconds: 100),
          ratio: 1,
          partialText: 'b',
          tokens: 7,
        ),
      ],
    ]);
    final seen = <TranscribeProgress>[];

    final result = await _service(engine, _stereoLevels()).transcribe(
      audioPath: 'ignored.wav',
      model: const EngineModelSpec(path: 'model.gguf'),
      chunkSettings: _oneSecondFixed,
      onProgress: seen.add,
    );

    expect(result.tokens, isNull);
    expect(result.avgTokensPerSec, isNull);
    // Chunk 2 knew its tokens, but chunk 1 did not: the cumulative count is
    // unknowable, so forwarded tokens must not pretend otherwise.
    expect(seen.map((p) => p.tokens), [null, null]);
  });

  test('mid-run engine failure throws and cleans the temp directory', () async {
    final engine = _ChunkedEngine(
      [
        const [
          TranscribeProgress(
            elapsed: Duration(milliseconds: 100),
            ratio: 1,
            partialText: 'a',
            tokens: 2,
          ),
        ],
        const [],
      ],
      failOnCall: 2,
    );

    await expectLater(
      _service(engine, _stereoLevels()).transcribe(
        audioPath: 'ignored.wav',
        model: const EngineModelSpec(path: 'model.gguf'),
        chunkSettings: _oneSecondFixed,
      ),
      throwsA(
        isA<EngineUnavailableException>().having(
          (e) => e.message,
          'message',
          contains('boom on call 2'),
        ),
      ),
    );

    expect(engine.loadCount, 1);
    expect(File(engine.requests.first).parent.existsSync(), isFalse);
  });

  test('energy plan with no speech throws without touching the engine', () async {
    final engine = _ChunkedEngine(const []);
    final silence = AudioBuffer(
      samples: Float32List(16000 * 3),
      sampleRate: 16000,
    );

    await expectLater(
      _service(engine, silence).transcribe(
        audioPath: 'ignored.wav',
        model: const EngineModelSpec(path: 'model.gguf'),
        chunkSettings: const ChunkSettings(mode: ChunkMode.energy),
      ),
      throwsA(isA<EngineUnavailableException>()),
    );

    expect(engine.loadCount, 0);
    expect(engine.requests, isEmpty);
  });

  test('invalid chunk settings fail before any engine work or temp files', () async {
    final engine = _ChunkedEngine(const []);

    await expectLater(
      _service(engine, _stereoLevels()).transcribe(
        audioPath: 'ignored.wav',
        model: const EngineModelSpec(path: 'model.gguf'),
        chunkSettings: const ChunkSettings(
          chunkSeconds: 1,
          maxSpeechSeconds: 1,
          overlapSeconds: 1,
        ),
      ),
      throwsA(isA<ArgumentError>()),
    );

    expect(engine.loadCount, 0);
    expect(engine.requests, isEmpty);
  });
}
