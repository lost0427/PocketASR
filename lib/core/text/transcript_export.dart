import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// One plain-text transcript to write to disk.
class TranscriptExport {
  const TranscriptExport({required this.fileName, required this.text});

  /// Suggested file name, including the `.txt` extension.
  final String fileName;
  final String text;
}

const _textExportChannel = MethodChannel('pocket_asr/text_export');

/// Saves one transcript as plain text. Returns true when written, false when
/// the user cancelled the picker.
Future<bool> saveTranscriptTxt(String suggestedName, String text) async {
  if (Platform.isAndroid) {
    final saved = await _textExportChannel.invokeMethod<bool>('saveText', {
      'suggestedName': suggestedName,
      'text': text,
    });
    return saved == true;
  }
  final location = await getSaveLocation(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Text', extensions: ['txt']),
    ],
    suggestedName: suggestedName,
  );
  if (location == null) return false;
  await File(location.path).writeAsString(text);
  return true;
}

/// Saves several transcripts into one user-chosen folder. Returns the number
/// written, or null when the user cancelled the directory picker.
Future<int?> saveTranscriptTxts(List<TranscriptExport> files) async {
  if (files.isEmpty) return 0;
  if (Platform.isAndroid) {
    return _textExportChannel.invokeMethod<int>('saveTexts', {
      'files': [
        for (final file in files)
          {'suggestedName': file.fileName, 'text': file.text},
      ],
    });
  }
  final directory = await getDirectoryPath();
  if (directory == null) return null;
  final used = <String>{};
  var saved = 0;
  for (final file in files) {
    final path = _uniquePath(directory, file.fileName, used);
    await File(path).writeAsString(file.text);
    saved++;
  }
  return saved;
}

/// Refuses to overwrite an existing file: `note.txt`, `note (2).txt`, …
String _uniquePath(String directory, String fileName, Set<String> used) {
  final separator = Platform.pathSeparator;
  final stem = fileName.replaceFirst(
    RegExp(r'\.txt$', caseSensitive: false),
    '',
  );
  var candidate = '$directory$separator$fileName';
  var index = 2;
  while (used.contains(candidate.toLowerCase()) ||
      File(candidate).existsSync()) {
    candidate = '$directory$separator$stem ($index).txt';
    index++;
  }
  used.add(candidate.toLowerCase());
  return candidate;
}
