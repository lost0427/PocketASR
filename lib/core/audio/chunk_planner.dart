import 'dart:math' as math;

import 'audio_buffer.dart';

/// Chunking strategy used by [ChunkPlanner].
enum ChunkMode {
  /// Contiguous fixed-length blocks covering the whole audio.
  fixed,

  /// Frame-level mean-absolute-energy gate. This is a cheap honest energy
  /// detector, **not** a neural VAD: loud non-speech (keyboard, music) passes
  /// it and quiet speech below [ChunkSettings.energyThreshold] does not.
  energy,
}

class ChunkSettings {
  const ChunkSettings({
    this.mode = ChunkMode.fixed,
    this.chunkSeconds = 30,
    this.energyThreshold = 0.015,
    this.minSpeechMs = 180,
    this.speechPadMs = 30,
    this.maxSpeechSeconds = 30,
    this.overlapSeconds = 0,
  });

  final ChunkMode mode;
  final double chunkSeconds;
  final double energyThreshold;
  final int minSpeechMs;
  final int speechPadMs;
  final double maxSpeechSeconds;

  /// Audio shared between consecutive oversized blocks. When > 0 the same
  /// audio is transcribed twice at block seams and engines typically emit
  /// duplicated words there; this codebase does **not** deduplicate that text
  /// (no LCS merge is implemented), so keep this at 0 unless you accept the
  /// repetition. Must be `< maxSpeechSeconds` or splitting could not advance.
  final double overlapSeconds;

  /// Throws [ArgumentError] on values that would hang [_limit] or produce
  /// nonsense blocks. [ChunkPlanner.plan] calls this, so no caller path skips
  /// it; services may also pre-validate to fail before any IO.
  void validate() {
    void positive(String name, double value) {
      if (!value.isFinite || value <= 0) {
        throw ArgumentError.value(value, name, 'must be finite and > 0');
      }
    }

    void nonNegative(String name, double value) {
      if (!value.isFinite || value < 0) {
        throw ArgumentError.value(value, name, 'must be finite and >= 0');
      }
    }

    positive('chunkSeconds', chunkSeconds);
    positive('maxSpeechSeconds', maxSpeechSeconds);
    nonNegative('energyThreshold', energyThreshold);
    nonNegative('overlapSeconds', overlapSeconds);
    if (overlapSeconds >= maxSpeechSeconds) {
      throw ArgumentError.value(
        overlapSeconds,
        'overlapSeconds',
        'must be < maxSpeechSeconds or block splitting cannot make progress',
      );
    }
    if (minSpeechMs < 0) {
      throw ArgumentError.value(minSpeechMs, 'minSpeechMs', 'must be >= 0');
    }
    if (speechPadMs < 0) {
      throw ArgumentError.value(speechPadMs, 'speechPadMs', 'must be >= 0');
    }
  }

  ChunkSettings copyWith({
    ChunkMode? mode,
    double? chunkSeconds,
    double? energyThreshold,
    int? minSpeechMs,
    int? speechPadMs,
    double? maxSpeechSeconds,
    double? overlapSeconds,
  }) => ChunkSettings(
    mode: mode ?? this.mode,
    chunkSeconds: chunkSeconds ?? this.chunkSeconds,
    energyThreshold: energyThreshold ?? this.energyThreshold,
    minSpeechMs: minSpeechMs ?? this.minSpeechMs,
    speechPadMs: speechPadMs ?? this.speechPadMs,
    maxSpeechSeconds: maxSpeechSeconds ?? this.maxSpeechSeconds,
    overlapSeconds: overlapSeconds ?? this.overlapSeconds,
  );
}

class AudioChunk {
  const AudioChunk({required this.start, required this.end});

  final Duration start;
  final Duration end;

  Duration get duration => end - start;

