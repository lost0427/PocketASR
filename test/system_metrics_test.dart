import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/engine/system_metrics.dart';

/// Builds a /proc/self/stat line: `pid (comm) state ppid ... utime stime`
/// with utime at field index 11 and stime at 12 after the closing paren.
String statLine(int utime, int stime, {String comm = 'PocketASR (demo)'}) {
  final after = <String>[
    'R', // state (field 3)
    ...List.filled(10, '1'), // fields 4..13 minus stime: ppid..cmajflt
    '$utime', // utime (field 14)
    '$stime', // stime (field 15)
    '0',
    '0',
  ];
  return '1234 ($comm) ${after.join(' ')}';
}

void main() {
  late int micros;
  late int? hz;
  late String? stat;

  SystemMetricsSampler sampler() => SystemMetricsSampler(
        readProcSelfStat: () async => stat,
        monotonicMicros: () => micros,
        ticksPerSecond: () => hz,
      );

  setUp(() {
    micros = 0;
    hz = 100;
    stat = statLine(10, 5);
  });

  test('memory is always reported, first sample has no cpu rate', () async {
    final s = sampler();
    final m = await s.sample();
    expect(m.cpuPercent, isNull);
    expect(m.memoryBytes, greaterThan(0));
  });

  test('cpuPercent is tick delta / hz over monotonic wall delta', () async {
    final s = sampler();
    await s.sample();
    // 40 more ticks at 100 Hz = 0.4 s CPU over 1 s wall = 40 %.
    micros = 1000000;
    stat = statLine(30, 25);
    final m = await s.sample();
    expect(m.cpuPercent, closeTo(40.0, 1e-9));
  });

  test('per-core scale: multi-core sums can exceed 100', () async {
    final s = sampler();
    stat = statLine(0, 0);
    await s.sample();
    micros = 1000000;
    stat = statLine(200, 0); // +200 ticks = 2 s CPU in 1 s wall
    expect((await s.sample()).cpuPercent, closeTo(200.0, 1e-9));
  });

  test('comm containing spaces and parentheses parses', () async {
    final s = sampler();
    stat = statLine(8, 2, comm: 'weird (nested (x)) app name');
    await s.sample();
    micros = 1000000;
    stat = statLine(8, 33); // +31 ticks in 1 s at 100 Hz
    expect((await s.sample()).cpuPercent, closeTo(31.0, 1e-9));
  });

  test('counter going backwards yields null and re-anchors', () async {
    final s = sampler();
    await s.sample();
    micros = 1000000;
    stat = statLine(0, 5); // smaller than previous total: reset guard
    expect((await s.sample()).cpuPercent, isNull);
    micros = 2000000;
    stat = statLine(15, 0); // 15 vs 5: +10 ticks in 1 s from new anchor
    expect((await s.sample()).cpuPercent, closeTo(10.0, 1e-9));
  });

  test('zero wall-time delta yields null instead of dividing', () async {
    final s = sampler();
    await s.sample();
    stat = statLine(60, 40);
    expect((await s.sample()).cpuPercent, isNull); // micros never advanced
  });

  test('missing _SC_CLK_TCK returns null, never assumes 100', () async {
    final s = sampler();
    hz = null;
    await s.sample();
    micros = 1000000;
    stat = statLine(50, 50);
    final m = await s.sample();
    expect(m.cpuPercent, isNull);
    expect(m.memoryBytes, greaterThan(0));
  });

  test('no /proc data (unsupported platform) gives null cpu, real memory',
      () async {
    final s = sampler();
    stat = null;
    await s.sample();
    micros = 1000000;
    final m = await s.sample();
    expect(m.cpuPercent, isNull);
    expect(m.memoryBytes, greaterThan(0));
  });

  test('malformed stat line degrades to null cpu', () async {
    final s = sampler();
    stat = 'garbage without parens or fields';
    final m = await s.sample();
    expect(m.cpuPercent, isNull);
  });
}
