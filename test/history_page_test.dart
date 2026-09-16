import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/data/db.dart';
import 'package:pocket_asr/data/search_repo.dart';
import 'package:pocket_asr/data/semantic_indexer.dart';
import 'package:pocket_asr/data/transcript_repo.dart';
import 'package:pocket_asr/engine/embedder.dart';
import 'package:pocket_asr/features/history/history_page.dart';
import 'package:pocket_asr/l10n/app_localizations.dart';

/// Records the query texts it is asked to embed; no native library needed.
class _QueryEmbedder implements Embedder {
  @override
  final String id = 'fake-embedder';
  @override
  final int dim = 2;

  final List<String> queries = [];

  @override
  Float32List embed(String text) => Float32List.fromList([1, 0]);

  @override
  Float32List embedDocument(String text) => Float32List.fromList([1, 0]);

  @override
  Float32List embedQuery(String text) {
    queries.add(text);
    return Float32List.fromList([1, 0]);
  }

  @override
  Future<void> dispose() async {}
}

/// Query embeds where 'slow' takes 300ms of worker time and lands on Beta,
/// anything else resolves immediately and lands on Alpha — enough to tell a
/// fresh result from a stale one by list order alone.
class _StaleQueryEmbedder implements Embedder {
  _StaleQueryEmbedder();

  @override
  final String id = 'stale-embedder';
  @override
  final int dim = 2;

  final List<String> queries = [];

  @override
  Float32List embed(String text) => embedDocument(text);

  @override
  Float32List embedDocument(String text) =>
      text.startsWith('alpha') ? _v(1, 0) : _v(0, 1);

  @override
  FutureOr<Float32List> embedQuery(String text) {
    queries.add(text);
    return text == 'slow'
        ? Future<Float32List>.delayed(
            const Duration(milliseconds: 300),
            () => _v(0, 1),
          )
        : _v(1, 0);
  }

  @override
  Future<void> dispose() async {}
}

Float32List _v(double a, double b) => Float32List.fromList([a, b]);

