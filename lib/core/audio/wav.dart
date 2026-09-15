import 'dart:typed_data';

import 'audio_buffer.dart';

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
