import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/audio_buffer.dart';
import 'package:pocket_asr/core/audio/audio_preprocessor.dart';

void main() {
  test('normalizes a quiet signal and reports applied gain', () {
    final samples = Float32List.fromList(List.generate(
      16000,
      (i) => 0.1 * math.sin(2 * math.pi * 1000 * i / 16000),
    ));
    final result = const AudioPreprocessor(targetLufs: -16).process(
      AudioBuffer(samples: samples, sampleRate: 16000),
    );
    expect(result.enabled, isTrue);
    expect(result.originalLufs, isA<double>());
    expect(result.gainDb, greaterThan(0));
    expect(result.audio.samples, isNot(same(samples)));
  });

  test('disabled preprocessing preserves the input object', () {
    final audio = AudioBuffer(samples: Float32List.fromList([0.1]), sampleRate: 16000);
    final result = const AudioPreprocessor(enabled: false).process(audio);
    expect(result.audio, same(audio));
    expect(result.gainDb, 0);
    expect(result.enabled, isFalse);
  });
}
