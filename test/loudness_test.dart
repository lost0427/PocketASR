import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/loudness.dart';
import 'package:pocket_asr/core/audio/pcm.dart';

Float32List _sine({
  double amplitude = 0.5,
  double freq = 1000,
  double seconds = 1.0,
  int fs = 16000,
}) {
  final n = (seconds * fs).round();
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = amplitude * math.sin(2 * math.pi * freq * i / fs);
  }
  return out;
}

void main() {
  group('PCM', () {
    test('PCM16 round-trips to f32 within one LSB', () {
      final src = Float32List.fromList([0.0, 0.5, -0.5, 0.25, -1.0, 0.9999]);
      final back = pcm16ToFloat32(float32ToPcm16(src));
      for (var i = 0; i < src.length; i++) {
        expect(back[i], closeTo(src[i], 1.0 / 32768.0));
      }
    });

    test('decodes little-endian PCM16 with sign extension', () {
      expect(pcm16ToFloat32(Uint8List.fromList([0x00, 0x40]))[0], 0.5);
      expect(pcm16ToFloat32(Uint8List.fromList([0x00, 0xc0]))[0], -0.5);
      expect(pcm16ToFloat32(Uint8List.fromList([0x00, 0x80]))[0], -1.0);
    });

    test('rejects odd-length PCM16 instead of dropping the trailing byte', () {
      expect(() => pcm16ToFloat32(Uint8List(3)), throwsArgumentError);
    });

    test('f32 byte view round-trips', () {
      final src = Float32List.fromList([0.1, -0.2, 0.3]);
      expect(float32FromBytes(bytesFromFloat32(src)), orderedEquals(src));
    });

    test('rejects f32 byte views that are not a multiple of 4', () {
      expect(() => float32FromBytes(Uint8List(6)), throwsArgumentError);
    });

    test('rejects misaligned f32 byte views', () {
      final backing = Uint8List(1 + 8);
      final misaligned = Uint8List.view(backing.buffer, 1, 8);
      expect(() => float32FromBytes(misaligned), throwsArgumentError);
    });
  });

  group('LoudnessNormalizer', () {
    const normalizer = LoudnessNormalizer();

    test('absolute scale matches BS.1770 for a full-scale 1 kHz sine', () {
      // K-weighting is ~+1.39 dB at 1 kHz, so a 0 dBFS sine reads ~-3 LUFS.
      expect(normalizer.integratedLufs(_sine(amplitude: 1.0)), closeTo(-3.0, 0.5));
    });

    test('normalizes a 1 kHz sine to the target', () {
      final s = _sine(amplitude: 0.5);
      normalizer.normalizeInPlace(s);
      expect(normalizer.integratedLufs(s), closeTo(-16.0, 0.3));
    });

    test('halving the amplitude adds ~6 dB of gain', () {
      final loud = _sine(amplitude: 0.5);
      final quiet = _sine(amplitude: 0.25);
      final gl = normalizer.normalizeInPlace(loud);
      final gq = normalizer.normalizeInPlace(quiet);
      expect(gq - gl, closeTo(6.02, 0.2));
    });

    test('silence gets no gain and is left untouched', () {
      final z = Float32List(16000);
      expect(normalizer.integratedLufs(z), double.negativeInfinity);
      expect(normalizer.normalizeInPlace(z), 0.0);
      expect(z.every((v) => v == 0), isTrue);
    });

    test('true-peak protection limits the gain', () {
      // A near-silent take with a full-scale click: loudness wants a big boost,
      // the peak ceiling must refuse it.
      final impulse = Float32List(16000);
      impulse[0] = 1.0;
      final gain = normalizer.normalizeInPlace(impulse);
      expect(gain, lessThan(0));
      expect(truePeakDb(impulse), lessThanOrEqualTo(-1.0 + 1e-6));
    });

    test('target is configurable', () {
      const quiet = LoudnessNormalizer(targetLufs: -23.0);
      final s = _sine(amplitude: 0.5);
      quiet.normalizeInPlace(s);
      expect(quiet.integratedLufs(s), closeTo(-23.0, 0.3));
    });
  });
}
