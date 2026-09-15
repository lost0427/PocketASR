import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/features/transcribe/transcribe_page.dart';
import 'package:pocket_asr/l10n/app_localizations.dart';

Widget _app({Locale? locale}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: const Scaffold(body: TranscribePage()),
);

void main() {
  testWidgets('reports the engine as unavailable instead of faking a result', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('On-device engine unavailable'), findsOneWidget);
    expect(find.text('Not selected'), findsOneWidget);

    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start transcription'),
    );
    expect(start.onPressed, isNull);

    final copy = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Copy'),
    );
    expect(copy.onPressed, isNull);

    // No backend and no metrics are known, so they stay blank rather than
    // showing an invented number.
    expect(find.text('—'), findsWidgets);
    expect(find.text('The transcript will appear here.'), findsOneWidget);
  });

  testWidgets('file picker is an honest placeholder', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose audio file'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('File picking is not wired up yet.'), findsOneWidget);
  });

  testWidgets('localizes the unavailable state to Chinese', (tester) async {
    await tester.pumpWidget(_app(locale: const Locale('zh')));
    await tester.pumpAndSettle();

    expect(find.text('本地引擎不可用'), findsOneWidget);
    expect(find.text('开始转录'), findsOneWidget);
  });
}
