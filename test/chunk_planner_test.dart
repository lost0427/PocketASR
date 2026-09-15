import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/audio_buffer.dart';
import 'package:pocket_asr/core/audio/chunk_planner.dart';

void main() {
  test('fixed mode splits audio into 30 second chunks', () {
    final audio = AudioBuffer(samples: Float32List(16000 * 65), sampleRate: 16000);
    final chunks = const ChunkPlanner().plan(audio);
    expect(chunks.map((chunk) => chunk.duration.inSeconds), [30, 30, 5]);
  });

  test('energy mode finds speech and pads boundaries', () {
    final samples = Float32List(16000 * 2);
    for (var i = 16000 ~/ 2; i < 16000; i++) {
      samples[i] = 0.5;
    }
    final chunks = const ChunkPlanner(settings: ChunkSettings(mode: ChunkMode.energy)).plan(
      AudioBuffer(samples: samples, sampleRate: 16000),
    );
    expect(chunks, hasLength(1));
    expect(chunks.single.start.inMilliseconds, lessThan(500));
    expect(chunks.single.end.inMilliseconds, greaterThan(990));
  });
}
