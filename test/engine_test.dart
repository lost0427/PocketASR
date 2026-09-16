import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/engine/asr_engine.dart';
import 'package:pocket_asr/engine/metrics.dart';

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

  group('TokenRateTracker', () {
    test('returns null until a window can be measured', () {
      final tracker = TokenRateTracker(window: const Duration(seconds: 2));
      expect(tracker.tokensPerSecond, isNull);

      tracker.add(0, Duration.zero);
      expect(tracker.tokensPerSecond, isNull); // one sample is not a rate

      tracker.add(10, const Duration(seconds: 1));
      expect(tracker.tokensPerSecond, 10); // 10 tokens over 1 s
    });

    test('uses the rolling window, not the whole run', () {
      final tracker = TokenRateTracker(window: const Duration(seconds: 2));
      tracker.add(0, Duration.zero);
      tracker.add(100, const Duration(seconds: 1)); // fast burst
      tracker.add(120, const Duration(seconds: 4)); // then stall

      // Spans 1 s -> 4 s: 20 tokens over 3 s.
      expect(tracker.tokensPerSecond, closeTo(20 / 3, 1e-9));
    });

    test('ignores "cannot count" and repeated counts', () {
      final tracker = TokenRateTracker();
      tracker.add(-1, Duration.zero); // unsupported marker
      expect(tracker.tokens, isNull);

      tracker.add(50, Duration.zero);
      tracker.add(50, const Duration(seconds: 2));
      expect(tracker.tokensPerSecond, 0); // no new tokens, no invented rate
    });

    test('restarts when the cumulative counter drops', () {
      final tracker = TokenRateTracker();
      tracker.add(100, const Duration(seconds: 1));
      tracker.add(5, const Duration(seconds: 2)); // new session

      expect(tracker.tokens, 5);
      expect(tracker.tokensPerSecond, isNull);
    });
  });

  group('TranscriptionMetrics', () {
    test('averages true tokens over elapsed', () {
      const metrics = TranscriptionMetrics(
        tokens: 40,
        elapsed: Duration(seconds: 2),
      );
      expect(metrics.avgTokensPerSec, 20);
      expect(metrics.rtf, isNull);
    });

    test('reports null when tokens or time are unknown', () {
      expect(
        const TranscriptionMetrics(elapsed: Duration(seconds: 1))
            .avgTokensPerSec,
        isNull,
      );
      expect(
        const TranscriptionMetrics(tokens: 10, elapsed: Duration.zero)
            .avgTokensPerSec,
        isNull,
      );
    });

    test('copies the engine result and derives rtf', () {
      const result = TranscriptionResult(
        text: '你好',
        elapsed: Duration(seconds: 2),
        tokens: 4,
        audioDuration: Duration(seconds: 4),
      );
      final metrics = TranscriptionMetrics.fromResult(result);
      expect(metrics.avgTokensPerSec, 2);
      expect(metrics.rtf, 0.5);
      expect(result.rtf, 0.5);
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
