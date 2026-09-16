import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/ffmpeg_decoder.dart';
import 'package:pocket_asr/engine/asr_engine.dart';

void main() {
  final executable = Platform.environment['POCKETASR_TEST_FFMPEG'];
  test(
    'real FFmpeg decodes MP3 M4A FLAC, rejects bad inputs and cancels',
    () async {
      final dir = await Directory.systemTemp.createTemp('ffmpeg test ');
      try {
        for (final extension in ['mp3', 'm4a', 'flac']) {
          final source = '${dir.path}/test audio.$extension';
          final generated = await Process.run(executable!, [
            '-v',
            'error',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440:duration=1',
            '-y',
            source,
          ]);
          expect(generated.exitCode, 0, reason: generated.stderr.toString());
          final pcm = await decodeWithFfmpeg(
            source,
            '${dir.path}/out.f32',
            executable: executable,
          );
          expect(pcm.count, inInclusiveRange(15000, 18000));
          var peak = 0.0;
          await for (final block in pcm.blocks()) {
            for (final sample in block) {
              if (sample.abs() > peak) peak = sample.abs();
            }
          }
          expect(peak, greaterThan(0.01));
        }
        await expectLater(
          decodeWithFfmpeg(
            '${dir.path}/missing.mp3',
            '${dir.path}/bad.f32',
            executable: executable,
          ),
          throwsA(isA<ProcessException>()),
        );
        await expectLater(
          decodeWithFfmpeg(
            'ignored',
            '${dir.path}/cancel.f32',
            executable: executable,
            isCancelled: () => true,
          ),
          throwsA(isA<EngineCancelledException>()),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
    skip: executable == null
        ? 'Set POCKETASR_TEST_FFMPEG to the staged executable'
        : false,
  );
}