void main() {
  bool alphaAboveBeta(WidgetTester tester) =>
      tester.getTopLeft(find.text('Alpha')).dy <
      tester.getTopLeft(find.text('Beta')).dy;

  /// The runs a text widget marks as a literal hit (the bold accent spans)
  /// inside the widget whose plain text is exactly [plain]. Empty when that
  /// text is unmarked.
  List<String> marksFor(WidgetTester tester, String plain) {
    final widget = tester.widget<Text>(
      find.byWidgetPredicate(
        (w) => w is Text && w.textSpan?.toPlainText() == plain,
      ),
    );
    final span = widget.textSpan! as TextSpan;
    return [
      for (final child in span.children!.whereType<TextSpan>())
        if (child.style?.fontWeight == FontWeight.w600) child.text ?? '',
    ];
  }

  late AppDatabase db;
  late TranscriptRepo repo;
  late SearchRepo search;

  setUp(() {
    db = AppDatabase.open();
    repo = TranscriptRepo(db);
    search = SearchRepo(db);
  });

  tearDown(() {
    repo.dispose();
    db.close();
  });

  Future<void> pumpHistory(
    WidgetTester tester, {
    SearchRepo? searchRepo,
    SemanticIndexer? indexer,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: HistoryPage(
            repo: repo,
            search: searchRepo ?? search,
            indexer: indexer,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a new transcript shows up without a manual refresh', (
    tester,
  ) async {
    await pumpHistory(tester);
    expect(find.text('No transcripts'), findsOneWidget);

    // The transcribe/queue pages write straight to the repo; the listener is
    // what makes the row appear here.
    repo.insert(title: 'Meeting', text: 'hello world');
    await tester.pumpAndSettle();

    expect(find.text('Meeting'), findsOneWidget);
    expect(find.text('hello world'), findsOneWidget);
    expect(find.text('No transcripts'), findsNothing);
  });

  testWidgets('detail shows the full text and the real recorded stats', (
    tester,
  ) async {
    repo.insert(
      title: 'Meeting',
      text: 'the whole transcript body that is longer than a list preview',
      engine: 'fake',
      backend: 'cpu',
      modelPath: 'models/m.onnx',
      rtf: 4.0,
      tokens: 12,
      avgTokensPerSec: 6.0,
      audioSeconds: 2.5,
    );
    await pumpHistory(tester);

    await tester.tap(find.text('Meeting'));
    await tester.pumpAndSettle();

    expect(find.text('Transcript'), findsOneWidget); // detail app bar
    expect(
      find.text('the whole transcript body that is longer than a list preview'),
      findsOneWidget,
    );
    expect(find.text('fake'), findsOneWidget);
    expect(find.text('cpu'), findsOneWidget);
    expect(find.text('m.onnx'), findsOneWidget);
    expect(find.text('4.00'), findsOneWidget); // rtf
    expect(find.text('6.0'), findsOneWidget); // tokens/s
    expect(find.text('2.5 s'), findsOneWidget);
  });

  testWidgets('detail shows the recorded total wall clock', (tester) async {
    repo.insert(title: 'Meeting', text: 'body', totalMs: 2500);
    await pumpHistory(tester);

    await tester.tap(find.text('Meeting'));
    await tester.pumpAndSettle();

    // Same label and shape as the transcribe page's elapsed metric.
    expect(find.text('Elapsed'), findsOneWidget);
    expect(find.text('2.5s'), findsOneWidget);
  });

  testWidgets('a literal search marks only the words that really match', (
    tester,
  ) async {
    repo.insert(title: 'Meeting', text: 'hello world');
    await pumpHistory(tester);

    // Upper-case query, lower-case text: matching is case-insensitive and the
    // original casing is kept.
    await tester.enterText(find.byType(TextField), 'WORLD');
    await tester.pumpAndSettle();

    expect(marksFor(tester, 'hello world'), ['world']);
    // The body still reads as one string; only its styling is split.
    expect(find.text('hello world'), findsOneWidget);
  });

  testWidgets('semantic results are never dressed up as literal hits', (
    tester,
  ) async {
    final embedder = _QueryEmbedder();
    final indexer = SemanticIndexer(db, embedder: embedder);
    addTearDown(indexer.dispose);
    final semanticSearch = SearchRepo(db, embedder: embedder);

    repo.insert(title: 'WiFi', text: 'connect to the wifi network');
    await tester.runAsync(() => indexer.indexPending());
    await pumpHistory(tester, searchRepo: semanticSearch, indexer: indexer);

    await tester.enterText(find.byType(TextField), 'wifi network');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Semantic'));
    await tester.pumpAndSettle();

    expect(find.text('WiFi'), findsOneWidget);
    // The query words are present, but this was not a literal search.
    expect(marksFor(tester, 'connect to the wifi network'), isEmpty);
  });

  testWidgets('copy puts the transcript on the clipboard', (tester) async {
    final copied = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    repo.insert(title: 'Meeting', text: 'copy me');
    await pumpHistory(tester);

    await tester.tap(find.text('Meeting'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Copy'));
    await tester.pumpAndSettle();

    expect(copied, ['copy me']);
    expect(find.text('Copied to clipboard'), findsOneWidget);
  });

  testWidgets('a marked search result still copies the plain original text', (
    tester,
  ) async {
    final copied = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    repo.insert(title: 'Meeting', text: 'hello world');
    await pumpHistory(tester);
    await tester.enterText(find.byType(TextField), 'world');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Meeting'));
    await tester.pumpAndSettle();

    // The full text is intact behind the marks, and that is what gets copied.
    expect(find.text('hello world'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy'));
    await tester.pumpAndSettle();
    expect(copied, ['hello world']);
  });

  testWidgets('trash scope lists only trashed rows, purge asks first', (
    tester,
  ) async {
    final live = repo.insert(title: 'Live', text: 'still here');
    final trashed = repo.insert(title: 'Deleted', text: 'in the bin');
    repo.softDelete(trashed);
    await pumpHistory(tester);

    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Deleted'), findsNothing);

    await tester.tap(find.text('Trash'));
    await tester.pumpAndSettle();
    expect(find.text('Deleted'), findsOneWidget);
    expect(find.text('Live'), findsNothing); // onlyTrash, no live leak

    // Permanent delete is confirmed, not silent.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete permanently').last);
    await tester.pumpAndSettle();
    expect(find.text('Delete permanently?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
    await tester.pumpAndSettle();

    expect(repo.listTrash(), isEmpty);
    expect(repo.list().map((t) => t.id), [live]);
    expect(find.text('Trash is empty'), findsOneWidget);
  });

  testWidgets('move to trash and restore round-trip through the repo', (
    tester,
  ) async {
    repo.insert(title: 'Meeting', text: 'text');
    await pumpHistory(tester);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to trash'));
    await tester.pumpAndSettle();
    expect(find.text('Meeting'), findsNothing); // gone from history

    await tester.tap(find.text('Trash'));
    await tester.pumpAndSettle();
    expect(find.text('Meeting'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(find.text('Trash is empty'), findsOneWidget);
    expect(repo.list(), hasLength(1));
  });

  testWidgets('semantic mode really embeds the query through the repo', (
    tester,
  ) async {
    final embedder = _QueryEmbedder();
    final indexer = SemanticIndexer(db, embedder: embedder);
    addTearDown(indexer.dispose);
    final semanticSearch = SearchRepo(db, embedder: embedder);

    repo.insert(title: 'WiFi', text: 'connect to the wifi network');
    // Indexing yields on a real timer, which the widget-test clock does not
    // advance; run it outside the fake-async zone.
    await tester.runAsync(() => indexer.indexPending());
    await pumpHistory(
      tester,
      searchRepo: semanticSearch,
      indexer: indexer,
    );

    // The indexing status row offers a rebuild seam.
    expect(find.text('Rebuild index'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'wifi network');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Semantic'));
    await tester.pumpAndSettle();

    expect(embedder.queries, ['wifi network']); // the real search seam
    expect(find.text('WiFi'), findsOneWidget);
  });

  testWidgets('a superseded semantic query cannot overwrite newer results', (
    tester,
  ) async {
    final embedder = _StaleQueryEmbedder();
    final indexer = SemanticIndexer(db, embedder: embedder);
    addTearDown(indexer.dispose);
    final semanticSearch = SearchRepo(db, embedder: embedder);

    repo.insert(title: 'Alpha', text: 'alpha one');
    repo.insert(title: 'Beta', text: 'beta two');
    await tester.runAsync(() => indexer.indexPending());
    await pumpHistory(
      tester,
      searchRepo: semanticSearch,
      indexer: indexer,
    );

    await tester.tap(find.text('Semantic'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'slow');
    await tester.pump(); // query 1 is now in flight (its 300ms has not elapsed)
    await tester.enterText(find.byType(TextField), 'fast');
    await tester.pump();
    await tester.pump(); // render the fresh answer

    // The fresh query ranked Alpha first (cosine 1 against [1, 0]).
    expect(alphaAboveBeta(tester), isTrue);

    // Let the stale 'slow' answer land: it must be dropped, not applied.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(embedder.queries, ['slow', 'fast']);
    expect(alphaAboveBeta(tester), isTrue);
  });

  testWidgets('a semantic result landing after dispose is dropped', (
    tester,
  ) async {
    final embedder = _StaleQueryEmbedder();
    final indexer = SemanticIndexer(db, embedder: embedder);
    addTearDown(indexer.dispose);
    final semanticSearch = SearchRepo(db, embedder: embedder);

    repo.insert(title: 'Alpha', text: 'alpha one');
    await tester.runAsync(() => indexer.indexPending());
    await pumpHistory(
      tester,
      searchRepo: semanticSearch,
      indexer: indexer,
    );
    await tester.tap(find.text('Semantic'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'slow');
    await tester.pump(const Duration(milliseconds: 100));

    // Tear the page down mid-query; when the embed lands there is no State.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('semantic modes are disabled and explained without an embedder', (
    tester,
  ) async {
    await pumpHistory(tester);

    expect(
      find.text('Select a downloaded embedding model to enable semantic search.'),
      findsOneWidget,
    );
    // Literal-only still works; the semantic segment cannot be selected.
    expect(find.text('Literal'), findsOneWidget);
    expect(find.text('Rebuild index'), findsNothing);
  });
}
