import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/data/db.dart';
import 'package:pocket_asr/data/search_repo.dart';
import 'package:pocket_asr/data/transcript_repo.dart';
import 'package:pocket_asr/features/history/history_page.dart';
import 'package:pocket_asr/l10n/app_localizations.dart';

void main() {
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

  Future<void> pumpHistory(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: HistoryPage(repo: repo, search: search)),
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
}
