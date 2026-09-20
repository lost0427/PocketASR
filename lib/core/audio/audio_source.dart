import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'audio_buffer.dart';
import 'chunk_planner.dart';
import 'wav.dart';
import 'pcm_file.dart';
import 'ffmpeg_decoder.dart';

abstract interface class AudioSource {
  Future<AudioBuffer> read(String path);
}

/// Mirrors `AudioDecodeChannel.NAME` on the Android side.
const audioDecodeChannel = MethodChannel('pocket_asr/audio_decode');

bool _isAndroid() => Platform.isAndroid;

/// How Android should choose a MediaCodec audio decoder.
enum AudioDecoderPreference { automatic, preferHardware, preferSoftware }

/// Which decode implementation Android must use. `auto` is the production
/// behaviour (dr_libs for its formats, MediaCodec otherwise); the benchmark
/// page pins one side to compare them on the same file.
enum AudioDecoderBackend { auto, builtin, platform }

/// The chain's fixed target rate; [DecodeProbe] frames are counted at it.
const decodeProbeSampleRate = 16000;

/// One measured decode, used to compare decoders on one file.
class DecodeProbe {
  const DecodeProbe({
    required this.elapsed,
    required this.frames,
    this.decoder,
  });

  /// Native decode wall time reported by the platform code.
  final Duration elapsed;

  /// Output samples at [decodeProbeSampleRate].
  final int frames;

  final AudioDecoderInfo? decoder;

  Duration get audioDuration => Duration(
    microseconds: (frames * 1000000 / decodeProbeSampleRate).round(),
  );
}

/// Reads an audio file into a 16 kHz mono [AudioBuffer].
///
/// On non-Android platforms this is the historic [WavDecoder]-only path.
/// On Android the work goes through [channel]: native MediaExtractor +
/// MediaCodec decode/downmix/resample any platform codec (m4a, mp3, flac,
/// wav) and stream the result into a temporary little-endian float32 file;
/// only metadata (`path`, `sampleRate`, `count` and decoder diagnostics)
/// crosses the channel — never the raw PCM. The temp file is read back as a
/// zero-copy Float32List view and
/// deleted in `finally`, success or failure alike (decode failures clean
/// up on the native side before the channel replies).
class FileAudioSource implements AudioSource {
  const FileAudioSource({
    this.decoder = const WavDecoder(),
    this.channel = audioDecodeChannel,
    this.usesNativeDecoder = _isAndroid,
  });

  final WavDecoder decoder;
  final MethodChannel channel;
  final bool Function() usesNativeDecoder;

  /// Production processing retains the native output on disk until job cleanup.
  Future<PcmFile> decodeToDisk(
    String path,
    Directory directory, {
    AudioDecoderPreference decoderPreference = AudioDecoderPreference.automatic,
    AudioDecoderBackend decoderBackend = AudioDecoderBackend.auto,
    bool Function()? isCancelled,
  }) async {
    checkAudioCancellation(isCancelled);
    if (!usesNativeDecoder()) {
      return decodeWithFfmpeg(
        path,
        '${directory.path}/decoded.f32',
        isCancelled: isCancelled,
      );
    }
    final result = await channel.invokeMethod<Object?>('decodeToPcm', {
      'path': path,
      'targetSampleRate': 16000,
      'outputDirectory': directory.path,
      'decoderPreference': decoderPreference.name,
      'decoderBackend': decoderBackend.name,
    });
    if (result is! Map ||
        result['path'] is! String ||
        (result['path'] as String).isEmpty) {
      throw const FormatException('Invalid native PCM response');
    }
    final temp = File(result['path'] as String);
    if (!await FileSystemEntity.identical(temp.parent.path, directory.path)) {
      throw const FormatException('Native PCM is outside the job directory');
    }
    try {
      checkAudioCancellation(isCancelled);
      final count = result['count'];
      if (result['sampleRate'] != 16000 ||
          count is! int ||
          count <= 0 ||
          await temp.length() != count * 4) {
        throw const FormatException('Invalid native PCM size or rate');
      }
      return PcmFile(
        temp.path,
        count,
        decoderInfo: AudioDecoderInfo.fromNativeResult(result),
      );
    } catch (_) {
      await _tryDelete(temp);
      rethrow;
    }
  }

