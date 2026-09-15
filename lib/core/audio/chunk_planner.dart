import 'dart:math' as math;
import 'audio_buffer.dart';

enum ChunkMode { fixed, energy }

class ChunkSettings {
  const ChunkSettings({
    this.mode = ChunkMode.fixed,
    this.chunkSeconds = 30,
    this.energyThreshold = 0.015,
    this.minSpeechMs = 180,
    this.speechPadMs = 30,
    this.maxSpeechSeconds = 30,
    this.overlapSeconds = 3,
  });

  final ChunkMode mode;
  final double chunkSeconds;
  final double energyThreshold;
  final int minSpeechMs;
  final int speechPadMs;
  final double maxSpeechSeconds;
  final double overlapSeconds;

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
}

class ChunkPlanner {
  const ChunkPlanner({this.settings = const ChunkSettings()});

  final ChunkSettings settings;

  List<AudioChunk> plan(AudioBuffer audio) {
    if (audio.samples.isEmpty) return const [];
    final chunks = settings.mode == ChunkMode.fixed
        ? _fixed(audio)
        : _energy(audio);
    return _limitAndMerge(chunks, audio.duration, audio.sampleRate);
  }

  List<AudioChunk> _fixed(AudioBuffer audio) {
    final size = math.max(1, (settings.chunkSeconds * audio.sampleRate).round());
    final result = <AudioChunk>[];
    for (var start = 0; start < audio.samples.length; start += size) {
      final end = math.min(audio.samples.length, start + size);
      result.add(AudioChunk(
        start: _duration(start, audio.sampleRate),
        end: _duration(end, audio.sampleRate),
      ));
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
        AudioChunk(
          start: _duration(math.max(0, range[0] - pad), audio.sampleRate),
          end: _duration(math.min(audio.samples.length, range[1] + pad), audio.sampleRate),
        ),
    ];
  }

  List<AudioChunk> _limitAndMerge(List<AudioChunk> input, Duration total, int rate) {
    if (input.isEmpty) return input;
    final maxMs = settings.maxSpeechSeconds * 1000;
    final out = <AudioChunk>[];
    for (final chunk in input) {
      var start = chunk.start;
      while (chunk.end - start > Duration(milliseconds: maxMs.round())) {
        final end = start + Duration(milliseconds: maxMs.round());
        out.add(AudioChunk(start: start, end: end));
        start = end - Duration(milliseconds: (settings.overlapSeconds * 1000).round());
      }
      out.add(AudioChunk(start: start, end: chunk.end));
    }
    return out;
  }

  static Duration _duration(int samples, int rate) =>
      Duration(microseconds: (samples * 1000000 / rate).round());
}
