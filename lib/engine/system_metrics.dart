import 'dart:ffi';
import 'dart:io';

/// Point-in-time resource usage for this process.
class SystemMetrics {
  const SystemMetrics({this.cpuPercent, this.memoryBytes});

  /// Process CPU utilisation between two [SystemMetricsSampler.sample]
  /// calls, on the **per-core** scale: 100.0 means one core was fully
  /// busy for the whole interval, and a multi-threaded process can report
  /// more (up to `100 * Platform.numberOfProcessors`). For the other
  /// common convention — **total-normalised**, where 100.0 means every
  /// core saturated — divide by `Platform.numberOfProcessors`.
  ///
  /// This is a delta-based rate, not the raw cumulative tick counter
  /// that /proc reports. Null whenever a rate cannot be honestly
  /// computed: the first sample (a rate needs two points), platforms
  /// without /proc (Windows/macOS/iOS — never fabricated there), read or
  /// parse failure, missing `_SC_CLK_TCK`, a non-positive interval, or a
  /// counter that went backwards (guarded; the next sample re-anchors).
  final double? cpuPercent;

  /// Resident set size in bytes (`ProcessInfo.currentRss`).
  final int? memoryBytes;
}

/// Reads process CPU time from `/proc/self/stat` and converts it to a
/// rate over monotonic wall time. Works on Android and Linux; every
/// other platform simply yields `cpuPercent: null`.
///
/// Stateful: hold one instance and call [sample] periodically. No
/// timers or background work — sampling cadence belongs to the caller.
class SystemMetricsSampler {
  SystemMetricsSampler({
    Future<String?> Function()? readProcSelfStat,
    int Function()? monotonicMicros,
    int? Function()? ticksPerSecond,
  })  : _readStat = readProcSelfStat ?? _readProcSelfStatDefault,
        _clock = monotonicMicros ?? _monotonicMicros,
        _hz = ticksPerSecond ?? _sysconfClkTck;

  final Future<String?> Function() _readStat;
  final int Function() _clock;
  final int? Function() _hz;

  int? _prevTicks;
  int? _prevMicros;

  Future<SystemMetrics> sample() async {
    final memory = ProcessInfo.currentRss;
    final stat = await _readStat();
    final hz = _hz();
    final ticks = stat == null ? null : _cpuTicks(stat);
    final now = _clock();

    if (ticks == null || hz == null || hz <= 0) {
      // No usable reading: drop the anchor so the next good sample
      // starts fresh instead of measuring across the gap.
      _prevTicks = null;
      _prevMicros = null;
      return SystemMetrics(memoryBytes: memory);
    }

    final prevTicks = _prevTicks;
    final prevMicros = _prevMicros;
    _prevTicks = ticks;
    _prevMicros = now;

    if (prevTicks == null || prevMicros == null) {
      return SystemMetrics(memoryBytes: memory); // first point of the delta
    }
    final deltaTicks = ticks - prevTicks;
    final deltaMicros = now - prevMicros;
    if (deltaTicks < 0 || deltaMicros <= 0) {
      // Counter went backwards (shouldn't for a live process, but don't
      // divide into a bogus negative) or the clock did not move.
      return SystemMetrics(memoryBytes: memory);
    }

    final cpuSeconds = deltaTicks / hz;
    final wallSeconds = deltaMicros / 1e6;
    return SystemMetrics(
      cpuPercent: cpuSeconds / wallSeconds * 100.0,
      memoryBytes: memory,
    );
  }
}

Future<String?> _readProcSelfStatDefault() async {
  if (!Platform.isAndroid && !Platform.isLinux) return null;
  try {
    return await File('/proc/self/stat').readAsString();
  } catch (_) {
    return null;
  }
}

/// Dart's [Stopwatch] runs on the OS monotonic clock, so wall gaps stay
/// correct across NTP steps and suspend/resume. Lazy-initialised.
final Stopwatch _stopwatch = Stopwatch()..start();

int _monotonicMicros() => _stopwatch.elapsedMicroseconds;

int? _cachedHz;
bool _hzTried = false;

/// Kernel USER_HZ via `sysconf(_SC_CLK_TCK)`. The `_SC_CLK_TCK` name
/// differs per libc: 6 on Android bionic (NDK `bits/sysconf.h`,
/// `#define _SC_CLK_TCK 0x0006`) and 2 on glibc (`bits/confname.h`).
/// Flutter Linux is glibc-only, so the platform branch is sufficient.
/// Never assumes 100: returns null if the lookup or call fails.
int? _sysconfClkTck() {
  if (_hzTried) return _cachedHz;
  _hzTried = true;
  try {
    final libc = DynamicLibrary.open(
      Platform.isAndroid ? 'libc.so' : 'libc.so.6',
    );
    final sysconf =
        libc.lookupFunction<Long Function(Int32), int Function(int)>(
      'sysconf',
    );
    final hz = sysconf(Platform.isAndroid ? 6 : 2);
    _cachedHz = hz > 0 ? hz : null;
  } catch (_) {
    _cachedHz = null;
  }
  return _cachedHz;
}

/// Sums utime+stime (fields 14 and 15 of /proc/[pid]/stat) from a stat
/// line. The comm field (2nd) is wrapped in parentheses and may itself
/// contain spaces and parentheses, so the field split anchors on the
/// LAST ')': after it, fields start at stat(3) = index 0, putting utime
/// at index 11 and stime at index 12.
int? _cpuTicks(String stat) {
  final open = stat.indexOf('(');
  final close = stat.lastIndexOf(')');
  if (open < 0 || close <= open) return null;
  final fields = stat.substring(close + 1).trim().split(RegExp(r'\s+'));
  if (fields.length < 13) return null;
  final utime = int.tryParse(fields[11]);
  final stime = int.tryParse(fields[12]);
  if (utime == null || stime == null) return null;
  return utime + stime;
}
