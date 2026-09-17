import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/app/app_state.dart';
import 'package:pocket_asr/core/audio/chunk_planner.dart';
import 'package:pocket_asr/data/db.dart';
import 'package:pocket_asr/data/transcript_repo.dart';
import 'package:pocket_asr/engine/asr_engine.dart';
import 'package:pocket_asr/engine/engine_registry.dart';
import 'package:pocket_asr/engine/model_catalog.dart';
import 'package:pocket_asr/features/bench/bench_page.dart';
import 'package:pocket_asr/features/models/models_page.dart';
import 'package:pocket_asr/features/queue/queue_page.dart';
import 'package:pocket_asr/features/settings/settings_page.dart';
import 'package:pocket_asr/features/transcribe/transcribe_page.dart';
import 'package:pocket_asr/features/transcribe/transcription_service.dart';
import 'package:pocket_asr/l10n/app_localizations.dart';

/// Available engine that counts native calls, so a test can prove the page
/// never loaded or transcribed ASR while previewing VAD.
class _CountingEngine extends UnavailableAsrEngine {
  int loadCalls = 0;
  int transcribeCalls = 0;

  @override
  String get id => 'counting';

  @override
  Future<List<Backend>> availableBackends() async => const [Backend.cpu];

  @override
  Future<EngineCapabilities> capabilities() async =>
      const EngineCapabilities(available: true, backends: {Backend.cpu});

  @override
  Future<void> load(EngineModelSpec spec, Backend backend) async => loadCalls++;

  @override
  Stream<TranscribeProgress> transcribe(TranscribeRequest request) {
    transcribeCalls++;
    return const Stream<TranscribeProgress>.empty();
  }
}

/// Cancellable stand-in for the independent VAD worker.
class _FakeVadEngine extends UnavailableAsrEngine
    implements CancellableAsrEngine {
  int cancelCalls = 0;
  bool disposed = false;

  @override
  String get id => 'sherpa-vad-fake';

  @override
  Future<void> cancel() async => cancelCalls++;

  @override
  Future<void> dispose() async => disposed = true;
}

/// Records what the transcribe/queue/bench flows hand the service, and answers
/// previewVad from a canned plan without touching any engine.
class _RecordingService extends TranscriptionService {
  _RecordingService() : super(engine: const UnavailableAsrEngine());

  int transcribeCalls = 0;
  int previewCalls = 0;
  ChunkSettings? lastChunkSettings;
  NeuralVadSettings? lastNeuralVad;
  NeuralVadSettings? lastPreviewSettings;
  bool Function()? lastPreviewIsCancelled;

  final VadPreview preview = VadPreview(
    windows: [
      [
        AudioChunk(
          start: Duration.zero,
          end: const Duration(milliseconds: 1100),
        ),
      ],
      [
        AudioChunk(
          start: const Duration(milliseconds: 1900),
          end: const Duration(milliseconds: 3100),
        ),
      ],
    ],
    sampleRate: 16000,
  );

