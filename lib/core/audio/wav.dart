import 'dart:typed_data';
import 'dart:io';

import 'audio_buffer.dart';
import 'pcm.dart';

/// Writes bounded PCM blocks, including for a full-length VAD input.
Future<void> writePcm16Wav(File file, Float32List samples, int sampleRate) async {
  if (samples.length > (0xffffffff - 36) ~/ 2) {
    throw ArgumentError('Audio exceeds the RIFF WAV size limit');
  }
  final header = encodePcm16Wav(Float32List(0), sampleRate);
  final fields = ByteData.sublistView(header);
  fields.setUint32(4, 36 + samples.length * 2, Endian.little);
  fields.setUint32(40, samples.length * 2, Endian.little);
  final output = await file.open(mode: FileMode.write);
  try {
    await output.writeFrom(header);
    const blockSamples = 16384;
    for (var start = 0; start < samples.length; start += blockSamples) {
      final end = (start + blockSamples).clamp(0, samples.length);
      await output.writeFrom(float32ToPcm16(Float32List.sublistView(samples, start, end)));
    }
  } finally {
    await output.close();
  }
}

/// Mono 16-bit PCM WAV encoder — the counterpart of [WavDecoder].
///
/// Engines take file paths, so the transcription service uses this to hand a
/// normalized PCM slice (or a whole buffer) to an engine request without
/// re-implementing the RIFF header per caller.
Uint8List encodePcm16Wav(Float32List samples, int sampleRate) {
  if (sampleRate <= 0) {
    throw ArgumentError.value(sampleRate, 'sampleRate', 'must be > 0');
  }
  final payload = float32ToPcm16(samples);
  final out = Uint8List(44 + payload.length);
  final header = ByteData.sublistView(out, 0, 44);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      header.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  header.setUint32(4, 36 + payload.length, Endian.little);
  text(8, 'WAVEfmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, 1, Endian.little); // mono
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  text(36, 'data');
  header.setUint32(40, payload.length, Endian.little);
  out.setRange(44, out.length, payload);
  return out;
}

class WavDecoder {
  const WavDecoder({this.targetSampleRate = 16000});

  final int targetSampleRate;

  AudioBuffer decode(Uint8List bytes) {
    if (targetSampleRate <= 0 || bytes.length < 44) {
      throw const FormatException('Invalid WAV input');
    }
    final view = ByteData.sublistView(bytes);
    if (_text(bytes, 0, 4) != 'RIFF' || _text(bytes, 8, 4) != 'WAVE') {
      throw const FormatException('Expected RIFF/WAVE audio');
    }
    int? format, channels, rate, bits;
    Uint8List? payload;
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = _text(bytes, offset, 4);
      final size = view.getUint32(offset + 4, Endian.little);
      final start = offset + 8;
      final end = start + size;
      if (end > bytes.length) throw const FormatException('Truncated WAV chunk');
      if (id == 'fmt ' && size >= 16) {
        format = view.getUint16(start, Endian.little);
        channels = view.getUint16(start + 2, Endian.little);
        rate = view.getUint32(start + 4, Endian.little);
        bits = view.getUint16(start + 14, Endian.little);
      } else if (id == 'data') {
        payload = Uint8List.sublistView(bytes, start, end);
      }
      offset = end + (size.isOdd ? 1 : 0);
    }
    if (format == null || channels == null || rate == null || bits == null || payload == null) {
      throw const FormatException('WAV is missing fmt or data chunk');
    }
    if (channels <= 0 || rate <= 0 || ![8, 16, 24, 32].contains(bits) ||
        (format != 1 && !(format == 3 && bits == 32))) {
      throw FormatException('Unsupported WAV format $format/$bits-bit');
    }
    final bytesPerSample = (bits + 7) ~/ 8;
    final frameBytes = bytesPerSample * channels;
    if (payload.length % frameBytes != 0) throw const FormatException('WAV data is not frame aligned');
    final frames = payload.length ~/ frameBytes;
    final mono = Float32List(frames);
    final data = ByteData.sublistView(payload);
    for (var frame = 0; frame < frames; frame++) {
      var sum = 0.0;
      for (var channel = 0; channel < channels; channel++) {
        final at = frame * frameBytes + channel * bytesPerSample;
        sum += _sample(data, at, bits, format);
      }
      mono[frame] = (sum / channels).clamp(-1.0, 1.0);
    }
    return AudioBuffer(
      samples: rate == targetSampleRate ? mono : _resample(mono, rate, targetSampleRate),
      sampleRate: targetSampleRate,
    );
  }

  static double _sample(ByteData data, int at, int bits, int format) {
    if (format == 3) return data.getFloat32(at, Endian.little);
    if (bits == 8) return (data.getUint8(at) - 128) / 128.0;
    if (bits == 16) return data.getInt16(at, Endian.little) / 32768.0;
    if (bits == 24) {
      final u = data.getUint8(at) | data.getUint8(at + 1) << 8 | data.getUint8(at + 2) << 16;
      return (u & 0x800000 != 0 ? u - 0x1000000 : u) / 8388608.0;
    }
    return data.getInt32(at, Endian.little) / 2147483648.0;
  }

  static Float32List _resample(Float32List input, int from, int to) {
    if (input.isEmpty) return Float32List(0);
    final length = (input.length * to / from).round();
    final output = Float32List(length);
    for (var i = 0; i < length; i++) {
      final position = i * from / to;
      final left = position.floor().clamp(0, input.length - 1);
      final right = (left + 1).clamp(0, input.length - 1);
      output[i] = input[left] + (input[right] - input[left]) * (position - left);
    }
    return output;
  }

  static String _text(Uint8List bytes, int start, int length) =>
      String.fromCharCodes(bytes.sublist(start, start + length));
}
