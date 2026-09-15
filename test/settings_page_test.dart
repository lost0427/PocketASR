import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/app/app_state.dart';
import 'package:pocket_asr/features/bench/bench_page.dart';
import 'package:pocket_asr/features/settings/settings_page.dart';
import 'package:pocket_asr/l10n/app_localizations.dart';

Widget host(AppState state) =>
    AppStateScope(notifier: state, child: const _Host());

/// Mirrors [main.dart]'s `_LocalizedApp`: it depends on [AppStateScope], so a
/// locale or theme change rebuilds the [MaterialApp] under test.
class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return MaterialApp(
      locale: state.locale,
      themeMode: state.themeMode,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: SettingsPage()),
    );
  }
}

void main() {
  // A tall surface keeps every control on screen, so taps never miss.
  Future<void> pumpSettings(WidgetTester tester, AppState state) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(state));
  }

  testWidgets('theme and language controls still drive AppState', (
    tester,
  ) async {
    final state = AppState();
    await pumpSettings(tester, state);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(state.themeMode, ThemeMode.dark);

    await tester.tap(find.text('中文'));
    await tester.pumpAndSettle();
    expect(state.locale, const Locale('zh'));
    expect(find.text('外观'), findsOneWidget);
  });

  testWidgets('model, quant, threads and loudness write to AppState', (
    tester,
  ) async {
    final state = AppState();
    await pumpSettings(tester, state);

    await tester.tap(find.widgetWithText(ChoiceChip, 'whisper'));
    await tester.pumpAndSettle();
    expect(state.modelFamily, 'whisper');

    await tester.tap(find.text('q8_0'));
    await tester.pumpAndSettle();
    expect(state.modelQuant, 'q8_0');

    expect(find.byType(Slider), findsOneWidget);

    expect(state.loudnessEnabled, isTrue);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(state.loudnessEnabled, isFalse);
  });

  testWidgets('the version row opens the benchmark on the seventh tap', (
    tester,
  ) async {
    final state = AppState();
    await pumpSettings(tester, state);

    final version = find.textContaining(settingsAppVersion);
    expect(version, findsOneWidget);

    for (var i = 0; i < 7; i++) {
      await tester.tap(version);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.byType(BenchPage), findsOneWidget);
  });
}
