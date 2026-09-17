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
  Future<VadPlan> planVad(
    TranscribeRequest request,
    NeuralVadSettings vad,
  ) async => const VadPlan.empty();

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
  Future<VadPlan> planVad(
    TranscribeRequest request,
    NeuralVadSettings vad,
  ) async => const VadPlan.empty();

  @override
  Future<void> dispose() async {}
}

/// Fake neural VAD worker: replays a canned plan and records everything the
/// service sent while the temp input file still existed.
class _VadEngine implements AsrEngine {
  _VadEngine(this.plan);

  final VadPlan plan;
  final requests = <TranscribeRequest>[];
  NeuralVadSettings? lastSettings;
  Uint8List? inputBytes;
  void Function()? onPlan;
  Object? failWith;

  @override
  String get id => 'vadfake';

  @override
  Future<List<Backend>> availableBackends() async => const [Backend.cpu];

  @override
  Future<EngineCapabilities> capabilities() async => const EngineCapabilities(
    available: true,
    backends: {Backend.cpu},
    supportsVad: true,
  );

  @override
  Future<void> load(EngineModelSpec spec, Backend backend) async =>
      throw StateError('a VAD worker must never load an ASR model');

  @override
  Stream<TranscribeProgress> transcribe(TranscribeRequest request) =>
      Stream.error(StateError('a VAD worker must never transcribe'));

  @override
  Future<VadPlan> planVad(
    TranscribeRequest request,
    NeuralVadSettings vad,
  ) async {
    requests.add(request);
    lastSettings = vad;
    inputBytes = File(request.audioPath).readAsBytesSync();
    onPlan?.call();
    final failure = failWith;
    if (failure != null) throw failure;
    return plan;
  }

  @override
  Future<void> dispose() async {}
}

