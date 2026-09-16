import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../engine/asr_engine.dart';
import 'audio_buffer.dart';
import 'chunk_planner.dart';
import 'pcm.dart';
import 'wav.dart';

void checkAudioCancellation(bool Function()? isCancelled) {
  if (isCancelled?.call() ?? false) {
    throw const EngineCancelledException('Audio processing cancelled.');
  }
}

/// Canonical little-endian mono float32 on disk. The job owns its directory.
class PcmFile {
  const PcmFile(this.path, this.count, {this.sampleRate = 16000});
  final String path;
  final int count;
  final int sampleRate;
  Duration get duration =>
      Duration(microseconds: (count * 1000000 / sampleRate).round());

  static Future<PcmFile> fromBuffer(AudioBuffer audio, String path) async {
    final output = await File(path).open(mode: FileMode.write);
    try {
      for (var start = 0; start < audio.samples.length; start += 16384) {
        final end = math.min(start + 16384, audio.samples.length);
        final bytes = ByteData((end - start) * 4);
        for (var i = start; i < end; i++) {
          bytes.setFloat32((i - start) * 4, audio.samples[i], Endian.little);
        }
        await output.writeFrom(bytes.buffer.asUint8List());
      }
    } finally {
      await output.close();
    }
    return PcmFile(path, audio.samples.length, sampleRate: audio.sampleRate);
  }

  /// A reader holds at most one block, and closes even when its consumer stops.
  Stream<Float32List> blocks({
    int start = 0,
    int? end,
    int blockSize = 16384,
    double gain = 1,
    bool Function()? isCancelled,
  }) async* {
    final stop = end ?? count;
    if (start < 0 || stop < start || stop > count || blockSize <= 0) {
      throw ArgumentError('Invalid PCM range or block size');
    }
    final input = await File(path).open();
    try {
      await input.setPosition(start * 4);
      for (var at = start; at < stop; at += blockSize) {
        checkAudioCancellation(isCancelled);
        final length = math.min(blockSize, stop - at);
        final bytes = await input.read(length * 4);
        if (bytes.length != length * 4) {
          throw const FormatException('Truncated PCM file');
        }
        final view = ByteData.sublistView(bytes);
        final samples = Float32List(length);
        for (var i = 0; i < length; i++) {
          final value = view.getFloat32(i * 4, Endian.little);
          if (!value.isFinite) {
            throw const FormatException('Non-finite PCM sample');
          }
          samples[i] = (value * gain).clamp(-1.0, 1.0);
        }
        yield samples;
      }
    } finally {
      await input.close();
    }
  }

  Future<void> writeWave(
    File file, {
    List<AudioChunk>? spans,
    double gain = 1,
    bool Function()? isCancelled,
  }) async {
    final ranges = spans ?? [AudioChunk(start: Duration.zero, end: duration)];
    final samples = ranges.fold<int>(
      0,
      (n, s) => n + s.endSampleAt(sampleRate) - s.startSampleAt(sampleRate),
    );
    if (samples > (0xffffffff - 36) ~/ 2) {
      throw ArgumentError('Audio exceeds RIFF WAV size limit');
    }
    final header = encodePcm16Wav(Float32List(0), sampleRate);
    final fields = ByteData.sublistView(header);
    fields.setUint32(4, 36 + samples * 2, Endian.little);
    fields.setUint32(40, samples * 2, Endian.little);
    final output = await file.open(mode: FileMode.write);
    try {
      await output.writeFrom(header);
      for (final span in ranges) {
        await for (final block in blocks(
          start: span.startSampleAt(sampleRate),
          end: span.endSampleAt(sampleRate),
          gain: gain,
          isCancelled: isCancelled,
        )) {
          await output.writeFrom(float32ToPcm16(block));
        }
      }
    } finally {
      await output.close();
    }
  }
}
