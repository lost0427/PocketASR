import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/audio_buffer.dart';
import 'package:pocket_asr/core/audio/chunk_planner.dart';

AudioBuffer _audio(int seconds, [int rate = 16000]) =>
    AudioBuffer(samples: Float32List(seconds * rate), sampleRate: rate);

/// Fills [fromMs, toMs) with a constant amplitude loud enough for the
/// default energy gate (0.5 >> 0.015 mean-abs threshold).
void _speech(Float32List samples, int rate, int fromMs, int toMs, [double v = 0.5]) {
  for (var i = fromMs * rate ~/ 1000; i < toMs * rate ~/ 1000; i++) {
    samples[i] = v;
  }
}

void main() {
  test('fixed mode splits audio into 30 second chunks', () {
    final audio = _audio(65);
    final chunks = const ChunkPlanner().plan(audio);
    expect(chunks.map((chunk) => chunk.duration.inSeconds), [30, 30, 5]);
  });

  test('fixed default has no overlap: chunks are contiguous', () {
    final chunks = const ChunkPlanner().plan(_audio(65));
    for (var i = 1; i < chunks.length; i++) {
      expect(chunks[i].start, chunks[i - 1].end);
    }
    expect(chunks.last.endSampleAt(16000), 16000 * 65);
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

  test('energy merges adjacent segments whose pads touch', () {
    // Two bursts 40 ms apart (gap < 2 * speechPadMs) become one block.
    final samples = Float32List(16000 * 4);
    _speech(samples, 16000, 500, 1500);
    _speech(samples, 16000, 1540, 2540);
    final chunks = const ChunkPlanner(settings: ChunkSettings(mode: ChunkMode.energy))
        .plan(AudioBuffer(samples: samples, sampleRate: 16000));
    expect(chunks, hasLength(1));
    // Span covers both bursts plus padding: ~470 ms .. ~2570 ms.
    expect(chunks.single.start.inMilliseconds, inInclusiveRange(400, 520));
    expect(chunks.single.end.inMilliseconds, inInclusiveRange(2500, 2620));
  });

  test('energy keeps real silence gaps as separate chunks', () {
    final samples = Float32List(16000 * 4);
    _speech(samples, 16000, 500, 1500);
    _speech(samples, 16000, 2000, 3000); // 500 ms of silence between
    final chunks = const ChunkPlanner(settings: ChunkSettings(mode: ChunkMode.energy))
        .plan(AudioBuffer(samples: samples, sampleRate: 16000));
    expect(chunks, hasLength(2));
    expect(chunks[1].start.inMilliseconds, greaterThan(chunks[0].end.inMilliseconds));
  });

  test('energy merge stops at maxSpeechSeconds', () {
    // Merging the two 12 s bursts would span ~24 s > maxSpeechSeconds=20,
    // so they stay separate and neither is split (each fits in 20 s).
    final samples = Float32List(16000 * 30);
    _speech(samples, 16000, 1000, 13000);
    _speech(samples, 16000, 13040, 26040);
    final chunks = ChunkPlanner(
      settings: const ChunkSettings(mode: ChunkMode.energy, maxSpeechSeconds: 20),
    ).plan(AudioBuffer(samples: samples, sampleRate: 16000));
    expect(chunks, hasLength(2));
    for (final chunk in chunks) {
      expect(chunk.duration.inMilliseconds, lessThanOrEqualTo(20100));
    }
  });

  test('energy merge chains until maxSpeechSeconds caps it', () {
    // Three 8 s bursts, 40 ms apart, max 20 s: 1+2 merge (16 s), adding 3
    // would exceed 20 s, so segment 3 stays separate.
    final samples = Float32List(16000 * 40);
    _speech(samples, 16000, 1000, 9000);
    _speech(samples, 16000, 9040, 17040);
    _speech(samples, 16000, 17080, 25080);
    final chunks = ChunkPlanner(
      settings: const ChunkSettings(mode: ChunkMode.energy, maxSpeechSeconds: 20),
    ).plan(AudioBuffer(samples: samples, sampleRate: 16000));
    expect(chunks, hasLength(2));
    expect(chunks.first.duration.inMilliseconds, greaterThan(15000));
    expect(chunks.first.duration.inMilliseconds, lessThanOrEqualTo(20100));
  });

  test('energy on pure silence plans no chunks', () {
    final chunks = const ChunkPlanner(settings: ChunkSettings(mode: ChunkMode.energy))
        .plan(_audio(3));
    expect(chunks, isEmpty);
  });

  test('oversized blocks split with overlap and always advance', () {
    final chunks = ChunkPlanner(
      settings: const ChunkSettings(
        chunkSeconds: 40,
        maxSpeechSeconds: 30,
        overlapSeconds: 10,
      ),
    ).plan(_audio(80));
    // [0,40) -> [0,30)+[20,40); [40,80) -> [40,70)+[60,80).
    expect(
      chunks.map((c) => [c.start.inSeconds, c.end.inSeconds]).toList(),
      [
        [0, 30],
        [20, 40],
        [40, 70],
        [60, 80],
      ],
    );
  });

  test('empty audio plans nothing', () {
    expect(const ChunkPlanner().plan(_audio(0)), isEmpty);
  });

  test('invalid settings throw ArgumentError from plan', () {
    final audio = _audio(2);
    const cases = <ChunkSettings>[
      ChunkSettings(chunkSeconds: 0),
      ChunkSettings(chunkSeconds: -1),
      ChunkSettings(chunkSeconds: double.nan),
      ChunkSettings(chunkSeconds: double.infinity),
      ChunkSettings(maxSpeechSeconds: 0),
      ChunkSettings(maxSpeechSeconds: double.nan),
      ChunkSettings(overlapSeconds: -1),
      ChunkSettings(overlapSeconds: double.nan),
      // overlap >= max would make _limit step backwards and never finish.
      ChunkSettings(maxSpeechSeconds: 10, overlapSeconds: 10),
      ChunkSettings(maxSpeechSeconds: 10, overlapSeconds: 30),
      ChunkSettings(energyThreshold: -0.1),
      ChunkSettings(energyThreshold: double.infinity),
      ChunkSettings(minSpeechMs: -1),
      ChunkSettings(speechPadMs: -1),
    ];
    for (var i = 0; i < cases.length; i++) {
      expect(
        () => ChunkPlanner(settings: cases[i]).plan(audio),
        throwsA(isA<ArgumentError>()),
        reason: 'case $i',
      );
    }
    // Non-positive sample rate is the audio's problem, not the settings'.
    expect(
      () => const ChunkPlanner().plan(
        AudioBuffer(samples: Float32List(16000), sampleRate: 0),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('validate runs before any engine-visible work', () {
    const settings = ChunkSettings(chunkSeconds: double.nan);
    expect(settings.validate, throwsA(isA<ArgumentError>()));
  });

  group('groupVad (real neural boundaries)', () {
    AudioChunk seg(double fromS, double toS) => AudioChunk(
      start: Duration(microseconds: (fromS * 1000000).round()),
      end: Duration(microseconds: (toS * 1000000).round()),
    );
    int speechSeconds(List<AudioChunk> window) => window.fold(
      0,
      (sum, span) => sum + span.duration.inSeconds,
    );

    test('pads each boundary and clamps at head and EOF', () {
      final windows = ChunkPlanner.groupVad(
        segments: [seg(0, 0.5), seg(3.5, 4)],
        audio: _audio(4),
        speechPadMs: 200,
        maxSpeechSeconds: 30,
      );
      expect(windows, hasLength(1));
      expect(windows.single, hasLength(2));
      expect(windows.single[0].start, Duration.zero); // pad clamped to 0
      expect(windows.single[0].end.inMilliseconds, 700);
      expect(windows.single[1].start.inMilliseconds, 3300);
      expect(windows.single[1].end.inMilliseconds, 4000); // clamped to EOF
    });

    test('pads that overlap join into one boundary', () {
      final windows = ChunkPlanner.groupVad(
        segments: [seg(1, 1.5), seg(1.6, 2)],
        audio: _audio(4),
        speechPadMs: 200,
        maxSpeechSeconds: 30,
      );
      expect(windows.single, hasLength(1));
      expect(windows.single.single.start.inMilliseconds, 800);
      expect(windows.single.single.end.inMilliseconds, 2200);
    });

    test('merges short segments until the speech total would pass max', () {
      // 3 x 12 s of speech with huge silences between, cap 30 s: 12+12=24
      // fits in one window, adding the third would reach 36 — so it starts
      // its own window and keeps its real timeline position.
      final windows = ChunkPlanner.groupVad(
        segments: [seg(10, 22), seg(82, 94), seg(154, 166)],
        audio: _audio(170),
        speechPadMs: 0,
        maxSpeechSeconds: 30,
      );
      expect(windows.map((w) => w.length), [2, 1]);
      expect(speechSeconds(windows.first), 24);
      // Silence is NOT smuggled in: the window's spans stay separate pieces.
      expect(windows.first[1].start.inSeconds, 82);
      expect(windows[1].single.start.inSeconds, 154);
    });

    test('a single oversized speech run splits into max-length windows', () {
      final windows = ChunkPlanner.groupVad(
        segments: [seg(0, 70)],
        audio: _audio(70),
        speechPadMs: 0,
        maxSpeechSeconds: 30,
      );
      expect(
        windows.map((w) => w.single.duration.inSeconds).toList(),
        [30, 30, 10],
      );
    });

    test('empty input plans nothing', () {
      expect(
        ChunkPlanner.groupVad(
          segments: const [],
          audio: _audio(2),
          speechPadMs: 30,
          maxSpeechSeconds: 30,
        ),
        isEmpty,
      );
      expect(
        ChunkPlanner.groupVad(
          segments: [seg(0, 1)],
          audio: _audio(0),
          speechPadMs: 30,
          maxSpeechSeconds: 30,
        ),
        isEmpty,
      );
    });

    test('invalid grouping arguments throw', () {
      for (final bad in <List<Object>>[
        [-1, 30.0],
        [0, 0.0],
        [0, double.nan],
      ]) {
        expect(
          () => ChunkPlanner.groupVad(
            segments: const [],
            audio: _audio(1),
            speechPadMs: bad[0] as int,
            maxSpeechSeconds: bad[1] as double,
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'pad=${bad[0]} max=${bad[1]}',
        );
      }
    });
  });
}
