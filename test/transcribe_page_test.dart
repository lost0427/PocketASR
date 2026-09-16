import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/app/app_state.dart';
import 'package:pocket_asr/core/audio/chunk_planner.dart';
import 'package:pocket_asr/data/db.dart';
import 'package:pocket_asr/data/transcript_repo.dart';
import 'package:pocket_asr/engine/asr_engine.dart';
import 'package:pocket_asr/features/transcribe/transcribe_page.dart';
import 'package:pocket_asr/features/transcribe/transcription_service.dart';
import 'package:pocket_asr/l10n/app_localizations.dart';

Widget _app({
  Locale? locale,
  AsrEngine engine = const UnavailableAsrEngine(),
  AppState? state,
  TranscriptRepo? transcriptRepo,
  TranscriptionService? service,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: TranscribePage(
      engine: engine,
      state: state,
      transcriptRepo: transcriptRepo,
      service: service,
    ),
  ),
);

/// Minimal engine whose capabilities are fixed by the test.
class _FakeEngine implements AsrEngine {
  const _FakeEngine(this.caps);

  final EngineCapabilities caps;

  @override
  String get id => 'fake';

  @override
  Future<List<Backend>> availableBackends() async => caps.backends.toList();

  @override
  Future<EngineCapabilities> capabilities() async => caps;

  @override
  Future<void> load(EngineModelSpec spec, Backend backend) async {}

  @override
  Stream<TranscribeProgress> transcribe(TranscribeRequest request) =>
      Stream<TranscribeProgress>.empty();

  @override
  Future<VadPlan> planVad(TranscribeRequest request) async =>
      const VadPlan.empty();

  @override
  Future<void> dispose() async {}
}

const _availableCaps = EngineCapabilities(
  available: true,
  backends: {Backend.cpu},
);

/// Service stub that replays a fixed progress script and returns a result,
/// so the page's live-metric wiring is tested without real audio or native IO.
class _ScriptedService extends TranscriptionService {
  _ScriptedService(this.steps) : super(engine: const _FakeEngine(_availableCaps));

  final List<TranscribeProgress> steps;

  /// What the page actually sent, for asserting wiring rather than layout.
  EngineModelSpec? lastModel;
  Backend? lastBackend;
  ChunkSettings? lastChunkSettings;

  @override
  Future<TranscriptionJobResult> transcribe({
    required String audioPath,
    required EngineModelSpec model,
    Backend backend = Backend.cpu,
    String? language,
    ChunkSettings? chunkSettings,
    void Function(TranscribeProgress progress)? onProgress,
  }) async {
    lastModel = model;
    lastBackend = backend;
    lastChunkSettings = chunkSettings;
    for (final step in steps) {
      onProgress?.call(step);
    }
    return TranscriptionJobResult(
      text: 'hello',
      elapsed: const Duration(seconds: 2),
      audioDuration: const Duration(milliseconds: 500),
      engine: 'fake',
      model: model,
      backend: backend,
      originalLufs: -16,
      gainDb: 0,
      tokens: 4,
    );
  }
}

/// Method channel the default file selector uses; mocked so the page can pick
/// an "audio file" and a "model" without a real dialog.
const MethodChannel _selectorChannel = MethodChannel(
  'plugins.flutter.io/file_selector',
);

