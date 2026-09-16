import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'audio_buffer.dart';
import 'wav.dart';
import 'pcm_file.dart';
import 'ffmpeg_decoder.dart';

abstract interface class AudioSource {
  Future<AudioBuffer> read(String path);
}

/// Mirrors `AudioDecodeChannel.NAME` on the Android side.
const audioDecodeChannel = MethodChannel('pocket_asr/audio_decode');

bool _isAndroid() => Platform.isAndroid;

/// Reads an audio file into a 16 kHz mono [AudioBuffer].
///
/// On non-Android platforms this is the historic [WavDecoder]-only path.
/// On Android the work goes through [channel]: native MediaExtractor +
/// MediaCodec decode/downmix/resample any platform codec (m4a, mp3, flac,
/// wav) and stream the result into a temporary little-endian float32 file;
/// only `{path, sampleRate, count}` crosses the channel — never the raw
/// PCM. The temp file is read back as a zero-copy Float32List view and
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
  Future<PcmFile> decodeToDisk(String path, Directory directory, {
    bool Function()? isCancelled,
  }) async {
    checkAudioCancellation(isCancelled);
    if (!usesNativeDecoder()) {
      return decodeWithFfmpeg(path, '${directory.path}/decoded.f32', isCancelled: isCancelled);
    }
    final result = await channel.invokeMethod<Object?>('decodeToPcm',
      {'path': path, 'targetSampleRate': 16000});
    if (result is! Map || result['path'] is! String) {
      throw const FormatException('Invalid native PCM response');
    }
    final temp = File(result['path'] as String);
    try {
      checkAudioCancellation(isCancelled);
      final count = result['count'];
      if (result['sampleRate'] != 16000 || count is! int || count <= 0 ||
          await temp.length() != count * 4) {
        throw const FormatException('Invalid native PCM size or rate');
      }
      final destination = '${directory.path}/decoded.f32';
      // Cache and job directories may be on different filesystems.
      await temp.copy(destination);
      return PcmFile(destination, count);
    } finally {
      await _tryDelete(temp);
    }
  }

  @override
  Future<AudioBuffer> read(String path) async {
    if (usesNativeDecoder()) return _readNative(path);
    return _decodeWavFile(path, decoder);
  }

  Future<AudioBuffer> _readNative(String path) async {
    final result = await channel.invokeMethod<Object?>(
      'decodeToPcm',
      {'path': path, 'targetSampleRate': decoder.targetSampleRate},
    );
    if (result is! Map) {
      throw FormatException('Native decoder returned unexpected result: $result');
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
      if (tempPath is String && tempPath.isNotEmpty) await _tryDelete(File(tempPath));
      throw FormatException('Native decoder returned an invalid result: $result');
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
