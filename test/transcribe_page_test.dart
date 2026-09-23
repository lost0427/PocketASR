import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/app/app_state.dart';
import 'package:pocket_asr/core/audio/chunk_planner.dart';
import 'package:pocket_asr/core/audio/pcm_file.dart';
import 'package:pocket_asr/data/db.dart';
import 'package:pocket_asr/data/transcript_repo.dart';
import 'package:pocket_asr/engine/asr_engine.dart';
import 'package:pocket_asr/engine/system_metrics.dart';
import 'package:pocket_asr/features/transcribe/transcribe_page.dart';
import 'package:pocket_asr/features/transcribe/transcription_service.dart';
import 'package:pocket_asr/l10n/app_localizations.dart';

Widget _app({
  Locale? locale,
  AsrEngine engine = const UnavailableAsrEngine(),
  AppState? state,
  TranscriptRepo? transcriptRepo,
  TranscriptionService? service,
  SystemMetricsSampler Function()? metricsSamplerFactory,
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
      metricsSamplerFactory: metricsSamplerFactory,
    ),
  ),
);

/// Minimal engine whose capabilities are fixed by the test. Extends the
/// unavailable stand-in so it inherits whatever `planVad` signature the engine
/// interface declares.
class _FakeEngine extends UnavailableAsrEngine {
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
}

const _availableCaps = EngineCapabilities(
  available: true,
  backends: {Backend.cpu},
);

/// Service stub that replays a fixed progress script and returns a result,
/// so the page's live-metric wiring is tested without real audio or native IO.
class _ScriptedService extends TranscriptionService {
  _ScriptedService(this.steps)
    : super(engine: const _FakeEngine(_availableCaps));

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
    // Object? keeps this override valid under both the pre-VAD and neural-VAD
    // service signature.
    Object? neuralVad,
    void Function(TranscriptionStage stage)? onStage,
    void Function(TranscribeProgress progress)? onProgress,
    bool Function()? isCancelled,
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
      decoderInfo: const AudioDecoderInfo(
        name: 'MediaCodec',
        codecName: 'c2.qti.aac.decoder + SpeexDSP AGC',
        isHardware: true,
      ),
    );
  }
}

/// Method channel the default file selector uses; mocked so the page can pick
/// an "audio file" and a "model" without a real dialog.
const MethodChannel _selectorChannel = MethodChannel(
  'plugins.flutter.io/file_selector',
);

/// Sampler seam: records how many times the page actually sampled.
class _FakeSampler extends SystemMetricsSampler {
  int calls = 0;

  @override
  Future<SystemMetrics> sample() async {
    calls++;
    return const SystemMetrics(cpuPercent: 37, memoryBytes: 2097152);
  }
}

/// Finishes only when [release] completes, so a run can be observed in flight.
class _SlowService extends TranscriptionService {
  _SlowService() : super(engine: const _FakeEngine(_availableCaps));

  final release = Completer<void>();

  @override
  Future<TranscriptionJobResult> transcribe({
    required String audioPath,
    required EngineModelSpec model,
    Backend backend = Backend.cpu,
    String? language,
    ChunkSettings? chunkSettings,
    void Function(TranscriptionStage stage)? onStage,
    void Function(TranscribeProgress progress)? onProgress,
    bool Function()? isCancelled,
    Object? neuralVad,
  }) async {
    onStage?.call(TranscriptionStage.segmenting);
    onProgress?.call(
      const TranscribeProgress(
        elapsed: Duration(milliseconds: 500),
        ratio: 0.5,
        partialText: 'hel',
      ),
    );
    await release.future;
    return TranscriptionJobResult(
      text: 'hello',
      elapsed: const Duration(seconds: 1),
      audioDuration: const Duration(seconds: 1),
      engine: 'fake',
      model: model,
      backend: backend,
    );
  }
}

/// Returns a real [VadPreview] only once [release] completes, so a preview can
/// be observed mid-plan and cancelled before its late plan lands.
class _GatedPreviewService extends TranscriptionService {
  _GatedPreviewService() : super(engine: const _FakeEngine(_availableCaps));

  final release = Completer<void>();

