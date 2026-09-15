import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/features/bench/bench_page.dart';
import 'package:pocket_asr/l10n/app_localizations.dart';

void main() {
  testWidgets('shows the CPU matrix and an honest empty state', (tester) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const BenchPage(),
      ),
    );
    await tester.pumpAndSettle();

    // No engine and no fixed sample in this build: the page says exactly that.
    expect(find.text('Nothing can run in this build'), findsOneWidget);
    expect(find.textContaining('native speech engine'), findsOneWidget);
    expect(find.textContaining(benchSampleAsset), findsOneWidget);
    expect(find.textContaining('No performance figure'), findsOneWidget);

    // The whole matrix is listed: 4 families × 2 quants.
    for (final family in benchFamilies) {
      expect(find.text(family), findsNWidgets(benchQuants.length));
    }
    for (final quant in benchQuants) {
      expect(find.text(quant), findsNWidgets(benchFamilies.length));
    }

    // Every cell is blocked, and the results table stays empty.
    expect(
      find.text('Unavailable'),
      findsNWidgets(benchFamilies.length * benchQuants.length),
    );
    expect(find.text('No results yet'), findsOneWidget);

    // The run button exists but is disabled, so it cannot promise numbers.
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });
}
