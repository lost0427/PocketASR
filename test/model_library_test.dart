import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/features/models/model_library.dart';

void main() {
  test('retired bundles are deleted and current bundles are kept', () async {
    final root = Directory.systemTemp.createTempSync('pocket_asr_models');
    addTearDown(() => root.deleteSync(recursive: true));
    final models = Directory('${root.path}${Platform.pathSeparator}models');
    for (final id in ['crispasr-sensevoice-q8', 'crispasr-qwen3-asr-0.6b-q8']) {
      Directory('${models.path}${Platform.pathSeparator}$id')
          .createSync(recursive: true);
    }
    final kept = Directory(
      '${models.path}${Platform.pathSeparator}sherpa-sensevoice-int8',
    )..createSync(recursive: true);
    File('${kept.path}${Platform.pathSeparator}model.int8.onnx')
        .writeAsBytesSync([1]);

    await retireRemovedModelBundles(root.path);

    for (final id in ['crispasr-sensevoice-q8', 'crispasr-qwen3-asr-0.6b-q8']) {
      expect(
        Directory('${models.path}${Platform.pathSeparator}$id').existsSync(),
        isFalse,
      );
    }
    expect(kept.existsSync(), isTrue);
  });
}
