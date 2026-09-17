import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/engine/asr_engine.dart';

void main() {
  group('UnavailableAsrEngine', () {
    test('reports unavailable with no backends', () async {
      const engine = UnavailableAsrEngine();
      expect(await engine.availableBackends(), isEmpty);

      final caps = await engine.capabilities();
      expect(caps.available, isFalse);
      expect(caps.backends, isEmpty);
      expect(caps.unavailableReason, isNotEmpty);
    });

    test('errors clearly instead of fabricating text', () async {
      const engine = UnavailableAsrEngine();
      const request = TranscribeRequest(audioPath: 'sample.wav');

      await expectLater(
        engine.transcribe(request),
        emitsError(isA<EngineUnavailableException>()),
      );
      await expectLater(
        engine.load(const EngineModelSpec(path: 'model.gguf'), Backend.cpu),
        throwsA(isA<EngineUnavailableException>()),
      );
      await expectLater(
        engine.planVad(
          request,
          const NeuralVadSettings(modelPath: 'vad.onnx'),
        ),
        throwsA(isA<EngineUnavailableException>()),
      );
    });
  });

  test('VadPlan sums speech segments', () {
    const plan = VadPlan([
      VadSegment(start: Duration.zero, end: Duration(seconds: 2)),
      VadSegment(start: Duration(seconds: 5), end: Duration(seconds: 6)),
    ]);
    expect(plan.isEmpty, isFalse);
    expect(plan.speechDuration, const Duration(seconds: 3));
    expect(const VadPlan.empty().isEmpty, isTrue);
  });

  group('NeuralVadSettings', () {
    test('defaults match the pinned Silero planning knobs', () {
      const settings = NeuralVadSettings(modelPath: 'silero.onnx');
      expect(settings.family, VadModelFamily.silero);
      expect(settings.threshold, 0.5);
      expect(settings.minSilenceDuration, 0.5);
      expect(settings.minSpeechDuration, 0.25);
      expect(settings.speechPadMs, 30);
      expect(settings.maxSpeechSeconds, 30);
      expect(settings.validate, returnsNormally);
    });

    test('rejects values that could not drive a real detector', () {
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
        NeuralVadSettings(modelPath: 'v', maxSpeechSeconds: double.infinity),
      ];
      for (final settings in bad) {
        expect(
          settings.validate,
          throwsA(isA<ArgumentError>()),
          reason: '$settings',
        );
      }
    });
  });
}
