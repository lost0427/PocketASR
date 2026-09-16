import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: ModelsPage(entries: entries, store: store, download: download),
    ),
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
    File(store.pathFor(entry)).writeAsBytesSync(List.filled(2048, 0));

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
}