void main() {
  testWidgets('reports the engine as unavailable instead of faking a result', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('On-device engine unavailable'), findsOneWidget);
    expect(find.text('Not selected'), findsOneWidget);

    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start transcription'),
    );
    expect(start.onPressed, isNull);

    final copy = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Copy'),
    );
    expect(copy.onPressed, isNull);

    // No backend and no metrics are known, so they stay blank rather than
    // showing an invented number.
    expect(find.text('—'), findsWidgets);
    expect(find.text('The transcript will appear here.'), findsOneWidget);
  });

  testWidgets('no banner and a live backend when the engine is available', (
    tester,
  ) async {
    await tester.pumpWidget(_app(engine: const _FakeEngine(_availableCaps)));
    await tester.pumpAndSettle();

    expect(find.text('On-device engine unavailable'), findsNothing);
    expect(find.text('CPU'), findsWidgets);

    // Still no file picked, so Start stays disabled — availability alone does
    // not produce a transcript.
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start transcription'),
    );
    expect(start.onPressed, isNull);
  });

  testWidgets('displays the current engine, backend and model', (tester) async {
    await tester.pumpWidget(_app(engine: const _FakeEngine(_availableCaps)));
    await tester.pumpAndSettle();

    expect(find.text('fake'), findsOneWidget);
    expect(find.text('CPU'), findsWidgets);
  });

  testWidgets('a finished run shows real metrics and saves the transcript', (
    tester,
  ) async {
    final picks = <List<String>>[
      ['meeting.wav'],
      ['model.onnx'],
    ];
    var pick = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_selectorChannel, (call) async {
      if (call.method == 'openFile') return picks[pick++];
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_selectorChannel, null));

    final database = AppDatabase.open(); // in-memory
    addTearDown(database.close);
    final repo = TranscriptRepo(database);

    const engine = _FakeEngine(_availableCaps);
    final service = _ScriptedService(const [
      TranscribeProgress(
        elapsed: Duration(seconds: 1),
        ratio: 0.5,
        partialText: 'hel',
        tokens: 2,
      ),
      TranscribeProgress(
        elapsed: Duration(seconds: 2),
        ratio: 1,
        partialText: 'hello',
        tokens: 4,
      ),
    ]);

    await tester.pumpWidget(
      _app(engine: engine, transcriptRepo: repo, service: service),
    );
    await tester.pumpAndSettle();

    // Pick the audio, then the model.
    await tester.tap(find.text('Choose audio file').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose model file'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start transcription'));
    await tester.pumpAndSettle();

    // Engine / backend / model reflect the run.
    expect(find.text('fake'), findsOneWidget);
    expect(find.text('CPU'), findsWidgets);
    expect(find.text('model.onnx'), findsOneWidget);

    // Real metrics: 4 tokens / 2 s = 2.0, 5 graphemes / 2 s = 2.5,
    // RTF = 2 s / 0.5 s audio = 4.00, elapsed = 2.0s.
    expect(find.text('2.0'), findsOneWidget); // tokens/s
    expect(find.text('2.5'), findsOneWidget); // chars/s
    expect(find.text('4.00'), findsOneWidget); // RTF
    expect(find.text('2.0s'), findsOneWidget); // elapsed

    expect(find.text('hello'), findsOneWidget); // final transcript

    final rows = repo.list();
    expect(rows, hasLength(1));
    expect(rows.single.text, 'hello');
    expect(rows.single.engine, 'fake');
    expect(rows.single.modelPath, 'model.onnx');
    expect(rows.single.backend, 'cpu');
    expect(rows.single.tokens, 4);
    expect(rows.single.totalMs, 2000);
    expect(rows.single.rtf, 4.0);
  });

  testWidgets('file picker no longer uses the placeholder flow', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose audio file').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('File picking is not wired up yet.'), findsNothing);
  });

  testWidgets('localizes the unavailable state to Chinese', (tester) async {
    await tester.pumpWidget(_app(locale: const Locale('zh')));
    await tester.pumpAndSettle();

    expect(find.text('本地引擎不可用'), findsOneWidget);
    expect(find.text('开始转录'), findsOneWidget);
  });

  testWidgets('sends family, quant, backend and chunk settings to the service', (
    tester,
  ) async {
    final picks = <List<String>>[
      ['meeting.wav'],
      ['model.onnx'],
    ];
    var pick = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_selectorChannel, (call) async {
      if (call.method == 'openFile') return picks[pick++];
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_selectorChannel, null));

    final state = AppState();
    addTearDown(state.dispose);
    state.modelFamily = 'sensevoice';
    state.modelQuant = 'q8_0';
    state.chunkMode = ChunkMode.energy;
    state.chunkSeconds = 12;
    state.energyThreshold = 0.02;
    state.speechPadMs = 40;

    final service = _ScriptedService(const [
      TranscribeProgress(elapsed: Duration(seconds: 1), ratio: 1, partialText: 'hi'),
    ]);

    await tester.pumpWidget(
      _app(
        engine: const _FakeEngine(_availableCaps),
        state: state,
        service: service,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose audio file').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose model file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start transcription'));
    await tester.pumpAndSettle();

    // The spec carries the real family/quant, not just a path (the bug that
    // made every sherpa load fail).
    expect(service.lastModel!.path, 'model.onnx');
    expect(service.lastModel!.family, 'sensevoice');
    expect(service.lastModel!.quant, 'q8_0');
    expect(service.lastBackend, Backend.cpu);
    // Chunk settings travel through unchanged, with overlap off.
    expect(service.lastChunkSettings!.mode, ChunkMode.energy);
    expect(service.lastChunkSettings!.chunkSeconds, 12);
    expect(service.lastChunkSettings!.energyThreshold, 0.02);
    expect(service.lastChunkSettings!.speechPadMs, 40);
    expect(service.lastChunkSettings!.overlapSeconds, 0);
    // The pick was shared into AppState so the queue page sees the same model.
    expect(state.modelPath, 'model.onnx');
  });

  testWidgets('refuses a whisper selection that needs a missing decoder', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_selectorChannel, (call) async {
      if (call.method == 'openFile') return ['meeting.wav'];
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_selectorChannel, null));

    final state = AppState();
    addTearDown(state.dispose);
    state.modelFamily = 'whisper';
    state.modelPath = 'whisper-encoder.onnx';

    await tester.pumpWidget(
      _app(engine: const _FakeEngine(_availableCaps), state: state),
    );
    await tester.pumpAndSettle();

    // Both an audio and a model are chosen, yet the selection still cannot run.
    await tester.tap(find.text('Choose audio file').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('needs a separate decoder'), findsOneWidget);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start transcription'),
    );
    expect(start.onPressed, isNull);
  });

  testWidgets('a whisper bundle with its decoder starts and keeps the spec', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_selectorChannel, (call) async {
      if (call.method == 'openFile') return ['meeting.wav'];
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_selectorChannel, null));

    final state = AppState();
    addTearDown(state.dispose);
    state.selectModel(
      spec: const EngineModelSpec(
        path: 'enc.onnx',
        family: 'whisper',
        tokensPath: 'tok.txt',
        encoderPath: 'enc.onnx',
        decoderPath: 'dec.onnx',
      ),
      engineId: 'sherpa',
      family: 'whisper',
      quant: 'int8',
    );

    final service = _ScriptedService(const [
      TranscribeProgress(
        elapsed: Duration(seconds: 1),
        ratio: 1,
        partialText: 'hi',
      ),
    ]);

    await tester.pumpWidget(
      _app(
        engine: const _FakeEngine(_availableCaps),
        state: state,
        service: service,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose audio file').first);
    await tester.pumpAndSettle();

    // The bundle carries its decoder, so it is not blocked.
    expect(find.textContaining('needs a separate decoder'), findsNothing);

    await tester.tap(find.text('Start transcription'));
    await tester.pumpAndSettle();

    // The page handed the engine the same companion-complete spec.
    expect(service.lastModel!.decoderPath, 'dec.onnx');
    expect(service.lastModel!.tokensPath, 'tok.txt');
    expect(service.lastModel!.encoderPath, 'enc.onnx');
    expect(service.lastModel!.family, 'whisper');
    // The busy flag is released once the run finishes.
    expect(state.engineBusy, isFalse);
  });
}
