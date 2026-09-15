import 'asr_engine.dart';

/// Rolling tokens/s from engine-reported *true* token counts (plan §1.4).
///
/// [add] takes the cumulative count so a poll that repeats the same value adds
/// no fake tokens. The rate comes from the token delta over the wall-clock
/// delta inside [window], so a short burst does not dominate. Until two samples
/// span a positive window it returns null — the UI shows `—`, it never guesses.
///
/// ponytail: these are model tokens, not 字; the UI shows a grapheme 字/s
/// alongside via `token_counter.dart` because Chinese users read tokens as 字.
class TokenRateTracker {
  TokenRateTracker({this.window = const Duration(seconds: 2)});

  /// Rolling window; 2 s balances responsiveness against jitter (plan Phase 6).
  final Duration window;

  final List<_Sample> _samples = [];
  int? _latestTokens;

  /// Last cumulative token count, or null when none was ever reported.
  int? get tokens => _latestTokens;

  /// Records the cumulative [tokens] seen at [elapsed].
  ///
  /// A negative [tokens] means "this engine cannot count" and is ignored.
  void add(int tokens, Duration elapsed) {
    if (tokens < 0) return;
    if (_latestTokens != null && tokens < _latestTokens!) {
      _samples.clear(); // counter went backwards: new job/session
    }
    _latestTokens = tokens;
    _samples.add(_Sample(elapsed, tokens));
    _prune(elapsed);
  }

  /// Tokens/s over the trailing [window], or null when it cannot be measured.
  double? get tokensPerSecond {
    if (_samples.length < 2) return null;

    final newest = _samples.last;
    final cutoff = newest.elapsed - window;

    // Reference = latest sample at or before the cutoff (one just before the
    // window is kept by [_prune] so the span is never shorter than the window).
    var reference = _samples.first;
    for (final sample in _samples) {
      if (sample.elapsed > cutoff) break;
      reference = sample;
    }
    if (identical(reference, newest)) return null;

    final deltaMs = (newest.elapsed - reference.elapsed).inMilliseconds;
    if (deltaMs <= 0) return null;
    return (newest.tokens - reference.tokens) * 1000 / deltaMs;
  }

  void reset() {
    _samples.clear();
    _latestTokens = null;
  }

  void _prune(Duration now) {
    final cutoff = now - window;
    // Drop everything before the last sample at or before the cutoff, keeping
    // that sample as the window's anchor.
    var anchor = -1;
    for (var i = 0; i < _samples.length; i++) {
      if (_samples[i].elapsed <= cutoff) {
        anchor = i;
      } else {
        break;
      }
    }
    if (anchor > 0) _samples.removeRange(0, anchor);
  }
}

class _Sample {
  const _Sample(this.elapsed, this.tokens);

  final Duration elapsed;
  final int tokens;
}

/// End-of-run summary built from the engine's true token count and wall clock.
///
/// Consumed by the metrics bar and written to the transcript row so history can
/// show the same numbers (plan Phase 6 / requirement 12).
class TranscriptionMetrics {
  const TranscriptionMetrics({
    required this.elapsed,
    this.tokens,
    this.audioDuration,
  });

  /// Copies the engine-reported fields out of a finished result.
  factory TranscriptionMetrics.fromResult(TranscriptionResult result) =>
      TranscriptionMetrics(
        elapsed: result.elapsed,
        tokens: result.tokens,
        audioDuration: result.audioDuration,
      );

  /// Total wall-clock time.
  final Duration elapsed;

  /// Real tokenizer count, or null when the engine cannot report one.
  final int? tokens;

  /// Input audio length; null when not measured.
  final Duration? audioDuration;

  /// Total tokens / total wall clock, or null when unknown (shown as `—`).
  double? get avgTokensPerSec {
    final count = tokens;
    final millis = elapsed.inMilliseconds;
    if (count == null || count <= 0 || millis <= 0) return null;
    return count * 1000 / millis;
  }

  /// Real-time factor = wall clock / audio time; null when audio is unknown.
  double? get rtf {
    final audioMs = audioDuration?.inMilliseconds;
    if (audioMs == null || audioMs <= 0) return null;
    return elapsed.inMilliseconds / audioMs;
  }
}
