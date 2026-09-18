import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/app/app_state.dart';
import 'package:pocket_asr/core/audio/audio_source.dart';
import 'package:pocket_asr/engine/asr_engine.dart';
import 'package:pocket_asr/engine/engine_registry.dart';
import 'package:pocket_asr/engine/model_catalog.dart';
import 'package:pocket_asr/features/bench/bench_page.dart';
import 'package:pocket_asr/features/models/model_library.dart';
import 'package:pocket_asr/features/settings/settings_page.dart';
import 'package:pocket_asr/l10n/app_localizations.dart';

Widget host(AppState state, {ModelLibrary? modelLibrary}) => AppStateScope(
  notifier: state,
  child: _Host(modelLibrary: modelLibrary),
);

/// Mirrors [main.dart]'s `_LocalizedApp`: it depends on [AppStateScope], so a
/// locale or theme change rebuilds the [MaterialApp] under test.
class _Host extends StatelessWidget {
  const _Host({this.modelLibrary});

  final ModelLibrary? modelLibrary;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return MaterialApp(
      locale: state.locale,
      themeMode: state.themeMode,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SettingsPage(modelLibrary: modelLibrary)),
    );
  }
}

void main() {
  // A tall surface keeps every control on screen, so taps never miss.
  Future<void> pumpSettings(
    WidgetTester tester,
    AppState state, {
    ModelLibrary? modelLibrary,
  }) async {
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(state, modelLibrary: modelLibrary));
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

  testWidgets('downloaded model, threads and loudness write to AppState', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    final directory = Directory.systemTemp.createTempSync(
      'pocket_asr_settings',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = LocalModelStore(directory);
    const model = ModelEntry(
      id: 'whisper',
      displayName: 'Whisper Base',
      fileName: 'model.onnx',
      engine: 'sherpa',
      family: 'whisper',
      quant: 'int8',
    );
    File(store.pathFor(model))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    final library = ModelLibrary.fixed(entries: const [model], store: store);
    await pumpSettings(tester, state, modelLibrary: library);

    await tester.tap(find.text('Choose downloaded model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Whisper Base'));
    await tester.pumpAndSettle();

    expect(state.modelFamily, 'whisper');
    expect(state.modelQuant, 'int8');
    expect(find.text('Whisper Base'), findsOneWidget);

    expect(find.byType(Slider), findsWidgets);

    expect(state.loudnessEnabled, isTrue);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(state.loudnessEnabled, isFalse);

    await tester.tap(find.text('Prefer hardware'));
    await tester.pumpAndSettle();
    expect(state.audioDecoderPreference, AudioDecoderPreference.preferHardware);
  });

  testWidgets('the version row opens the benchmark on the seventh tap', (
    tester,
  ) async {
    // An engine override keeps the benchmark off the native worker isolate and
    // its fast probe settles the page in the test's fake-async clock.
    final state = AppState(
      engineRegistry: EngineRegistry(
        asrBuilders: {'sherpa': () => const UnavailableAsrEngine()},
      ),
    );
    await pumpSettings(tester, state);

    final version = find.textContaining(settingsAppVersion);
    expect(version, findsOneWidget);

    for (var i = 0; i < 7; i++) {
      await tester.tap(version);
      await tester.pump();
    }
    // The benchmark route is pushed; its own async setup is left to run (it may
    // show a progress spinner), so pump a frame instead of settling.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(BenchPage), findsOneWidget);
  });

  testWidgets('chunking controls write to AppState and reset to defaults', (
    tester,
  ) async {
    final state = AppState();
    await pumpSettings(tester, state);

    // Switch to energy detection (a loudness gate, never called a neural VAD).
    await tester.ensureVisible(find.text('Energy detection'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Energy detection'));
    await tester.pumpAndSettle();
    expect(state.chunkStrategy, ChunkStrategy.energy);

    state.chunkSeconds = 10;
    await tester.pumpAndSettle();
    expect(state.chunkSeconds, 10);

    await tester.ensureVisible(find.text('Reset chunking'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset chunking'));
    await tester.pumpAndSettle();

    expect(state.chunkStrategy, ChunkStrategy.fixed);
    expect(state.chunkSeconds, AppState.defaultChunkSettings.chunkSeconds);
    expect(
      state.energyThreshold,
      AppState.defaultChunkSettings.energyThreshold,
    );
    expect(state.speechPadMs, AppState.defaultChunkSettings.speechPadMs);
  });
}
