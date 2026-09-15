import 'dart:typed_data';

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
