import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/app/app_state.dart';
import 'package:pocket_asr/engine/model_catalog.dart';
import 'package:pocket_asr/engine/model_downloader.dart';
import 'package:pocket_asr/features/models/models_page.dart';
import 'package:pocket_asr/l10n/app_localizations.dart';

void main() {
  late Directory dir;
  late LocalModelStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pocket_asr_models_page');
    store = LocalModelStore(dir);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Widget host({
    required List<ModelEntry> entries,
    ModelDownloadRunner? download,
    AppState? state,
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: ModelsPage(
        entries: entries,
        store: store,
        download: download,
        state: state,
      ),
    ),
  );

  /// Puts every file of [entry] on disk with its declared size.
  void download(ModelEntry entry) {
    for (final file in entry.bundleFiles) {
      final target = File(store.pathToFile(entry, file));
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(List.filled(file.sizeBytes ?? 1, 0));
    }
  }

  const whisper = ModelEntry(
    id: 'whisper',
    displayName: 'Whisper Base',
    fileName: 'unused',
    engine: 'sherpa',
    family: 'whisper',
    quant: 'int8',
    languages: ['en', 'zh'],
    license: 'MIT',
    files: [
      ModelFile(fileName: 'enc.onnx', role: 'encoder', sizeBytes: 2),
      ModelFile(fileName: 'dec.onnx', role: 'decoder', sizeBytes: 2),
      ModelFile(fileName: 'tok.txt', role: 'tokens', sizeBytes: 2),
    ],
  );

  testWidgets('offers download only when the entry carries a URL', (
    tester,
  ) async {
    const entries = [
      ModelEntry(
        id: 'a',
        displayName: 'With URL',
        fileName: 'a.onnx',
        url: 'https://example.invalid/a.onnx',
      ),
      ModelEntry(id: 'b', displayName: 'No URL', fileName: 'b.onnx'),
    ];

    await tester.pumpWidget(host(entries: entries));
    await tester.pumpAndSettle();

    expect(find.text('With URL'), findsOneWidget);
    expect(find.text('No URL'), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    expect(find.text('Not downloaded'), findsOneWidget);
    expect(find.text('Not available for download'), findsOneWidget);
  });

  testWidgets('downloaded entry shows its real size and can be deleted', (
    tester,
  ) async {
    const entry = ModelEntry(
      id: 'a',
      displayName: 'Model A',
      fileName: 'a.onnx',
      sizeBytes: 999999, // declared; must not be shown once the file is here
    );
    File(store.pathFor(entry))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(2048, 0));

    await tester.pumpWidget(host(entries: const [entry]));
    await tester.pumpAndSettle();

    expect(find.text('Downloaded'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    // The real size appears twice: the tile detail and the total usage card.
    expect(find.text('2.0 KB'), findsNWidgets(2));
    expect(find.textContaining('977 KB'), findsNothing);
    expect(find.text('On this device'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('Delete downloaded model?'), findsOneWidget);

    // The dialog's Delete is a FilledButton; the tile's is an OutlinedButton.
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    // Deleting is real file I/O, which the fake-async clock does not advance;
    // let it resolve, then render the rebuilt tile.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(store.isDownloaded(entry), isFalse);
    expect(find.text('Downloaded'), findsNothing);
    expect(find.text('Not available for download'), findsOneWidget);
    expect(find.text('0 B'), findsOneWidget);
  });

  testWidgets('download reports progress and can be cancelled', (tester) async {
    const entry = ModelEntry(
      id: 'a',
      displayName: 'Model A',
      fileName: 'a.onnx',
      url: 'https://example.invalid/a.onnx',
    );
    var cancelled = false;

    Future<void> fakeDownload(
      ModelEntry entry, {
      void Function(ModelDownloadProgress progress)? onProgress,
      Future<void>? cancel,
    }) async {
      onProgress?.call(const ModelDownloadProgress(50, 100));
      await cancel;
      cancelled = true;
      throw const HttpException('Download cancelled');
    }

    await tester.pumpWidget(
      host(entries: const [entry], download: fakeDownload),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('Downloading'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(cancelled, isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Not downloaded'), findsOneWidget);
  });

  testWidgets('a downloaded ASR bundle is adopted with its full spec', (
    tester,
  ) async {
    download(whisper);
    final state = AppState();
    addTearDown(state.dispose);

    await tester.pumpWidget(host(entries: const [whisper], state: state));
    await tester.pumpAndSettle();

    // Engine, languages and license come from the allowlist.
    expect(find.textContaining('sherpa'), findsOneWidget);
    expect(find.textContaining('en/zh'), findsOneWidget);
    expect(find.text('MIT'), findsOneWidget);

    await tester.tap(find.text('Use'));
    await tester.pumpAndSettle();

    final spec = state.modelSpec!;
    expect(spec.tokensPath, store.pathToFile(whisper, whisper.files[2]));
    expect(spec.encoderPath, store.pathToFile(whisper, whisper.files[0]));
    expect(spec.decoderPath, store.pathToFile(whisper, whisper.files[1]));
    expect(state.engineId, 'sherpa');
    expect(state.modelFamily, 'whisper');
    expect(state.modelQuant, 'int8');
    // A bundle with its decoder is not treated as unsupported.
    expect(state.selectionNeedsMissingCompanion, isFalse);
    expect(find.text('In use'), findsOneWidget);
  });

  testWidgets('embedding bundles are selected for search, not transcription', (
    tester,
  ) async {
    const asr = ModelEntry(
      id: 'asr',
      displayName: 'Speech',
      fileName: 'a.onnx',
    );
    const embedding = ModelEntry(
      id: 'embed',
      displayName: 'Embedding',
      fileName: 'e.gguf',
      engine: 'crispembed',
      type: 'embedding',
    );
    download(asr);
    download(embedding);
    final state = AppState();
    addTearDown(state.dispose);

    await tester.pumpWidget(
      host(entries: const [asr, embedding], state: state),
    );
    await tester.pumpAndSettle();

    expect(find.text('Speech models'), findsOneWidget);
    expect(find.text('Embedding models'), findsOneWidget);
    // Both kinds can be adopted now: ASR for transcription, embedding for
    // semantic search.
    expect(find.text('Use'), findsNWidgets(2));

    // The embedding bundle becomes the semantic model, never the ASR model.
    await tester.tap(find.text('Use').last);
    await tester.pumpAndSettle();
    expect(state.embeddingPath, store.pathFor(embedding));
    expect(state.modelPath, isNull);
    // This build has no native CrispEmbed library: the page says so rather
    // than silently falling back to the deterministic test embedder.
    expect(state.embeddingReady, isFalse);
    expect(
      find.textContaining('Could not load the embedding model'),
      findsOneWidget,
    );

    // The ASR bundle still selects for transcription.
    await tester.tap(find.text('Use'));
    await tester.pumpAndSettle();
    expect(state.modelPath, store.pathFor(asr));
  });

  testWidgets('deleting the selected bundle clears the selection only', (
    tester,
  ) async {
    const a = ModelEntry(id: 'a', displayName: 'Bundle A', fileName: 'a.onnx');
    const b = ModelEntry(id: 'b', displayName: 'Bundle B', fileName: 'b.onnx');
    download(a);
    download(b);
    final state = AppState();
    addTearDown(state.dispose);
    state.selectModel(spec: store.specFor(a), engineId: 'sherpa');
    expect(state.modelPath, store.pathFor(a));

    await tester.pumpWidget(host(entries: const [a, b], state: state));
    await tester.pumpAndSettle();
    expect(find.text('In use'), findsOneWidget);

    // The first tile is Bundle A; its delete button opens the confirm dialog.
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(state.modelPath, isNull);
    expect(store.isDownloaded(a), isFalse);
    // The other downloaded model is untouched.
    expect(store.isDownloaded(b), isTrue);
    expect(find.text('In use'), findsNothing);
  });

  testWidgets('the Use button is disabled while a run is active', (
    tester,
  ) async {
    download(whisper);
    final state = AppState()..engineBusy = true;
    addTearDown(state.dispose);

    await tester.pumpWidget(host(entries: const [whisper], state: state));
    await tester.pumpAndSettle();

    expect(
      find.text('A transcription is running. Stop it before switching models.'),
      findsOneWidget,
    );
    final use = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Use'),
    );
    expect(use.onPressed, isNull);
  });
}
