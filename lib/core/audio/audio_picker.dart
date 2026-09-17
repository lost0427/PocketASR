import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

const audioPickerChannel = MethodChannel('pocket_asr/audio_picker');

bool _isAndroid() => Platform.isAndroid;

class PickedAudio {
  const PickedAudio({required this.source, required this.name, this.size});

  /// A local path on desktop, and a persisted content URI on Android.
  final String source;
  final String name;
  final int? size;
}

class AudioPicker {
  const AudioPicker({
    this.channel = audioPickerChannel,
    this.usesUriPicker = _isAndroid,
  });

  final MethodChannel channel;
  final bool Function() usesUriPicker;

  Future<PickedAudio?> pickOne({String typeLabel = 'Audio'}) async {
    if (usesUriPicker()) {
      final result = await channel.invokeMethod<Object?>('pickAudio');
      return result == null ? null : _fromNative(result);
    }
    final file = await openFile(acceptedTypeGroups: [_audioTypes(typeLabel)]);
    return file == null
        ? null
        : PickedAudio(source: file.path, name: file.name);
  }

  Future<List<PickedAudio>> pickMany({String typeLabel = 'Audio'}) async {
    if (usesUriPicker()) {
      final result = await channel.invokeMethod<Object?>('pickAudios');
      if (result is! List) {
        throw const FormatException('Invalid Android audio picker response');
      }
      return [for (final item in result) _fromNative(item)];
    }
    final files = await openFiles(acceptedTypeGroups: [_audioTypes(typeLabel)]);
    return [
      for (final file in files) PickedAudio(source: file.path, name: file.name),
    ];
  }

  static XTypeGroup _audioTypes(String label) =>
      XTypeGroup(label: label, extensions: const ['wav', 'm4a', 'mp3', 'flac']);

  static PickedAudio _fromNative(Object? value) {
    if (value is! Map) {
      throw const FormatException('Invalid Android audio picker response');
    }
    final source = value['uri'];
    final name = value['name'];
    final size = value['size'];
    if (source is! String ||
        source.isEmpty ||
        !source.startsWith('content://') ||
        name is! String ||
        name.isEmpty ||
        (size != null && (size is! int || size < 0))) {
      throw const FormatException('Invalid Android audio picker response');
    }
    return PickedAudio(source: source, name: name, size: size as int?);
  }
}
