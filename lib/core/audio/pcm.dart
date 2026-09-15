import 'dart:typed_data';

/// PCM conversion helpers.
///
/// The whole pipeline is mono `Float32List` in [-1, 1]; decoded/recorded audio
/// arrives as little-endian 16-bit PCM. Everything here is little-endian to
/// match the Android side (`AudioDecodeChannel` outputs f32 LE, `record` gives
/// PCM16 LE).

/// PCM16 little-endian bytes -> f32 samples (`byte / 32768`).
///
/// Throws [ArgumentError] if [bytes] has an odd length (not a whole number of
/// 16-bit samples), rather than silently dropping the trailing byte.
Float32List pcm16ToFloat32(Uint8List bytes) {
  if (bytes.lengthInBytes.isOdd) {
    throw ArgumentError.value(
      bytes.lengthInBytes,
      'bytes.lengthInBytes',
      'PCM16 must be an even number of bytes',
    );
  }
  final n = bytes.lengthInBytes >> 1;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    // Assemble as unsigned, then sign-extend, to stay endian-explicit.
    final u = bytes[i * 2] | (bytes[i * 2 + 1] << 8);
    out[i] = (u >= 0x8000 ? u - 0x10000 : u) / 32768.0;
  }
  return out;
}

/// f32 samples -> PCM16 little-endian bytes. Clamps to [-1, 1] first.
Uint8List float32ToPcm16(Float32List samples) {
  final out = Uint8List(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    var v = (samples[i].clamp(-1.0, 1.0) * 32768.0).round();
    if (v > 32767) v = 32767; // only +1.0 can overflow
    out[i * 2] = v & 0xff;
    out[i * 2 + 1] = (v >> 8) & 0xff;
  }
  return out;
}

/// Reinterpret little-endian f32 bytes as samples, without copying.
///
/// Throws [ArgumentError] if [bytes] is not a whole number of 32-bit samples or
/// if its offset into the underlying buffer is not 4-byte aligned, rather than
/// silently truncating or throwing an opaque [RangeError].
///
/// ponytail: host must be little-endian (arm64/x86_64 are). Use [pcm16ToFloat32]
/// for explicitly little-endian PCM16.
Float32List float32FromBytes(Uint8List bytes) {
  if (bytes.lengthInBytes % 4 != 0) {
    throw ArgumentError.value(
      bytes.lengthInBytes,
      'bytes.lengthInBytes',
      'f32 bytes must be a multiple of 4',
    );
  }
  if (bytes.offsetInBytes % 4 != 0) {
    throw ArgumentError.value(
      bytes.offsetInBytes,
      'bytes.offsetInBytes',
      'f32 view must be 4-byte aligned',
    );
  }
  return Float32List.view(
    bytes.buffer,
    bytes.offsetInBytes,
    bytes.lengthInBytes >> 2,
  );
}

/// View f32 samples as raw bytes, without copying.
Uint8List bytesFromFloat32(Float32List samples) =>
    samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes);
