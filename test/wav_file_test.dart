import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/audio_source.dart';
import 'package:pocket_asr/core/audio/wav.dart';

void main() {
  test('block writer matches WAV encoder across block boundaries and worker decodes it', () async {
    final dir = await Directory.systemTemp.createTemp('wav-block-test-');
    try {
      final file = File('${dir.path}/audio.wav');
      final samples = Float32List.fromList(List.generate(40001, (i) => (i % 31 - 15) / 16));
      await writePcm16Wav(file, samples, 16000);
      expect(await file.readAsBytes(), encodePcm16Wav(samples, 16000));
      final audio = await const FileAudioSource().read(file.path);
      expect(audio.sampleRate, 16000);
      expect(audio.samples, samples);
      await writePcm16Wav(file, Float32List(0), 16000);
      expect(await file.length(), 44); // Existing longer file was truncated.
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
