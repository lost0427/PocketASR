import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/app/app_state.dart';
import 'package:pocket_asr/engine/model_catalog.dart';
import 'package:pocket_asr/features/models/model_library.dart';
import 'package:pocket_asr/features/models/model_picker.dart';
import 'package:pocket_asr/l10n/app_localizations.dart';

void main() {
  late Directory directory;
  late LocalModelStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('pocket_asr_picker');
    store = LocalModelStore(directory);
  });

  tearDown(() => directory.deleteSync(recursive: true));

  const whisper = ModelEntry(
    id: 'whisper',
    displayName: 'Whisper Base',
    fileName: 'unused',
    engine: 'sherpa',
    family: 'whisper',
    quant: 'int8',
    languages: ['en', 'zh'],
    files: [
      ModelFile(fileName: 'enc.onnx', role: 'encoder', sizeBytes: 2),
      ModelFile(fileName: 'dec.onnx', role: 'decoder', sizeBytes: 2),
      ModelFile(fileName: 'tokens.txt', role: 'tokens', sizeBytes: 2),
    ],
  );
  const incomplete = ModelEntry(
    id: 'incomplete',
    displayName: 'Incomplete speech model',
    fileName: 'model.onnx',
    engine: 'sherpa',
    files: [
      ModelFile(fileName: 'model.onnx', role: 'model', sizeBytes: 2),
      ModelFile(fileName: 'tokens.txt', role: 'tokens', sizeBytes: 2),
    ],
  );
  const vad = ModelEntry(
    id: 'vad',
    displayName: 'Silero VAD',
    fileName: 'vad.onnx',
    family: 'silero',
    type: 'vad',
  );
  const embedding = ModelEntry(
    id: 'embedding',
    displayName: 'Embedding model',
    fileName: 'embed.gguf',
    type: 'embedding',
  );

  void writeFile(ModelEntry entry, ModelFile file) {
    final target = File(store.pathToFile(entry, file));
    target.parent.createSync(recursive: true);
    target.writeAsBytesSync(List.filled(file.sizeBytes ?? 1, 0));
  }

  void download(ModelEntry entry) {
    for (final file in entry.bundleFiles) {
      writeFile(entry, file);
    }
  }

  test('library exposes only complete downloaded speech bundles', () async {
    download(whisper);
    writeFile(incomplete, incomplete.files.first);
    download(vad);
    download(embedding);
    final library = ModelLibrary.fixed(
      entries: const [whisper, incomplete, vad, embedding],
      store: store,
    );

    final data = await library.data;

    expect(data.downloadedAsrModels, const [whisper]);
    expect(data.entryForPath(store.pathFor(whisper)), whisper);
    expect(data.entryForPath(store.pathFor(vad)), isNull);
  });

  testWidgets('picker selects a downloaded bundle with all companions', (
    tester,
  ) async {
    download(whisper);
    writeFile(incomplete, incomplete.files.first);
    download(vad);
    final library = ModelLibrary.fixed(
      entries: const [whisper, incomplete, vad],
      store: store,
    );
    final state = AppState();
    addTearDown(state.dispose);

    await tester.pumpWidget(_host(library: library, state: state));
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();

    expect(find.text('Whisper Base'), findsOneWidget);
    expect(find.text('Incomplete speech model'), findsNothing);
    expect(find.text('Silero VAD'), findsNothing);

    await tester.tap(find.text('Whisper Base'));
    await tester.pumpAndSettle();

    expect(find.text('Whisper Base'), findsOneWidget);
    expect(
      state.modelSpec?.encoderPath,
      store.pathToFile(whisper, whisper.files[0]),
    );
    expect(
      state.modelSpec?.decoderPath,
      store.pathToFile(whisper, whisper.files[1]),
    );
    expect(
      state.modelSpec?.tokensPath,
      store.pathToFile(whisper, whisper.files[2]),
    );
    expect(state.engineId, 'sherpa');
    expect(state.modelFamily, 'whisper');
    expect(state.modelQuant, 'int8');
  });

  testWidgets('empty picker routes to model management', (tester) async {
    var openedModels = false;
    final library = ModelLibrary.fixed(entries: const [], store: store);
    final state = AppState();
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _host(
        library: library,
        state: state,
        onManageModels: () => openedModels = true,
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();

    expect(
      find.text('No downloaded speech models. Download one from Models first.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Open Models'));
    await tester.pumpAndSettle();

    expect(openedModels, isTrue);
    expect(find.text('Choose speech model'), findsNothing);
  });

  testWidgets('picker cannot switch models while the engine is busy', (
    tester,
  ) async {
    download(whisper);
    final library = ModelLibrary.fixed(entries: const [whisper], store: store);
    final state = AppState()..engineBusy = true;
    addTearDown(state.dispose);

    await tester.pumpWidget(_host(library: library, state: state));
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();

    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, 'Whisper Base'),
    );
    expect(tile.enabled, isFalse);
    await tester.tap(find.text('Whisper Base'), warnIfMissed: false);
    expect(state.modelSpec, isNull);
  });
}

Widget _host({
  required ModelLibrary library,
  required AppState state,
  VoidCallback? onManageModels,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Builder(
      builder: (context) => Column(
        children: [
          FilledButton(
            onPressed: () => showDownloadedModelPicker(
              context: context,
              library: library,
              state: state,
              onManageModels: onManageModels,
            ),
            child: const Text('Open picker'),
          ),
          SelectedModelName(
            library: library,
            state: state,
            emptyLabel: 'No model',
          ),
        ],
      ),
    ),
  ),
);
