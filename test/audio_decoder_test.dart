import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/wav.dart';

void main() {
  test('decodes stereo PCM16 and downsamples to mono 16k', () {
    final wav = _wav(sampleRate: 8000, channels: 2, bits: 16, samples: [
      [0, 32767],
      [16384, 16384],
    ]);
    final audio = const WavDecoder().decode(wav);
    expect(audio.sampleRate, 16000);
    expect(audio.samples.length, 4);
    expect(audio.samples[0], closeTo(0.5, 0.01));
    expect(audio.samples[2], closeTo(0.5, 0.01));
  });

  test('rejects non-WAV data', () {
    expect(() => const WavDecoder().decode(Uint8List(44)), throwsFormatException);
  });
}

Uint8List _wav({required int sampleRate, required int channels, required int bits, required List<List<int>> samples}) {
  final data = BytesBuilder();
  for (final frame in samples) {
    for (final value in frame) {
      final bytes = ByteData(2)..setInt16(0, value, Endian.little);
      data.add(bytes.buffer.asUint8List());
    }
  }
  final payload = data.takeBytes();
  final out = BytesBuilder();
  void text(String value) => out.add(value.codeUnits);
  text('RIFF');
  out.add((36 + payload.length).asBytes());
  text('WAVEfmt ');
  out.add((16).asBytes());
  out.add((1).asBytes(2));
  out.add(channels.asBytes(2));
  out.add(sampleRate.asBytes(4));
  out.add((sampleRate * channels * 2).asBytes(4));
  out.add((channels * 2).asBytes(2));
  out.add(bits.asBytes(2));
  text('data');
  out.add(payload.length.asBytes());
  out.add(payload);
  return out.takeBytes();
}

extension on int {
  Uint8List asBytes([int width = 4]) {
    final data = ByteData(width);
    if (width == 2) {
      data.setUint16(0, this, Endian.little);
    } else {
      data.setUint32(0, this, Endian.little);
    }
    return data.buffer.asUint8List();
  }
}
