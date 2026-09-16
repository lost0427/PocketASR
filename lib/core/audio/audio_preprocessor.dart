import 'dart:typed_data';
import 'dart:isolate';

import 'audio_buffer.dart';
import 'loudness.dart';

class ProcessedAudio {
  const ProcessedAudio({
    required this.audio,
    required this.enabled,
    required this.originalLufs,
    required this.gainDb,
  });

  final AudioBuffer audio;
  final bool enabled;
  final double originalLufs;
  final double gainDb;
}

class AudioPreprocessor {
  const AudioPreprocessor({this.enabled = true, this.targetLufs = -16});

  final bool enabled;
  final double targetLufs;

  /// Only plain PCM and options cross this boundary, never an engine handle
  /// or MethodChannel. Disabled processing avoids spawning a worker.
  Future<ProcessedAudio> processAsync(AudioBuffer input) {
    if (!enabled) return Future.value(process(input));
    return _processInWorker(input, targetLufs);
  }

  ProcessedAudio process(AudioBuffer input) {
    if (!enabled) {
      return ProcessedAudio(
        audio: input,
        enabled: false,
        originalLufs: double.nan,
        gainDb: 0,
      );
    }
    final samples = Float32List.fromList(input.samples);
    final normalizer = LoudnessNormalizer(targetLufs: targetLufs);
    final originalLufs = normalizer.integratedLufs(
      samples,
      sampleRate: input.sampleRate,
    );
    final gainDb = normalizer.normalizeInPlace(
      samples,
      sampleRate: input.sampleRate,
    );
    return ProcessedAudio(
      audio: AudioBuffer(samples: samples, sampleRate: input.sampleRate),
      enabled: true,
      originalLufs: originalLufs,
      gainDb: gainDb,
    );
  }
}

Future<ProcessedAudio> _processInWorker(AudioBuffer input, double target) =>
    Isolate.run(() => AudioPreprocessor(targetLufs: target).process(input));
