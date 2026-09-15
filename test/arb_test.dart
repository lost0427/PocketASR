import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards against a translation being added to one locale only.
void main() {
  test('en and zh ARB files define the same message keys', () {
    Set<String> keys(String path) {
      final json =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      return json.keys
          .where((key) => !key.startsWith('@@') && !key.startsWith('@'))
          .toSet();
    }

    final en = keys('lib/l10n/app_en.arb');
    final zh = keys('lib/l10n/app_zh.arb');

    expect(zh.difference(en), isEmpty, reason: 'zh has keys en lacks');
    expect(en.difference(zh), isEmpty, reason: 'en has keys zh lacks');
  });
}