  @override
  Future<TranscriptionJobResult> transcribe({
    required String audioPath,
    required EngineModelSpec model,
    Backend backend = Backend.cpu,
    String? language,
    ChunkSettings? chunkSettings,
    NeuralVadSettings? neuralVad,
    void Function(TranscriptionStage stage)? onStage,
    void Function(TranscribeProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    transcribeCalls++;
    lastChunkSettings = chunkSettings;
    lastNeuralVad = neuralVad;
    return TranscriptionJobResult(
      text: 'ok',
      elapsed: const Duration(milliseconds: 10),
      audioDuration: const Duration(milliseconds: 10),
      engine: 'fake',
      model: model,
      backend: backend,
      originalLufs: -16,
      gainDb: 0,
    );
  }

  @override
  Future<VadPreview> previewVad({
    required String audioPath,
    required NeuralVadSettings neuralVad,
    bool Function()? isCancelled,
  }) async {
    previewCalls++;
    lastPreviewSettings = neuralVad;
    lastPreviewIsCancelled = isCancelled;
    return preview;
  }
}

/// Blocks until cancelled, like a native VAD plan or ASR call in flight.
class _BlockingService extends TranscriptionService {
  _BlockingService() : super(engine: const UnavailableAsrEngine());

  @override
  Future<TranscriptionJobResult> transcribe({
    required String audioPath,
    required EngineModelSpec model,
    Backend backend = Backend.cpu,
    String? language,
    ChunkSettings? chunkSettings,
    NeuralVadSettings? neuralVad,
    void Function(TranscriptionStage stage)? onStage,
    void Function(TranscribeProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    while (!(isCancelled?.call() ?? false)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    throw const EngineCancelledException('stopped');
  }
}

const MethodChannel _selectorChannel = MethodChannel(
  'plugins.flutter.io/file_selector',
);

/// Answers the file selector with [paths], one pick per call.
void _mockPicker(WidgetTester tester, List<String> paths) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var index = 0;
  messenger.setMockMethodCallHandler(_selectorChannel, (call) async {
    if (call.method == 'openFile') {
      return index < paths.length ? [paths[index++]] : null;
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_selectorChannel, null));
}

Widget _transcribeApp({
  required AppState state,
  required AsrEngine engine,
  required TranscriptionService service,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: TranscribePage(
      engine: engine,
      state: state,
      transcriptRepo: TranscriptRepo(AppDatabase.open()),
      service: service,
    ),
  ),
);

Widget _queueApp({
  required AppState state,
  required TranscriptionService service,
  AsrEngine engine = const UnavailableAsrEngine(),
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: QueuePage(
      engine: engine,
      transcriptRepo: TranscriptRepo(AppDatabase.open()),
      state: state,
      service: service,
    ),
  ),
);

/// Settings host mirroring `main.dart`'s localized app.
Widget _settingsHost(AppState state) =>
    AppStateScope(notifier: state, child: const _SettingsHost());

class _SettingsHost extends StatelessWidget {
  const _SettingsHost();

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
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('pocket_asr_neural'));
  tearDown(() => dir.deleteSync(recursive: true));

  String write(String name) {
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync([1, 2, 3]);
    return file.path;
  }

  group('AppState', () {
    test('persists the VAD model and knobs, and reset restores defaults', () {
      final db = AppDatabase.open();
      addTearDown(db.close);
      final model = write('ten-vad.int8.onnx');

      AppState(database: db)
        ..selectVad(path: model, family: VadModelFamily.ten)
        ..chunkStrategy = ChunkStrategy.neural
        ..vadThreshold = 0.7
        ..vadMinSilenceSeconds = 1.2
        ..vadMinSpeechSeconds = 0.4
        ..vadPadMs = 80
        ..vadMaxSeconds = 12;

      final restored = AppState(database: db);
      expect(restored.vadModelPath, model);
      expect(restored.vadModelFamily, VadModelFamily.ten);
      expect(restored.chunkStrategy, ChunkStrategy.neural);
      expect(restored.vadThreshold, 0.7);
      expect(restored.vadMinSilenceSeconds, 1.2);
      expect(restored.vadMinSpeechSeconds, 0.4);
      expect(restored.vadPadMs, 80);
      expect(restored.vadMaxSeconds, 12);

      // Neural mode hands the service real VAD settings and *no* chunk
      // settings; the two are mutually exclusive.
      expect(restored.chunkSettings, isNull);
      final vad = restored.neuralVadSettings!;
      expect(vad.modelPath, model);
      expect(vad.family, VadModelFamily.ten);
      expect(vad.threshold, 0.7);
      expect(vad.minSilenceDuration, 1.2);
      expect(vad.minSpeechDuration, 0.4);
      expect(vad.speechPadMs, 80);
      expect(vad.maxSpeechSeconds, 12);

      restored.resetChunkSettings();
      expect(restored.chunkStrategy, ChunkStrategy.fixed);
      expect(restored.vadThreshold, AppState.defaultVadThreshold);
      expect(restored.vadMinSilenceSeconds, AppState.defaultVadMinSilence);
      expect(restored.vadPadMs, AppState.defaultVadPadMs);
      expect(restored.vadMaxSeconds, AppState.defaultVadMaxSeconds);
      // Fixed mode gives chunk settings back, and VAD settings go away.
      expect(restored.chunkSettings, isNotNull);
      expect(restored.neuralVadSettings, isNull);
    });

    test('neural mode without a model is not ready and yields no settings', () {
      final db = AppDatabase.open();
      addTearDown(db.close);
      final state = AppState(database: db)
        ..chunkStrategy = ChunkStrategy.neural;

      expect(state.neuralVadReady, isFalse);
      expect(state.neuralVadSettings, isNull);
      // Crucially not a silent downgrade to the whole-file path.
      expect(state.chunkSettings, isNull);
      expect(state.activeVadEngine, isNull);
    });

    test('a vanished VAD file is flagged and disables neural mode', () {
      final db = AppDatabase.open();
      addTearDown(db.close);
      final path = write('gone.onnx');
      AppState(database: db).selectVad(path: path);
      File(path).deleteSync();

      final restored = AppState(database: db);
      expect(restored.vadModelPath, isNull);
      expect(restored.vadSelectionMissing, isTrue);
      expect(restored.neuralVadReady, isFalse);
    });

    test('cancelVad cancels the worker and resetVadEngine replaces it', () async {
      final db = AppDatabase.open();
      addTearDown(db.close);
      final built = <_FakeVadEngine>[];
      final state = AppState(
        database: db,
        engineRegistry: EngineRegistry(
          asrBuilders: {
            'sherpa': () {
              final engine = _FakeVadEngine();
              built.add(engine);
              return engine;
            },
          },
        ),
      )
        ..chunkStrategy = ChunkStrategy.neural
        ..selectVad(path: 'silero.onnx');

      // Nothing cancelled yet: reset is a no-op and keeps the same worker.
      final first = state.activeVadEngine;
      expect(first, isNotNull);
      state.resetVadEngine();
      expect(state.activeVadEngine, same(first));
      expect(built, hasLength(1));

      await state.cancelVad();
      expect(built.single.cancelCalls, 1);

      // A cancelled worker is dropped: the next use builds a fresh one, which
      // is what makes a retry work even though planVad never reloads.
      state.resetVadEngine();
      expect(built.single.disposed, isTrue);
      expect(state.activeVadEngine, isNot(same(first)));
      expect(built, hasLength(2));
    });
  });

  group('Settings', () {
    Future<void> pumpSettings(WidgetTester tester, AppState state) async {
      tester.view.physicalSize = const Size(1200, 4800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_settingsHost(state));
      await tester.pumpAndSettle();
    }

    testWidgets('offers the three modes and the neural VAD knobs', (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await pumpSettings(tester, state);

      await tester.ensureVisible(find.text('Neural VAD'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Neural VAD'));
      await tester.pumpAndSettle();

      expect(state.chunkStrategy, ChunkStrategy.neural);
      // The VAD controls are replaced in, and the missing model is called out.
      expect(find.text('VAD model'), findsOneWidget);
      expect(find.text('Speech threshold'), findsOneWidget);
      expect(find.text('Min silence'), findsOneWidget);
      expect(find.text('Min speech'), findsOneWidget);
      expect(find.text('Max speech'), findsOneWidget);
      expect(
        find.text('Select a downloaded VAD model in the Models tab to use neural VAD.'),
        findsOneWidget,
      );

      state.vadThreshold = 0.8;
      state.vadMaxSeconds = 20;
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Reset chunking'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset chunking'));
      await tester.pumpAndSettle();

      expect(state.chunkStrategy, ChunkStrategy.fixed);
      expect(state.vadThreshold, AppState.defaultVadThreshold);
      expect(state.vadMaxSeconds, AppState.defaultVadMaxSeconds);
    });
  });

  group('Models', () {
    testWidgets('a VAD bundle is adopted for neural VAD, never as ASR', (
      tester,
    ) async {
      const asr = ModelEntry(id: 'asr', displayName: 'Speech', fileName: 'a.onnx');
      const vad = ModelEntry(id: 'vad', displayName: 'TEN', fileName: 'v.onnx', family: 'ten', type: 'vad');
      final store = LocalModelStore(dir);
      for (final entry in [asr, vad]) {
        File(store.pathFor(entry))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync([0, 0]);
      }
      final state = AppState();
      addTearDown(state.dispose);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ModelsPage(
              entries: const [asr, vad],
              store: store,
              state: state,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Its own section, so a VAD model is never mistaken for a speech model.
      expect(find.text('Speech models'), findsOneWidget);
      expect(find.text('VAD models'), findsOneWidget);

      // Select the ASR bundle first; the VAD tile still offers its own Use.
      await tester.tap(find.text('Use').first);
      await tester.pumpAndSettle();
      expect(state.modelPath, store.pathFor(asr));
      expect(state.vadModelPath, isNull);

      // The remaining Use is the VAD tile: it changes only the VAD selection.
      await tester.tap(find.text('Use'));
      await tester.pumpAndSettle();
      expect(state.vadModelPath, store.pathFor(vad));
      expect(state.vadModelFamily, VadModelFamily.ten);
      expect(state.modelPath, store.pathFor(asr)); // untouched

      // Deleting the VAD bundle clears only the VAD selection.
      await tester.tap(find.byIcon(Icons.delete_outline).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();

      expect(state.vadModelPath, isNull);
      expect(state.vadModelFamily, VadModelFamily.silero);
      expect(state.modelPath, store.pathFor(asr));
      expect(store.isDownloaded(vad), isFalse);
    });
  });

  group('Transcribe', () {
    testWidgets('sends NeuralVadSettings and previews without any ASR', (
      tester,
    ) async {
      _mockPicker(tester, ['meeting.wav']);
      final state = AppState()
        ..modelPath = 'model.onnx'
        ..chunkStrategy = ChunkStrategy.neural
        ..vadThreshold = 0.65
        ..vadPadMs = 50
        ..selectVad(path: 'silero.onnx');
      addTearDown(state.dispose);

      final engine = _CountingEngine();
      final service = _RecordingService();
      await tester.pumpWidget(
        _transcribeApp(state: state, engine: engine, service: service),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Choose audio file').first);
      await tester.pumpAndSettle();

      // Preview runs real VAD and shows the windows it found — no ASR at all.
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(service.previewCalls, 1);
      expect(service.lastPreviewSettings!.threshold, 0.65);
      expect(service.lastPreviewSettings!.speechPadMs, 50);
      expect(service.lastPreviewIsCancelled, isNotNull);
      expect(engine.loadCalls, 0);
      expect(engine.transcribeCalls, 0);
      expect(find.text('Window 1'), findsOneWidget);
      expect(find.text('Window 2'), findsOneWidget);
      expect(find.text('0.00 – 1.10 s'), findsOneWidget);
      expect(find.text('1.90 – 3.10 s'), findsOneWidget);

      // Starting the job hands the same settings and no chunk settings.
      await tester.ensureVisible(find.text('Start transcription'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start transcription'));
      await tester.pumpAndSettle();
      expect(service.transcribeCalls, 1);
      expect(service.lastNeuralVad!.threshold, 0.65);
      expect(service.lastNeuralVad!.modelPath, 'silero.onnx');
      expect(service.lastChunkSettings, isNull);
    });

    testWidgets('blocks neural mode when no VAD model is selected', (
      tester,
    ) async {
      _mockPicker(tester, ['meeting.wav']);
      final state = AppState()
        ..modelPath = 'model.onnx'
        ..chunkStrategy = ChunkStrategy.neural;
      addTearDown(state.dispose);

      await tester.pumpWidget(
        _transcribeApp(
          state: state,
          engine: _CountingEngine(),
          service: _RecordingService(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Choose audio file').first);
      await tester.pumpAndSettle();

      expect(
        find.text('Select a downloaded VAD model in the Models tab to use neural VAD.'),
        findsOneWidget,
      );
      final start = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Start transcription'),
      );
      expect(start.onPressed, isNull);
    });
  });

  group('Queue', () {
    testWidgets('runs neural VAD with the shared settings and no chunking', (
      tester,
    ) async {
      _mockPicker(tester, ['a.wav']);
      final state = AppState()
        ..modelPath = 'm.onnx'
        ..chunkStrategy = ChunkStrategy.neural
        ..vadThreshold = 0.6
        ..selectVad(path: 'silero.onnx');
      addTearDown(state.dispose);
      final service = _RecordingService();

      await tester.pumpWidget(_queueApp(state: state, service: service));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add audio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run queue'));
      await tester.pumpAndSettle();

      expect(service.transcribeCalls, 1);
      expect(service.lastNeuralVad!.threshold, 0.6);
      expect(service.lastChunkSettings, isNull);
    });

    testWidgets('blocks neural mode without a VAD model', (tester) async {
      _mockPicker(tester, ['a.wav']);
      final state = AppState()
        ..modelPath = 'm.onnx'
        ..chunkStrategy = ChunkStrategy.neural;
      addTearDown(state.dispose);

      await tester.pumpWidget(
        _queueApp(state: state, service: _RecordingService()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add audio'));
      await tester.pumpAndSettle();

      expect(
        find.text('Select a downloaded VAD model in the Models tab to use neural VAD.'),
        findsOneWidget,
      );
      final run = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Run queue'),
      );
      expect(run.onPressed, isNull);
    });

    testWidgets('cancelling also cancels the VAD worker; retry resets it', (
      tester,
    ) async {
      _mockPicker(tester, ['a.wav']);
      final built = <_FakeVadEngine>[];
      final state = AppState(
        engineRegistry: EngineRegistry(
          asrBuilders: {
            'sherpa': () {
              final engine = _FakeVadEngine();
              built.add(engine);
              return engine;
            },
          },
        ),
      )
        ..modelPath = 'm.onnx'
        ..chunkStrategy = ChunkStrategy.neural
        ..selectVad(path: 'silero.onnx');
      addTearDown(state.dispose);
      // Production builds the service from this worker; touch it so there is
      // one for cancelVad to reach.
      expect(state.activeVadEngine, isNotNull);
      expect(built, hasLength(1));

      await tester.pumpWidget(
        _queueApp(state: state, service: _BlockingService()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add audio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run queue'));
      await tester.pump();

      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(built.single.cancelCalls, 1);
      expect(find.text('Cancelled'), findsOneWidget);

      // Retry drops the cancelled worker so the next run starts fresh.
      await tester.tap(find.byTooltip('Retry'));
      await tester.pumpAndSettle();
      expect(state.activeVadEngine, isNotNull);
      expect(built, hasLength(2));
    });
  });

  group('Bench', () {
    testWidgets('skips VAD bundles and benchmarks with the neural settings', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const asr = ModelEntry(
        id: 'asr',
        displayName: 'Speech',
        fileName: 'a.onnx',
        family: 'sensevoice',
      );
      const vad = ModelEntry(
        id: 'vad',
        displayName: 'Silero',
        fileName: 'v.onnx',
        type: 'vad',
      );
      final store = LocalModelStore(dir);
      for (final entry in [asr, vad]) {
        File(store.pathFor(entry))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync([0, 0]);
      }
      final state = AppState()
        ..chunkStrategy = ChunkStrategy.neural
        ..selectVad(path: 'silero.onnx');
      addTearDown(state.dispose);
      final service = _RecordingService();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BenchPage(
            engine: _CountingEngine(),
            service: service,
            entries: const [asr, vad],
            store: store,
            state: state,
            pickAudio: () async => 'picked.wav',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The VAD bundle is not a speech recognizer and gets no matrix row.
      expect(find.text('Silero'), findsNothing);
      expect(find.text('Speech'), findsOneWidget);

      await tester.tap(find.text('Choose audio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run benchmark'));
      await tester.pumpAndSettle();

      expect(service.transcribeCalls, 3); // one model × three repeats
      expect(service.lastNeuralVad, isNotNull);
      expect(service.lastNeuralVad!.modelPath, 'silero.onnx');
      expect(service.lastChunkSettings, isNull);
    });
  });
}