  /// Sample indices for slicing [AudioBuffer.samples] at [sampleRate].
  /// Round-trip exact for the rates the planner itself produces.
  int startSampleAt(int sampleRate) => _sampleIndex(start, sampleRate);
  int endSampleAt(int sampleRate) => _sampleIndex(end, sampleRate);
}
class ChunkPlanner {
  const ChunkPlanner({this.settings = const ChunkSettings()});

  final ChunkSettings settings;

  /// Plans ascending, non-overlapping-by-default blocks for [audio].
  ///
  /// Returns `[]` when energy mode finds no speech; never returns blocks
  /// longer than [ChunkSettings.maxSpeechSeconds].
  List<AudioChunk> plan(AudioBuffer audio) {
    settings.validate();
    if (audio.sampleRate <= 0) {
      throw ArgumentError.value(
        audio.sampleRate,
        'audio.sampleRate',
        'must be > 0',
      );
    }
    if (audio.samples.isEmpty) return const [];
    final chunks = settings.mode == ChunkMode.fixed
        ? _fixed(audio)
        : _mergeAdjacent(_energy(audio));
    return _limit(chunks, audio);
  }

  List<AudioChunk> _fixed(AudioBuffer audio) {
    final size = math.max(1, (settings.chunkSeconds * audio.sampleRate).round());
    final result = <AudioChunk>[];
    for (var start = 0; start < audio.samples.length; start += size) {
      final end = math.min(audio.samples.length, start + size);
      result.add(_at(start, end, audio.sampleRate));
    }
    return result;
  }

  List<AudioChunk> _energy(AudioBuffer audio) {
    final frame = math.max(1, (audio.sampleRate * 0.02).round());
    final ranges = <List<int>>[];
    int? start;
    for (var i = 0; i < audio.samples.length; i += frame) {
      final end = math.min(audio.samples.length, i + frame);
      var sum = 0.0;
      for (var j = i; j < end; j++) {
        sum += audio.samples[j].abs();
      }
      final active = sum / (end - i) >= settings.energyThreshold;
      if (active && start == null) start = i;
      if ((!active || end == audio.samples.length) && start != null) {
        final stop = active && end == audio.samples.length ? end : i;
        if (stop - start >= settings.minSpeechMs * audio.sampleRate / 1000) {
          ranges.add([start, stop]);
        }
        start = null;
      }
    }
    final pad = settings.speechPadMs * audio.sampleRate ~/ 1000;
    return [
      for (final range in ranges)
        _at(
          math.max(0, range[0] - pad),
          math.min(audio.samples.length, range[1] + pad),
          audio.sampleRate,
        ),
    ];
  }

  /// Re-joins energy segments whose pads touch (gap <= 2 x [speechPadMs]), as
  /// long as the merged span still fits [ChunkSettings.maxSpeechSeconds].
  /// Silences longer than that stay real boundaries, and [_limit] splits
  /// whatever merge exceeded maxSpeech instead of merging past it.
  List<AudioChunk> _mergeAdjacent(List<AudioChunk> input) {
    final maxUs = (settings.maxSpeechSeconds * 1000000).round();
    final bridgeUs = settings.speechPadMs * 2000;
    final out = <AudioChunk>[];
    for (final chunk in input) {
      if (out.isNotEmpty) {
        final last = out.last;
        if (chunk.start.inMicroseconds - last.end.inMicroseconds <= bridgeUs &&
            chunk.end.inMicroseconds - last.start.inMicroseconds <= maxUs) {
          out[out.length - 1] = AudioChunk(start: last.start, end: chunk.end);
          continue;
        }
      }
      out.add(chunk);
    }
    return out;
  }