const _defaultVad = NeuralVadSettings(modelPath: 'silero.onnx');

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
  test('default windows bound ASR input and remove previous chunks', () async {
    final engine = _ChunkedEngine(List.generate(3, (_) => const [
      TranscribeProgress(elapsed: Duration(milliseconds: 1), ratio: 1, partialText: 'speech'),
    ]));
    final audio = AudioBuffer(samples: Float32List(16000 * 65), sampleRate: 16000);
    final result = await _service(engine, audio).transcribe(
      audioPath: 'ignored.wav', model: const EngineModelSpec(path: 'model.gguf'));
    expect(engine.chunkSamples.map((s) => s.length), [480000, 480000, 80000]);
    expect(result.audioDuration, const Duration(seconds: 65));
    for (final request in engine.requests) {
      expect(File(request).existsSync(), isFalse);
    }
  });
  test('forwards every engine progress update to the optional callback', () async {
    final engine = _FakeEngine(const [
      TranscribeProgress(
        elapsed: Duration(milliseconds: 100),
        ratio: 0.5,
        partialText: 'he',
      ),
      TranscribeProgress(
        elapsed: Duration(milliseconds: 200),
        ratio: 1,
        partialText: 'hello',
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
    expect(seen.map((p) => p.completedChunkText), [null, 'hello']);

    // Forwarding must not change the returned result.
    expect(result.text, 'hello');
    expect(result.engine, 'fake');
    expect(result.audioDuration, const Duration(seconds: 1));
  });

  test('reports each processing stage in execution order', () async {
    final engine = _FakeEngine(const [
      TranscribeProgress(
        elapsed: Duration(milliseconds: 100),
        ratio: 1,
        partialText: 'done',
      ),
    ]);
    final stages = <TranscriptionStage>[];

    await _service(engine).transcribe(
      audioPath: 'ignored.wav',
      model: const EngineModelSpec(path: 'model.gguf'),
      onStage: stages.add,
    );

    expect(stages, const [
      TranscriptionStage.decoding,
      TranscriptionStage.analyzing,
      TranscriptionStage.segmenting,
      TranscriptionStage.loadingModel,
      TranscriptionStage.transcribing,
      TranscriptionStage.finalizing,
    ]);
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
  });

  test('a job where every chunk is empty still errors', () async {
    final engine = _FakeEngine(const [
      TranscribeProgress(elapsed: Duration(seconds: 1), ratio: 1),
    ]);

    await expectLater(
      _service(engine).transcribe(
        audioPath: 'ignored.wav',
        model: const EngineModelSpec(path: 'model.gguf'),
      ),
      throwsA(
        isA<EngineUnavailableException>().having(
          (e) => e.message,
          'message',
          contains('any audio chunk'),
        ),
      ),
    );
  });

  test('an engine that emits no result still errors immediately', () async {
    final engine = _FakeEngine(const []);

    await expectLater(
      _service(engine).transcribe(
        audioPath: 'ignored.wav',
        model: const EngineModelSpec(path: 'model.gguf'),
      ),
      throwsA(
        isA<EngineUnavailableException>().having(
          (e) => e.message,
          'message',
          contains('no result for chunk 1 of 1'),
        ),
      ),
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
        ),
        TranscribeProgress(
          elapsed: Duration(milliseconds: 100),
          ratio: 1,
          partialText: 'a',
        ),
      ],
      const [
        TranscribeProgress(
          elapsed: Duration(milliseconds: 200),
          ratio: 1,
          partialText: 'b',
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

    // Aggregated full text and cumulative engine-reported elapsed.
    expect(result.text, 'a b');
    expect(result.elapsed, const Duration(milliseconds: 300));
    expect(result.audioDuration, const Duration(seconds: 2));

    // Global progress over the planned audio, with the completed chunk marked.
    expect(seen.map((p) => p.ratio), [0.25, 0.5, 1.0]);
    expect(seen.map((p) => p.partialText), ['a?', 'a', 'a b']);
    expect(seen.map((p) => p.completedChunkText), [null, 'a', 'b']);
    expect(
      seen.map((p) => p.completedChunkElapsed?.inMilliseconds),
      [null, 100, 200],
    );
    expect(
      seen.map((p) => p.elapsed.inMilliseconds).toList(),
      [100, 100, 300],
    );

    // The whole temp directory (not just the chunk files) is gone.
    expect(File(engine.requests.first).parent.existsSync(), isFalse);
  });

  test('empty chunks are skipped without losing text or elapsed time', () async {
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
          elapsed: Duration(milliseconds: 200),
          ratio: 1,
        ),
      ],
      const [
        TranscribeProgress(
          elapsed: Duration(milliseconds: 300),
          ratio: 1,
          partialText: 'b',
        ),
      ],
    ]);
    final seen = <TranscribeProgress>[];
    final audio = AudioBuffer(
      samples: Float32List(16000 * 3),
      sampleRate: 16000,
    );

    final result = await _service(engine, audio).transcribe(
      audioPath: 'ignored.wav',
      model: const EngineModelSpec(path: 'model.gguf'),
      chunkSettings: _oneSecondFixed,
      onProgress: seen.add,
    );

    expect(engine.requests, hasLength(3));
    expect(result.text, 'a b');
    expect(result.elapsed, const Duration(milliseconds: 600));
    expect(seen.map((p) => p.completedChunkText), ['a', null, 'b']);
    expect(
      seen.map((p) => p.completedChunkElapsed?.inMilliseconds),
      [100, null, 300],
    );
  });

  test('mid-run engine failure throws and cleans the temp directory', () async {
    final engine = _ChunkedEngine(
      [
        const [
          TranscribeProgress(
            elapsed: Duration(milliseconds: 100),
            ratio: 1,
            partialText: 'a',
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

  test('cancel between chunks errors, skips later chunks, and cleans up', () async {
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
        ),
      ],
    ]);
    var cancel = false;

    // Flag flips during chunk 1's progress; the loop must abort at the
    // chunk-2 boundary and never send it.
    await expectLater(
      _service(engine, _stereoLevels()).transcribe(
        audioPath: 'ignored.wav',
        model: const EngineModelSpec(path: 'model.gguf'),
        chunkSettings: _oneSecondFixed,
        onProgress: (_) => cancel = true,
        isCancelled: () => cancel,
      ),
      throwsA(
        isA<EngineCancelledException>().having(
          (e) => e.message,
          'message',
          contains('chunk 2 of 2'),
        ),
      ),
    );

    // No success result was returned, chunk 2 never reached the engine, and
    // the temp directory is still fully removed.
    expect(engine.requests, hasLength(1));
    expect(File(engine.requests.first).parent.existsSync(), isFalse);
  });

  test('pre-run cancel stops the unchunked job before the engine call', () async {
    final engine = _ChunkedEngine(const []);

    await expectLater(
      _service(engine, _stereoLevels()).transcribe(
        audioPath: 'ignored.wav',
        model: const EngineModelSpec(path: 'model.gguf'),
        isCancelled: () => true,
      ),
      throwsA(isA<EngineCancelledException>()),
    );

    expect(engine.requests, isEmpty);
  });

  test(
    'cancel arriving after the final chunk never returns a success',
    () async {
      final engine = _FakeEngine(const [
        TranscribeProgress(
          elapsed: Duration(milliseconds: 5),
          ratio: 1,
          partialText: 'done',
        ),
      ]);
      var cancel = false;

      // Flag flips during the only chunk's progress; the loop top never sees
      // it again, so the pre-return re-check is all that stands between a
      // cancelled job and a persisted "success".
      await expectLater(
        _service(engine).transcribe(
          audioPath: 'ignored.wav',
          model: const EngineModelSpec(path: 'model.gguf'),
          onProgress: (_) => cancel = true,
          isCancelled: () => cancel,
        ),
        throwsA(isA<EngineCancelledException>()),
      );
    },
  );

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

  group('neural VAD', () {
    /// N seconds at 16 kHz: 0–1 s constant 0.25, 2–3 s constant 0.5 — exact
    /// under PCM16 round-trip, so concatenated chunk samples are checkable.
    AudioBuffer bursts([int seconds = 4]) {
      final samples = Float32List(seconds * 16000);
      samples.setRange(0, 16000, List<double>.filled(16000, 0.25));
      samples.setRange(32000, 48000, List<double>.filled(16000, 0.5));
      return AudioBuffer(samples: samples, sampleRate: 16000);
    }

    const speechPlan = VadPlan([
      VadSegment(start: Duration.zero, end: Duration(seconds: 1)),
      VadSegment(start: Duration(seconds: 2), end: Duration(seconds: 3)),
    ]);

    const nopad = NeuralVadSettings(
      modelPath: 'silero.onnx',
      speechPadMs: 0,
    );

    TranscriptionService neural(
      _ChunkedEngine asr,
      _VadEngine vad,
      AudioBuffer audio,
    ) => TranscriptionService(
      engine: asr,
      vadEngine: vad,
      source: _BufferSource(audio),
      preprocessor: const AudioPreprocessor(enabled: false),
    );

    test(
      'plans on the VAD worker before any ASR load and sends '
      'concatenated speech, never the silence between',
      () async {
        final asr = _ChunkedEngine([
          const [
            TranscribeProgress(
              elapsed: Duration(milliseconds: 100),
              ratio: 1,
              partialText: 'a b',
            ),
          ],
        ]);
        final vad = _VadEngine(speechPlan);
        var asrLoadedDuringPlanning = true;
        vad.onPlan = () => asrLoadedDuringPlanning = asr.loadCount > 0;

        final result = await neural(asr, vad, bursts()).transcribe(
          audioPath: 'ignored.wav',
          model: const EngineModelSpec(path: 'model.gguf'),
          neuralVad: nopad,
        );

        expect(asrLoadedDuringPlanning, isFalse);
        expect(vad.requests, hasLength(1));
        expect(vad.lastSettings, same(nopad));
        // The VAD worker got the full 16 kHz mono normalized audio as a WAV.
        final wave = WavDecoder().decode(vad.inputBytes!);
        expect(wave.sampleRate, 16000);
        expect(wave.samples, hasLength(64000));

        // One request: 1 s + 1 s of speech back-to-back. A first-to-last
        // slice would have been 3 s long with a silent middle.
        expect(asr.requests, hasLength(1));
        expect(asr.chunkSamples.single, hasLength(32000));
        expect(asr.chunkSamples.single.first, 0.25);
        expect(asr.chunkSamples.single[16000], 0.5);
        expect(result.text, 'a b');
        // Timeline coordinates stay the full audio's.
        expect(result.audioDuration, const Duration(seconds: 4));
      },
    );

    test('windows respect the max-speech cap across merges', () async {
      final asr = _ChunkedEngine([
        const [
          TranscribeProgress(
            elapsed: Duration(milliseconds: 10),
            ratio: 1,
            partialText: 'x',
          ),
        ],
        const [
          TranscribeProgress(
            elapsed: Duration(milliseconds: 10),
            ratio: 1,
            partialText: 'y',
          ),
        ],
      ]);
      final vad = _VadEngine(
        const VadPlan([
          VadSegment(start: Duration.zero, end: Duration(seconds: 3)),
          VadSegment(start: Duration(seconds: 10), end: Duration(seconds: 13)),
          VadSegment(start: Duration(seconds: 20), end: Duration(seconds: 23)),
        ]),
      );

      await neural(asr, vad, bursts(25)).transcribe(
        audioPath: 'ignored.wav',
        model: const EngineModelSpec(path: 'model.gguf'),
        neuralVad: const NeuralVadSettings(
          modelPath: 'silero.onnx',
          speechPadMs: 0,
          maxSpeechSeconds: 7,
        ),
      );

      // 3+3=6 fits under 7; adding the third run would reach 9 → new window.
      expect(asr.requests, hasLength(2));
      expect(asr.chunkSamples[0], hasLength(96000)); // 6 s, not the 23 s span
      expect(asr.chunkSamples[1], hasLength(48000)); // 3 s
    });

    test('no speech throws instead of faking a success, ASR untouched', () async {
      final asr = _ChunkedEngine(const []);
      final vad = _VadEngine(const VadPlan.empty());

      await expectLater(
        neural(asr, vad, bursts()).transcribe(
          audioPath: 'ignored.wav',
          model: const EngineModelSpec(path: 'model.gguf'),
          neuralVad: _defaultVad,
        ),
        throwsA(isA<EngineUnavailableException>()),
      );

      expect(vad.requests, hasLength(1));
      expect(asr.loadCount, 0);
      expect(asr.requests, isEmpty);
    });

    test('VAD failure propagates and its temp input is removed', () async {
      final asr = _ChunkedEngine(const []);
      final vad = _VadEngine(speechPlan)
        ..failWith = const EngineUnavailableException('vad boom');

      await expectLater(
        neural(asr, vad, bursts()).transcribe(
          audioPath: 'ignored.wav',
          model: const EngineModelSpec(path: 'model.gguf'),
          neuralVad: _defaultVad,
        ),
        throwsA(
          isA<EngineUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('vad boom'),
          ),
        ),
      );

      expect(asr.loadCount, 0);
      expect(File(vad.requests.single.audioPath).existsSync(), isFalse);
    });

    test('invalid settings or double mode fail before any IO', () async {
      final asr = _ChunkedEngine(const []);
      final vad = _VadEngine(speechPlan);
      final service = neural(asr, vad, bursts());
      const bad = <NeuralVadSettings>[
        NeuralVadSettings(modelPath: ''),
        NeuralVadSettings(modelPath: '   '),
        NeuralVadSettings(modelPath: 'v', threshold: 0),
        NeuralVadSettings(modelPath: 'v', threshold: 1),
        NeuralVadSettings(modelPath: 'v', threshold: double.nan),
        NeuralVadSettings(modelPath: 'v', minSilenceDuration: -0.1),
        NeuralVadSettings(modelPath: 'v', minSpeechDuration: -1),
        NeuralVadSettings(modelPath: 'v', speechPadMs: -1),
        NeuralVadSettings(modelPath: 'v', maxSpeechSeconds: 0),
      ];
      for (final settings in bad) {
        await expectLater(
          service.transcribe(
            audioPath: 'ignored.wav',
            model: const EngineModelSpec(path: 'model.gguf'),
            neuralVad: settings,
          ),
          throwsA(isA<ArgumentError>()),
          reason: settings.modelPath,
        );
        await expectLater(
          service.previewVad(
            audioPath: 'ignored.wav',
            neuralVad: settings,
          ),
          throwsA(isA<ArgumentError>()),
        );
      }
      await expectLater(
        service.transcribe(
          audioPath: 'ignored.wav',
          model: const EngineModelSpec(path: 'model.gguf'),
          chunkSettings: _oneSecondFixed,
          neuralVad: _defaultVad,
        ),
        throwsA(isA<ArgumentError>()),
      );

      expect(vad.requests, isEmpty);
      expect(asr.loadCount, 0);
      expect(asr.requests, isEmpty);
    });

    test('cancel before planning sends nothing anywhere', () async {
      final asr = _ChunkedEngine(const []);
      final vad = _VadEngine(speechPlan);

      await expectLater(
        neural(asr, vad, bursts()).transcribe(
          audioPath: 'ignored.wav',
          model: const EngineModelSpec(path: 'model.gguf'),
          neuralVad: _defaultVad,
          isCancelled: () => true,
        ),
        throwsA(isA<EngineCancelledException>()),
      );

      expect(vad.requests, isEmpty);
      expect(asr.loadCount, 0);
      expect(asr.requests, isEmpty);
    });

    test('cancel flagged during planning aborts before any chunk and '
        'cleans the VAD input', () async {
      final asr = _ChunkedEngine(const []);
      var cancel = false;
      final vad = _VadEngine(speechPlan)..onPlan = () => cancel = true;

      await expectLater(
        neural(asr, vad, bursts()).transcribe(
          audioPath: 'ignored.wav',
          model: const EngineModelSpec(path: 'model.gguf'),
          neuralVad: _defaultVad,
          isCancelled: () => cancel,
        ),
        throwsA(
          isA<EngineCancelledException>().having(
            (e) => e.message,
            'message',
            contains('before loading'),
          ),
        ),
      );

      // Planning happened, transcription did not, temp input is gone.
      expect(asr.loadCount, 0);
      expect(vad.requests, hasLength(1));
      expect(File(vad.requests.single.audioPath).existsSync(), isFalse);
      expect(asr.requests, isEmpty);
    });

    test('window PCM is allocated by exact sample sums, not microsecond math', () async {
      // At 16 kHz these spans are samples 1..4 and 5..8 (6 samples total),
      // but their summed durations 187+187 us convert back to 374*16000~/1e6
      // = 5 slots: the old microsecond-based allocation threw RangeError
      // before the engine ever saw the chunk.
      final asr = _ChunkedEngine([
        const [
          TranscribeProgress(
            elapsed: Duration(milliseconds: 1),
            ratio: 1,
            partialText: 'x',
          ),
        ],
      ]);
      final vad = _VadEngine(
        const VadPlan([
          VadSegment(
            start: Duration(microseconds: 63),
            end: Duration(microseconds: 250),
          ),
          VadSegment(
            start: Duration(microseconds: 313),
            end: Duration(microseconds: 500),
          ),
        ]),
      );
      final audio = AudioBuffer(samples: Float32List(16), sampleRate: 16000);

      await TranscriptionService(
        engine: asr,
        vadEngine: vad,
        source: _BufferSource(audio),
        preprocessor: const AudioPreprocessor(enabled: false),
      ).transcribe(
        audioPath: 'ignored.wav',
        model: const EngineModelSpec(path: 'model.gguf'),
        neuralVad: nopad,
      );

      expect(asr.chunkSamples.single, hasLength(6)); // (4-1) + (8-5)
    });

    test('previewVad cancelled during planning throws and cleans up', () async {
      final asr = _ChunkedEngine(const []);
      var cancel = false;
      final vad = _VadEngine(speechPlan)..onPlan = () => cancel = true;

      await expectLater(
        neural(
          asr,
          vad,
          bursts(),
        ).previewVad(
          audioPath: 'ignored.wav',
          neuralVad: _defaultVad,
          isCancelled: () => cancel,
        ),
        throwsA(isA<EngineCancelledException>()),
      );

      // A cancelled preview returns no windows, and its temp input is gone.
      expect(File(vad.requests.single.audioPath).existsSync(), isFalse);
    });

    test(
      'previewVad returns real padded boundaries without touching the '
      'ASR engine, and cleans up',
      () async {
        final asr = _ChunkedEngine(const []);
        final vad = _VadEngine(speechPlan);

        final preview = await neural(
          asr,
          vad,
          bursts(),
        ).previewVad(
          audioPath: 'ignored.wav',
          neuralVad: const NeuralVadSettings(
            modelPath: 'silero.onnx',
            speechPadMs: 100,
          ),
        );

        expect(asr.loadCount, 0);
        expect(asr.requests, isEmpty);
        expect(vad.requests, hasLength(1));
        final wave = WavDecoder().decode(vad.inputBytes!);
        expect(wave.sampleRate, 16000);
        expect(wave.samples, hasLength(64000));

        // Real boundaries with pad, on the audio timeline — two spans, not
        // one first-to-last slice over the silence.
        expect(preview.windows, hasLength(1));
        expect(
          preview.windows.single
              .map((s) => [s.start.inMilliseconds, s.end.inMilliseconds])
              .toList(),
          [
            [0, 1100], // head pad clamped to 0
            [1900, 3100],
          ],
        );
        expect(preview.speechDuration, const Duration(milliseconds: 2300));
        expect(preview.sampleRate, 16000);
        // The whole temp directory (vad input included) is gone.
        expect(File(vad.requests.single.audioPath).existsSync(), isFalse);
      },
    );

    test('previewVad on silent audio throws instead of empty success', () async {
      final asr = _ChunkedEngine(const []);
      final vad = _VadEngine(const VadPlan.empty());

      await expectLater(
        neural(
          asr,
          vad,
          bursts(),
        ).previewVad(audioPath: 'ignored.wav', neuralVad: _defaultVad),
        throwsA(isA<EngineUnavailableException>()),
      );
      expect(asr.loadCount, 0);
    });
  });
}
