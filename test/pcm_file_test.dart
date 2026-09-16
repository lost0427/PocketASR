import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/audio_buffer.dart';
import 'package:pocket_asr/core/audio/chunk_planner.dart';
import 'package:pocket_asr/core/audio/loudness.dart';
import 'package:pocket_asr/core/audio/pcm_file.dart';
import 'package:pocket_asr/core/audio/wav.dart';
import 'package:pocket_asr/engine/asr_engine.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pcm-file-test-');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test(
    'bounded reads, disjoint spans, streaming WAV and cancellation',
    () async {
      final audio = AudioBuffer(
        samples: Float32List.fromList(
          List.generate(40001, (i) => (i % 31 - 15) / 16),
        ),
        sampleRate: 16000,
      );
      final pcm = await PcmFile.fromBuffer(audio, '${dir.path}/audio.f32');
      final lengths = await pcm
          .blocks(blockSize: 1000)
          .map((b) => b.length)
          .toList();
      expect(lengths.reduce(max), 1000);
      expect(lengths.reduce((a, b) => a + b), 40001);
      final wav = File('${dir.path}/slice.wav');
      await pcm.writeWave(
        wav,
        spans: const [
          AudioChunk(start: Duration.zero, end: Duration(milliseconds: 100)),
          AudioChunk(
            start: Duration(seconds: 1),
            end: Duration(milliseconds: 1200),
          ),
        ],
      );
      final decoded = <double>[];
      await for (final block in readCanonicalWave(wav.path)) {
        expect(block.length, lessThanOrEqualTo(512));
        decoded.addAll(block);
      }
      expect(decoded, [
        ...audio.samples.take(1600),
        ...audio.samples.skip(16000).take(3200),
      ]);
      await expectLater(
        pcm.blocks(isCancelled: () => true).drain<void>(),
        throwsA(isA<EngineCancelledException>()),
      );
      await File(pcm.path)
          .delete(); // Readers released handles on cancellation.
    },
  );

  test(
    'disk planner matches fixed and energy boundaries across read blocks',
    () async {
      final audio = AudioBuffer(
        samples: Float32List.fromList(
          List.generate(80000, (i) => i > 15500 && i < 48500 ? 0.1 : 0),
        ),
        sampleRate: 16000,
      );
      final pcm = await PcmFile.fromBuffer(audio, '${dir.path}/audio.f32');
      for (final mode in ChunkMode.values) {
        final planner = ChunkPlanner(
          settings: ChunkSettings(
            mode: mode,
            chunkSeconds: 1,
            maxSpeechSeconds: 1,
          ),
        );
        final memory = planner.plan(audio);
        final disk = await planner.planFile(pcm);
        expect(
          disk.map((c) => (c.start, c.end)),
          memory.map((c) => (c.start, c.end)),
        );
      }
    },
  );

  test(
    'whole-file loudness agrees with memory measurement across boundaries',
    () async {
      for (final count in [1700, 48000]) {
        final audio = AudioBuffer(
          samples: Float32List.fromList(
            List.generate(count, (i) => 0.08 * sin(2 * pi * 997 * i / 16000)),
          ),
          sampleRate: 16000,
        );
        final pcm = await PcmFile.fromBuffer(audio, '${dir.path}/audio.f32');
        const normalizer = LoudnessNormalizer();
        final measured = await normalizer.measureFile(pcm);
        expect(
          measured.lufs,
          closeTo(normalizer.integratedLufs(audio.samples), 0.01),
        );
        expect(
          measured.gainDb,
          closeTo(normalizer.gainDbFor(audio.samples), 0.01),
        );
      }
    },
  );
}
