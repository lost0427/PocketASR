import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/main.dart';

void main() {
  testWidgets('five tabs, and Settings overrides locale + theme', (
    tester,
  ) async {
    await tester.pumpWidget(const PocketAsrApp());

    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(find.text('Transcribe'), findsWidgets);

    // Follow-the-system by default.
    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app().themeMode, ThemeMode.system);
    expect(app().locale, isNull);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('中文'));
    await tester.pumpAndSettle();
    expect(app().locale, const Locale('zh'));
    expect(find.text('设置'), findsWidgets);

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(app().themeMode, ThemeMode.dark);
  });
}
