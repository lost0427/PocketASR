import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/app/app_state.dart';
import 'package:pocket_asr/engine/asr_engine.dart';
import 'package:pocket_asr/engine/crisp_embedder.dart';
import 'package:pocket_asr/engine/crispasr_engine.dart';
import 'package:pocket_asr/engine/embedder.dart';
import 'package:pocket_asr/engine/engine_registry.dart';
import 'package:pocket_asr/engine/native_worker.dart';
import 'package:pocket_asr/engine/sherpa_engine.dart';

/// Adapter wiring tests. These must not require a real model or native library:
/// they assert the registry constructs the right implementations and that the
/// adapters fail loudly (never fabricate results) when the native side is
/// missing.
void main() {
  group('EngineRegistry', () {
    test('lists and builds the built-in ASR engines by id', () {
      final registry = EngineRegistry();

      expect(
        registry.asrEngineIds,
        containsAll(['unavailable', 'crispasr', 'sherpa']),
      );
      expect(registry.createAsr('unavailable'), isA<UnavailableAsrEngine>());
      // Native engines are worker facades: the real adapter (and its native
      // session) is built inside a private isolate, never in the root one.
      expect(
        registry.createAsr('crispasr'),
        isA<WorkerAsrEngine>().having((e) => e.id, 'id', 'crispasr'),
      );
      expect(
        registry.createAsr('sherpa'),
        isA<WorkerAsrEngine>().having((e) => e.id, 'id', 'sherpa'),
      );
    });

    test('builds the deterministic embedder and rejects unknown ids', () {
      final registry = EngineRegistry();

      expect(registry.embedderIds, contains('deterministic'));
      expect(registry.createEmbedder('deterministic'), isA<DeterministicEmbedder>());
      expect(() => registry.createAsr('nope'), throwsArgumentError);
      expect(() => registry.createEmbedder('crispembed'), throwsArgumentError);
    });

    test('accepts caller overrides over the built-ins', () {
      final registry = EngineRegistry(
        asrBuilders: {'unavailable': () => const UnavailableAsrEngine(reason: 'override')},
      );

      final engine = registry.createAsr('unavailable');
      expect(engine, isA<UnavailableAsrEngine>());
      expect((engine as UnavailableAsrEngine).reason, 'override');
    });

    test('threads configure the built-in worker engines; overrides still win', () {
      // The count is passed to WorkerAsrEngine's factory, which keeps it inside
      // the worker isolate (not inspectable here); the seam is that the built-in
      // is still a WorkerAsrEngine and a caller override is not bypassed.
      final registry = EngineRegistry();
      expect(registry.createAsr('sherpa', threads: 2), isA<WorkerAsrEngine>());
      expect(registry.createAsr('crispasr', threads: 1), isA<WorkerAsrEngine>());

      final overridden = EngineRegistry(
        asrBuilders: {'sherpa': () => const UnavailableAsrEngine()},
      );
      expect(
        overridden.createAsr('sherpa', threads: 2),
        isA<UnavailableAsrEngine>(),
      );
    });
  });

  group('AppState engine selection', () {
    test('prefers a real sherpa engine by default', () {
      final state = AppState();
      addTearDown(state.dispose);

      expect(state.engineId, 'sherpa');
      expect(state.engine, isA<WorkerAsrEngine>());
    });

    test('rebuilds the engine when the id changes, not per access', () {
      final state = AppState();
      addTearDown(state.dispose);

      final first = state.engine;
      expect(identical(state.engine, first), isTrue);

      state.engineId = 'unavailable';
      final second = state.engine;
      expect(second, isA<UnavailableAsrEngine>());
      expect(identical(second, first), isFalse);
    });

    test('an unknown id throws instead of silently standing in', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.engineId = 'nope';
      expect(() => state.engine, throwsArgumentError);
    });

    test('changing threads rebuilds the worker engine', () {
      final state = AppState();
      addTearDown(state.dispose);

      final first = state.engine;
      state.threads = 1;
      final second = state.engine;
      expect(identical(second, first), isFalse);
      expect(second, isA<WorkerAsrEngine>());
    });

    test('a thread change waits while a run owns the engine', () {
      final state = AppState()..engineBusy = true;
      addTearDown(state.dispose);

      final first = state.engine;
      state.threads = 1;
      // Still the same instance while busy: the native session in use is not
      // disposed out from under the worker.
      expect(identical(state.engine, first), isTrue);

      state.engineBusy = false;
      expect(identical(state.engine, first), isFalse); // rebuilt after the run
    });
  });

  group('CrispAsrEngine without the native library', () {
    test('reports unavailable with a reason and no backends', () async {
      final engine = CrispAsrEngine();

      final caps = await engine.capabilities();
      expect(caps.available, isFalse);
      expect(caps.backends, isEmpty);
      expect(caps.supportsVad, isFalse);
      expect(caps.unavailableReason, isNotEmpty);
      expect(await engine.availableBackends(), isEmpty);
    });

    test('errors instead of fabricating text', () async {
      final engine = CrispAsrEngine();
      const request = TranscribeRequest(audioPath: 'sample.wav');

      await expectLater(
        engine.load(const EngineModelSpec(path: 'missing.gguf'), Backend.cpu),
        throwsA(isA<EngineUnavailableException>()),
      );
      await expectLater(
        engine.transcribe(request),
        emitsError(isA<EngineUnavailableException>()),
      );
      await expectLater(
        engine.planVad(
          request,
          const NeuralVadSettings(modelPath: 'missing-vad.onnx'),
        ),
        throwsA(isA<EngineUnavailableException>()),
      );
    });
  });

  group('SherpaEngine', () {
    test('reports capabilities or a clear reason, never throws', () async {
      final engine = SherpaEngine();

      final caps = await engine.capabilities();
      if (caps.available) {
        expect(caps.unavailableReason, isNull);
        expect(caps.backends, isNotEmpty);
        expect(caps.supportsTokenCount, isTrue);
        // Real Silero VoiceActivityDetector in the loaded bindings.
        expect(caps.supportsVad, isTrue);
      } else {
        expect(caps.unavailableReason, isNotEmpty);
        expect(caps.backends, isEmpty);
        // No library, no VAD — never report support that cannot run.
        expect(caps.supportsVad, isFalse);
      }

      await engine.dispose();
    });

    test('planVad fails loudly when the Silero model cannot be opened', () async {
      final engine = SherpaEngine();
      addTearDown(engine.dispose);

      // No model is loaded and none is needed; the missing VAD ONNX (or the
      // missing native library) must surface as an error, not silence.
      await expectLater(
        engine.planVad(
          const TranscribeRequest(audioPath: 'missing-input.wav'),
          const NeuralVadSettings(modelPath: 'definitely-missing-silero.onnx'),
        ),
        throwsA(isA<EngineUnavailableException>()),
      );
    });

    test('planVad rejects invalid settings before touching native code', () async {
      final engine = SherpaEngine();
      addTearDown(engine.dispose);

      // validate() runs before any native call — but after the library probe,
      // so on a library-less host this is still an availability error.
      await expectLater(
        engine.planVad(
          const TranscribeRequest(audioPath: 'x.wav'),
          const NeuralVadSettings(modelPath: 'v.onnx', threshold: 2),
        ),
        throwsA(
          anyOf(
            isA<ArgumentError>(),
            isA<EngineUnavailableException>(),
          ),
        ),
      );
    });

    test('fails load loudly when the model files are absent', () async {
      final engine = SherpaEngine();

      await expectLater(
        engine.load(
          const EngineModelSpec(path: 'missing.onnx', family: 'sensevoice'),
          Backend.cpu,
        ),
        throwsA(isA<EngineUnavailableException>()),
      );
    });

    test('transcribe before load errors instead of returning empty text', () async {
      final engine = SherpaEngine();

      await expectLater(
        engine.transcribe(const TranscribeRequest(audioPath: 'sample.wav')),
        emitsError(isA<EngineUnavailableException>()),
      );
    });
  });

  group('CrispEmbedder without the native library', () {
    test('throws instead of falling back to DeterministicEmbedder', () {
      expect(
        () => CrispEmbedder(modelPath: 'missing.gguf'),
        throwsA(isA<EmbedderUnavailableException>()),
      );
    });
  });
}
