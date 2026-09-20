import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/audio_buffer.dart';
import 'package:pocket_asr/core/audio/chunk_planner.dart';
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
    'non-finite decoded samples become silence without loading the file',
    () async {
      final data = ByteData(5 * 4)
        ..setFloat32(0, 0.25, Endian.little)
        ..setFloat32(4, double.nan, Endian.little)
        ..setFloat32(8, double.infinity, Endian.little)
        ..setFloat32(12, double.negativeInfinity, Endian.little)
        ..setFloat32(16, -0.5, Endian.little);
      final path = '${dir.path}/damaged.f32';
      await File(path).writeAsBytes(data.buffer.asUint8List());

      final blocks = await PcmFile(path, 5).blocks(blockSize: 2).toList();

      expect(blocks.map((block) => block.length), [2, 2, 1]);
      expect(blocks.expand((block) => block), [0.25, 0, 0, 0, -0.5]);
    },
  );

  test('raw f32 reads slice whole values for the neural VAD', () async {
    final audio = AudioBuffer(
      samples: Float32List.fromList(List.generate(10, (i) => (i - 5) / 8)),
      sampleRate: 16000,
    );
    final path = '${dir.path}/raw.f32';
    await PcmFile.fromBuffer(audio, path);

    final lengths = <int>[];
    final samples = <double>[];
    await for (final block in readRawFloat32(path, blockSize: 4)) {
      lengths.add(block.length);
      samples.addAll(block);
    }
    expect(lengths, [4, 4, 2]);
    expect(samples, audio.samples);

    await expectLater(
      readRawFloat32('${dir.path}/missing.f32').drain<void>(),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('fixed windows re-slice blocks and pass a short tail through', () async {
    final blocks = Stream.fromIterable([
      Float32List.fromList([1, 2, 3]),
      Float32List.fromList([4, 5, 6, 7, 8, 9]),
    ]);
    final windows = await fixedWindows(blocks, 2).toList();
    expect(windows.map((w) => w.length), [2, 2, 2, 2, 1]);
    expect(windows.expand((w) => w), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  });
}