  /// Decodes [path] once with [backend] and reports the native decode time,
  /// discarding the PCM. Only Android exposes the backend choice.
  Future<DecodeProbe> decodeProbe(
    String path,
    Directory directory, {
    required AudioDecoderBackend backend,
    bool Function()? isCancelled,
  }) async {
    checkAudioCancellation(isCancelled);
    if (!usesNativeDecoder()) {
      throw UnsupportedError('Decoder comparison needs the Android decoder');
    }
    final result = await channel.invokeMethod<Object?>('decodeToPcm', {
      'path': path,
      'targetSampleRate': decodeProbeSampleRate,
      'outputDirectory': directory.path,
      'decoderBackend': backend.name,
    });
    final tempPath = result is Map ? result['path'] : null;
    final count = result is Map ? result['count'] : null;
    final micros = result is Map ? result['decodeMicros'] : null;
    final temp = tempPath is String && tempPath.isNotEmpty
        ? File(tempPath)
        : null;
    // Never delete a path the native side should not have produced.
    final ours =
        temp != null &&
        await FileSystemEntity.identical(temp.parent.path, directory.path);
    try {
      if (!ours || count is! int || count <= 0 || micros is! int || micros <= 0) {
        throw const FormatException('Invalid native decode probe response');
      }
      return DecodeProbe(
        elapsed: Duration(microseconds: micros),
        frames: count,
        decoder: AudioDecoderInfo.fromNativeResult(result),
      );
    } finally {
      if (ours) await _tryDelete(temp);
    }
  }

  @override
  Future<AudioBuffer> read(String path) async {
    if (usesNativeDecoder()) return _readNative(path);
    return _decodeWavFile(path, decoder);
  }

  /// Cuts one chunk WAV from the raw chain float32 file at [source].
  ///
  /// [spans] are half-open ranges concatenated in order. Android does the
  /// whole cut natively — the same file is read once per window, so a Dart
  /// per-sample pass per window is what made chunking slow.
  Future<void> writeChunkWav(
    String source,
    String destination,
    List<AudioChunk> spans, {
    int sampleRate = 16000,
  }) async {
    if (!usesNativeDecoder()) {
      throw UnsupportedError('Chunk splitting needs the Android decoder');
    }
    final result = await channel.invokeMethod<Object?>('writeWav', {
      'source': source,
      'destination': destination,
      'starts': [for (final span in spans) span.startSampleAt(sampleRate)],
      'ends': [for (final span in spans) span.endSampleAt(sampleRate)],
      'sampleRate': sampleRate,
    });
    if (result is! int ||
        result <= 0 ||
        await File(destination).length() != 44 + result * 2) {
      throw const FormatException('Invalid native chunk write response');
    }
  }

  Future<AudioBuffer> _readNative(String path) async {
    final result = await channel.invokeMethod<Object?>('decodeToPcm', {
      'path': path,
      'targetSampleRate': decoder.targetSampleRate,
    });
    if (result is! Map) {
      throw FormatException(
        'Native decoder returned unexpected result: $result',
      );
    }
    final tempPath = result['path'];
    final sampleRate = result['sampleRate'];
    final count = result['count'];
    if (tempPath is! String ||
        tempPath.isEmpty ||
        sampleRate is! int ||
        sampleRate != decoder.targetSampleRate ||
        count is! int ||
        count < 0) {
      // Malformed reply: still try to remove the temp file so a half-trusting
      // native side cannot leak it into the cache.
      if (tempPath is String && tempPath.isNotEmpty) {
        await _tryDelete(File(tempPath));
      }
      throw FormatException(
        'Native decoder returned an invalid result: $result',
      );
    }
    final temp = File(tempPath);
    try {
      final bytes = await temp.readAsBytes();
      if (bytes.lengthInBytes != count * 4) {
        throw FormatException(
          'Native decoder size mismatch: expected ${count * 4} bytes, got ${bytes.lengthInBytes}',
        );
      }
      // Android is little-endian; the view avoids a second full copy.
      return AudioBuffer(
        samples: Float32List.view(bytes.buffer, bytes.offsetInBytes, count),
        sampleRate: sampleRate,
      );
    } finally {
      await _tryDelete(temp);
    }
  }

  static Future<void> _tryDelete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Best effort — Android evicts its own cache dir eventually.
    }
  }
}

// Capture only the decoder and path, never the platform channel or its owner.
Future<AudioBuffer> _decodeWavFile(String path, WavDecoder decoder) =>
    Isolate.run(() async => decoder.decode(await File(path).readAsBytes()));
