import 'dart:io';

import 'audio_buffer.dart';
import 'wav.dart';

abstract interface class AudioSource {
  Future<AudioBuffer> read(String path);
}

class FileAudioSource implements AudioSource {
  const FileAudioSource({this.decoder = const WavDecoder()});

  final WavDecoder decoder;

  @override
  Future<AudioBuffer> read(String path) async {
    final file = File(path);
    if (!await file.exists()) throw FileSystemException('Audio file not found', path);
    return decoder.decode(await file.readAsBytes());
  }
}
