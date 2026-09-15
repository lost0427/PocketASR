import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/app/app_state.dart';
import 'package:pocket_asr/engine/asr_engine.dart';
import 'package:pocket_asr/engine/crisp_embedder.dart';
import 'package:pocket_asr/engine/crispasr_engine.dart';
import 'package:pocket_asr/engine/embedder.dart';
import 'package:pocket_asr/engine/engine_registry.dart';
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
      expect(registry.createAsr('crispasr'), isA<CrispAsrEngine>());
      expect(registry.createAsr('sherpa'), isA<SherpaEngine>());
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
  });

  group('AppState engine selection', () {
    test('prefers a real sherpa engine by default', () {
      final state = AppState();
      addTearDown(state.dispose);

      expect(state.engineId, 'sherpa');
      expect(state.engine, isA<SherpaEngine>());
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
        engine.planVad(request),
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
      } else {
        expect(caps.unavailableReason, isNotEmpty);
        expect(caps.backends, isEmpty);
      }

      await engine.dispose();
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