  @override
  Future<VadPreview> previewVad({
    required String audioPath,
    required NeuralVadSettings neuralVad,
    bool Function()? isCancelled,
  }) async {
    await release.future;
    return const VadPreview(
      windows: [
        [AudioChunk(start: Duration.zero, end: Duration(seconds: 2))],
      ],
      sampleRate: 16000,
    );
  }
}

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

  testWidgets('stacks engine status tiles on a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_app(engine: const _FakeEngine(_availableCaps)));
    await tester.pumpAndSettle();

    final modelTop = tester.getTopLeft(find.byIcon(Icons.layers_outlined)).dy;
    final engineTop = tester.getTopLeft(find.byIcon(Icons.memory_outlined)).dy;
    final backendTop = tester
        .getTopLeft(find.byIcon(Icons.developer_board_outlined))
        .dy;

    expect(engineTop, greaterThan(modelTop));
    expect(backendTop, engineTop);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a finished run shows real metrics and saves the transcript', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_selectorChannel, (call) async {
      if (call.method == 'openFile') return ['meeting.wav'];
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(_selectorChannel, null),
    );

    final database = AppDatabase.open(); // in-memory
    addTearDown(database.close);
    final repo = TranscriptRepo(database);
    final state = AppState();
    addTearDown(state.dispose);
    state.selectModel(
      spec: const EngineModelSpec(path: 'model.onnx'),
      engineId: 'sherpa',
    );

    const engine = _FakeEngine(_availableCaps);
    final service = _ScriptedService(const [
      TranscribeProgress(
        elapsed: Duration(seconds: 1),
        ratio: 0.5,
        partialText: 'hel',
      ),
      TranscribeProgress(
        elapsed: Duration(seconds: 2),
        ratio: 1,
        partialText: 'hello',
      ),
    ]);

    await tester.pumpWidget(
      _app(
        engine: engine,
        state: state,
        transcriptRepo: repo,
        service: service,
      ),
    );
    await tester.pumpAndSettle();

    // Pick the audio; the model is the catalog selection in shared state.
    await tester.tap(find.text('Choose audio file').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start transcription'));
    await tester.pumpAndSettle();

    // Engine / backend / model reflect the run.
    expect(find.text('fake'), findsOneWidget);
    expect(find.text('CPU'), findsWidgets);
    expect(find.text('model.onnx'), findsOneWidget);

    // Real metrics: 5 graphemes / 2 s = 2.5,
    // RTF = 2 s / 0.5 s audio = 4.00, elapsed = 2.0s.
    expect(find.text('2.5'), findsOneWidget); // chars/s
    expect(find.text('4.00'), findsOneWidget); // RTF
    expect(find.text('2.0s'), findsOneWidget); // elapsed
    expect(find.text('Hardware'), findsOneWidget);

    expect(find.text('hello'), findsOneWidget); // final transcript

    final rows = repo.list();
    expect(rows, hasLength(1));
    expect(rows.single.text, 'hello');
    expect(rows.single.engine, 'fake');
    expect(rows.single.modelPath, 'model.onnx');
    expect(rows.single.backend, 'cpu');
    expect(rows.single.totalMs, 2000);
    expect(rows.single.rtf, 4.0);
  });

  testWidgets('file picker no longer uses the placeholder flow', (
    tester,
  ) async {
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
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_selectorChannel, (call) async {
      if (call.method == 'openFile') return ['meeting.wav'];
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(_selectorChannel, null),
    );

    final state = AppState();
    addTearDown(state.dispose);
    state.selectModel(
      spec: const EngineModelSpec(
        path: 'model.onnx',
        family: 'sensevoice',
        quant: 'q8_0',
      ),
      engineId: 'sherpa',
      family: 'sensevoice',
      quant: 'q8_0',
    );
    state.chunkStrategy = ChunkStrategy.energy;
    state.chunkSeconds = 12;
    state.energyThreshold = 0.02;
    state.speechPadMs = 40;

    final database = AppDatabase.open();
    addTearDown(database.close);
    final repo = TranscriptRepo(database);

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
        transcriptRepo: repo,
        service: service,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose audio file').first);
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
    // The saved row records the run's model family, not just its path.
    expect(repo.list().single.modelFamily, 'sensevoice');
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
    addTearDown(
      () => messenger.setMockMethodCallHandler(_selectorChannel, null),
    );

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

    expect(find.textContaining('model bundle is incomplete'), findsOneWidget);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start transcription'),
    );
    expect(start.onPressed, isNull);
  });

  testWidgets('explains that a hand-picked MNN file is not verified', (
    tester,
  ) async {
    final state = AppState()..modelPath = 'hand-picked.mnn';
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _app(engine: const _FakeEngine(_availableCaps), state: state),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('MNN models can only run from a verified download'),
      findsOneWidget,
    );
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
    addTearDown(
      () => messenger.setMockMethodCallHandler(_selectorChannel, null),
    );

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
    expect(find.textContaining('model bundle is incomplete'), findsNothing);

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

  testWidgets('samples CPU and memory only while a run is active', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_selectorChannel, (call) async {
      if (call.method == 'openFile') return ['meeting.wav'];
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(_selectorChannel, null),
    );

    final state = AppState()..modelPath = 'model.onnx';
    addTearDown(state.dispose);
    final sampler = _FakeSampler();
    final service = _SlowService();

    await tester.pumpWidget(
      _app(
        engine: const _FakeEngine(_availableCaps),
        state: state,
        service: service,
        metricsSamplerFactory: () => sampler,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose audio file').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start transcription'));
    await tester.pump();

    expect(find.text('Segmenting audio'), findsOneWidget);
    expect(find.text('Calculating'), findsNothing);

    // A tick of the run's sampler fills the CPU and memory tiles with the
    // readings the sampler really returned.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(sampler.calls, greaterThanOrEqualTo(1));
    expect(find.text('37%'), findsOneWidget);
    expect(find.text('2.0 MB'), findsOneWidget);

    // Ending the run stops the sampling: no further reads happen.
    service.release.complete();
    await tester.pumpAndSettle();
    final callsAtEnd = sampler.calls;
    await tester.pump(const Duration(seconds: 3));
    expect(sampler.calls, callsAtEnd);
  });

  testWidgets('cancelling shows the real wait and drops the late result', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_selectorChannel, (call) async {
      if (call.method == 'openFile') return ['meeting.wav'];
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(_selectorChannel, null),
    );

    final database = AppDatabase.open();
    addTearDown(database.close);
    final repo = TranscriptRepo(database);
    final service = _SlowService();
    final state = AppState();
    addTearDown(state.dispose);
    state.selectModel(
      spec: const EngineModelSpec(path: 'model.onnx'),
      engineId: 'sherpa',
    );

    await tester.pumpWidget(
      _app(
        engine: const _FakeEngine(_availableCaps),
        state: state,
        transcriptRepo: repo,
        service: service,
        metricsSamplerFactory: _FakeSampler.new,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Choose audio file').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start transcription'));
    await tester.pump();

    // Ask to stop while the "engine" is still in flight.
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    // The abort is cooperative, so the page says it is still winding down
    // instead of pretending the run already stopped.
    expect(find.text('Cancelling…'), findsWidgets);
    expect(repo.list(), isEmpty);

    // The engine returns *after* the cancel: the late text is thrown away.
    service.release.complete();
    await tester.pumpAndSettle();

    expect(repo.list(), isEmpty);
    expect(find.text('hello'), findsNothing);
    expect(find.text('Cancelling…'), findsNothing);
  });

  testWidgets('a cancelled preview never shows its late plan', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_selectorChannel, (call) async {
      if (call.method == 'openFile') return ['meeting.wav'];
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(_selectorChannel, null),
    );

    final state = AppState();
    addTearDown(state.dispose);
    state.selectVad(path: 'vad.onnx');
    state.chunkStrategy = ChunkStrategy.neural;
    final service = _GatedPreviewService();

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

    await tester.tap(find.text('Preview'));
    await tester.pump();
    expect(find.text('Analysing speech…'), findsOneWidget);

    // Cancel mid-plan, then let the plan land.
    await tester.ensureVisible(find.text('Cancel'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    service.release.complete();
    await tester.pumpAndSettle();

    // The late plan is dropped: no windows, no summary.
    expect(find.textContaining('window(s)'), findsNothing);
    expect(find.textContaining('Window '), findsNothing);
    expect(find.text('Preview'), findsOneWidget);
  });
}
