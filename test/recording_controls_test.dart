import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/features/transcribe/recording_controls.dart';
import 'package:pocket_asr/l10n/app_localizations.dart';
import 'package:record/record.dart';

class _Recorder implements AudioRecorder {
  bool permission = true;
  bool disposed = false;
  int cancellations = 0;
  String? path;
  RecordConfig? config;
  Completer<void>? starting;

  @override
  Future<bool> hasPermission({bool request = true}) async => permission;
  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    this.config = config;
    this.path = path;
    File(path).writeAsBytesSync(List.filled(46, 0));
    if (starting != null) await starting!.future;
  }

  @override
  Future<String?> stop() async => path;
  @override
  Future<void> cancel() async {
    cancellations++;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late _Recorder recorder;
  late List<bool> busy;
  late List<String> completed;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('recording-test-');
    recorder = _Recorder();
    busy = [];
    completed = [];
  });
  tearDown(() async => root.delete(recursive: true));

  Widget app() => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: RecordingControls(
        enabled: true,
        onBusy: busy.add,
        onRecorded: completed.add,
        recorderFactory: () => recorder,
        directoryProvider: () async => root,
      ),
    ),
  );

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(label));
      // Drain filesystem futures before asserting widget state.
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
        if (busy.isNotEmpty &&
            (label == 'Record audio'
                ? recorder.path != null || !recorder.permission
                : busy.last == false)) {
          break;
        }
      }
    });
    for (var i = 0; i < 10; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
  }

  testWidgets('denied permission never starts or creates audio', (
    tester,
  ) async {
    recorder.permission = false;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tap(tester, 'Record audio');
    expect(recorder.path, isNull);
    expect(busy, [true, false]);
    expect(find.textContaining('Microphone access was denied'), findsOneWidget);
    expect(root.listSync(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'stop selects persistent WAV; discard deletes only new recording',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tap(tester, 'Record audio');
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(recorder.config!.encoder, AudioEncoder.wav);
      expect(recorder.config!.sampleRate, 16000);
      expect(recorder.config!.numChannels, 1);
      await tap(tester, 'Stop and use recording');
      final saved = completed.single;
      expect(File(saved).existsSync(), isTrue);
      await tap(tester, 'Record audio');
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      final discarded = recorder.path!;
      await tap(tester, 'Discard recording');
      expect(File(discarded).existsSync(), isFalse);
      expect(File(saved).existsSync(), isTrue);
      expect(completed, [saved]);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(recorder.disposed, isTrue);
    },
  );

  testWidgets('dispose during start waits then cancels and cleans up', (
    tester,
  ) async {
    recorder.starting = Completer<void>();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tap(tester, 'Record audio');
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      recorder.starting!.complete();
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
        if (recorder.disposed && !await File(recorder.path!).exists()) break;
      }
    });
    for (var i = 0; i < 10; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(recorder.cancellations, 1);
    expect(recorder.disposed, isTrue);
    expect(File(recorder.path!).existsSync(), isFalse);
    expect(completed, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
