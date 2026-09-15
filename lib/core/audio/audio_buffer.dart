import 'dart:typed_data';

class AudioBuffer {
  const AudioBuffer({required this.samples, required this.sampleRate});

  final Float32List samples;
  final int sampleRate;

  Duration get duration => Duration(
    microseconds: (samples.length * 1000000 / sampleRate).round(),
  );
}
