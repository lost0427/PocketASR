import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/features/settings/settings_page.dart';

void main() {
  test('settingsAppVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull);
    expect(settingsAppVersion, match!.group(1));
  });
}