  /// Splits blocks longer than maxSpeechSeconds into <= maxSpeech pieces,
  /// stepping back by overlapSeconds. [step] is forced >= 1 so the loop
  /// always terminates even if validation were bypassed.
  List<AudioChunk> _limit(List<AudioChunk> input, AudioBuffer audio) {
    final rate = audio.sampleRate;
    final maxSamples = math.max(1, (settings.maxSpeechSeconds * rate).round());
    final overlapSamples = (settings.overlapSeconds * rate).round();
    final step = math.max(1, maxSamples - overlapSamples);
    final out = <AudioChunk>[];
    for (final chunk in input) {
      final end = chunk.endSampleAt(rate).clamp(0, audio.samples.length);
      var start = chunk.startSampleAt(rate).clamp(0, end);
      while (end - start > maxSamples) {
        out.add(_at(start, start + maxSamples, rate));
        start += step;
      }
      if (start < end) out.add(_at(start, end, rate));
    }
    return out;
  }

  static AudioChunk _at(int startSample, int endSample, int rate) => AudioChunk(
    start: _duration(startSample, rate),
    end: _duration(endSample, rate),
  );

  /// Groups *real* VAD boundaries (from a neural detector's [VadPlan]) into
  /// transcribable windows. This is planning arithmetic on supplied
  /// boundaries — it does not detect anything itself.
  ///
  /// Each segment is padded outward by [speechPadMs] (clamped to the audio,
  /// so head and EOF never reach outside), overlapping pads join into one
  /// boundary, spans longer than [maxSpeechSeconds] are split, and pieces are
  /// then packed into windows whose total **speech** stays ≤ max. Silence
  /// between pieces inside a window is real but *never* sliced in: callers
  /// must concatenate the window's span PCM, never cut from `first.start`
  /// to `last.end`, or long gaps would be smuggled back into the audio.
  /// Time coordinates stay on the original audio timeline.
  static List<List<AudioChunk>> groupVad({
    required List<AudioChunk> segments,
    required AudioBuffer audio,
    required int speechPadMs,
    required double maxSpeechSeconds,
  }) {
    if (speechPadMs < 0) {
      throw ArgumentError.value(speechPadMs, 'speechPadMs', 'must be >= 0');
    }
    if (!maxSpeechSeconds.isFinite || maxSpeechSeconds <= 0) {
      throw ArgumentError.value(
        maxSpeechSeconds,
        'maxSpeechSeconds',
        'must be finite and > 0',
      );
    }
    final rate = audio.sampleRate;
    if (rate <= 0) {
      throw ArgumentError.value(rate, 'audio.sampleRate', 'must be > 0');
    }
    final total = audio.samples.length;
    if (total == 0) return const [];
    final pad = speechPadMs * rate ~/ 1000;

    // Pad, clamp, then join spans whose padded edges overlap.
    final spans = <List<int>>[];
    for (final segment in segments) {
      final start = math.max(
        0,
        segment.startSampleAt(rate) - pad,
      );
      final end = math.min(total, segment.endSampleAt(rate) + pad);
      if (end <= start) continue;
      if (spans.isNotEmpty && start <= spans.last[1]) {
        if (end > spans.last[1]) spans.last[1] = end;
        continue;
      }
      spans.add([start, end]);
    }

    // Cut anything longer than one window first (always terminates: the
    // piece step is maxSamples >= 1), then pack pieces greedily by their
    // summed length, so a window's *speech* total respects the cap.
    final maxSamples = math.max(1, (maxSpeechSeconds * rate).round());
    final windows = <List<AudioChunk>>[];
    var group = <AudioChunk>[];
    var groupSamples = 0;
    for (final span in spans) {
      for (var s = span[0]; s < span[1]; s += maxSamples) {
        final end = math.min(span[1], s + maxSamples);
        final length = end - s;
        if (group.isNotEmpty && groupSamples + length > maxSamples) {
          windows.add(group);
          group = <AudioChunk>[];
          groupSamples = 0;
        }
        group.add(_at(s, end, rate));
        groupSamples += length;
      }
    }
    if (group.isNotEmpty) windows.add(group);
    return windows;
  }
}

int _sampleIndex(Duration at, int rate) =>
    (at.inMicroseconds * rate / 1000000).round();

Duration _duration(int samples, int rate) =>
    Duration(microseconds: (samples * 1000000 / rate).round());
