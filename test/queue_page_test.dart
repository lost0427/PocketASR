import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/app/app_state.dart';
import 'package:pocket_asr/core/audio/chunk_planner.dart';
import 'package:pocket_asr/data/db.dart';
import 'package:pocket_asr/data/transcript_repo.dart';
import 'package:pocket_asr/engine/asr_engine.dart';
import 'package:pocket_asr/features/queue/queue_page.dart';
import 'package:pocket_asr/features/transcribe/transcription_service.dart';
import 'package:pocket_asr/l10n/app_localizations.dart';

/// Records what the queue actually sent; the engine is never touched because
/// [transcribe] is overridden.
class _RecordingService extends TranscriptionService {
  _RecordingService() : super(engine: const UnavailableAsrEngine());

  final List<EngineModelSpec> models = [];

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
    void Function(TranscribeProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    models.add(model);
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
}

const MethodChannel _selectorChannel = MethodChannel(
  'plugins.flutter.io/file_selector',
);

void main() {
  testWidgets('the queue runs with the full spec AppState holds', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_selectorChannel, (call) async {
      if (call.method == 'openFile') return ['a.wav', 'b.wav'];
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_selectorChannel, null));

    final database = AppDatabase.open();
    addTearDown(database.close);
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

    final service = _RecordingService();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: QueuePage(
            engine: const UnavailableAsrEngine(),
            transcriptRepo: TranscriptRepo(database),
            state: state,
            service: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add audio'));
    await tester.pumpAndSettle();
    expect(find.text('a.wav'), findsOneWidget);
    expect(find.text('b.wav'), findsOneWidget);

    await tester.tap(find.text('Run queue'));
    await tester.pumpAndSettle();

    // Both jobs got the same companion-complete spec, not a path-only rebuild.
    expect(service.models, hasLength(2));
    for (final model in service.models) {
      expect(model.decoderPath, 'dec.onnx');
      expect(model.tokensPath, 'tok.txt');
      expect(model.family, 'whisper');
    }
    // The busy flag is released once the queue drains.
    expect(state.engineBusy, isFalse);
  });

  testWidgets('adding the same path twice keeps two separate jobs', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var openCount = 0;
    messenger.setMockMethodCallHandler(_selectorChannel, (call) async {
      if (call.method == 'openFile') {
        openCount++;
        return ['same.wav'];
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_selectorChannel, null));

    final state = AppState();
    addTearDown(state.dispose);

    await tester.pumpWidget(_host(state: state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add audio'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add audio'));
    await tester.pumpAndSettle();

    expect(openCount, 2);
    expect(find.text('same.wav'), findsNWidgets(2)); // not shadowed by one id
  });

  testWidgets('reorder moves a queued job and remove drops it', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_selectorChannel, (call) async {
      if (call.method == 'openFile') return ['a.wav', 'b.wav'];
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_selectorChannel, null));

    final state = AppState();
    addTearDown(state.dispose);

    await tester.pumpWidget(_host(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add audio'));
    await tester.pumpAndSettle();

    // Second row's "move up" swaps the two titles.
    await tester.tap(find.byTooltip('Move up').at(1));
    await tester.pumpAndSettle();
    final titles = tester
        .widgetList<Text>(find.descendant(
          of: find.byType(ListTile),
          matching: find.byType(Text),
        ))
        .map((t) => t.data)
        .toList();
    expect(titles.indexOf('a.wav'), greaterThan(titles.indexOf('b.wav')));

    // Remove the first remaining row; only one title is left.
    await tester.tap(find.byTooltip('Remove').first);
    await tester.pumpAndSettle();
    expect(
      find.text('a.wav').evaluate().length + find.text('b.wav').evaluate().length,
      1,
    );
  });

  testWidgets('cancelling the running job asks a cancellable engine to stop', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_selectorChannel, (call) async {
      if (call.method == 'openFile') return ['a.wav'];
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_selectorChannel, null));

    final engine = _CancellableFakeEngine();
    final service = _BlockingService();
    final state = AppState();
    addTearDown(state.dispose);
    state.modelPath = 'm.onnx'; // a run needs a model to start

    await tester.pumpWidget(
      _host(state: state, engine: engine, service: service),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add audio'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run queue'));
    await tester.pump();

    // The page really asked the engine to abort (the cooperative seam).
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(engine.cancelCalls, 1);
    expect(find.text('Cancelled'), findsOneWidget);
    expect(state.engineBusy, isFalse);
  });

  testWidgets('another page\'s run disables this one', (tester) async {
    final state = AppState()..engineBusy = true;
    addTearDown(state.dispose);

    await tester.pumpWidget(_host(state: state));
    await tester.pumpAndSettle();

    expect(
      find.text('Another transcription is running. Wait for it to finish first.'),
      findsOneWidget,
    );
    final run = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Run queue'),
    );
    expect(run.onPressed, isNull);
  });
}

Widget _host({
  required AppState state,
  AsrEngine engine = const UnavailableAsrEngine(),
  TranscriptionService? service,
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

/// Cancellable engine seam: records [cancel] calls without native work.
/// Extends the unavailable stand-in so it inherits whatever `planVad`
/// signature the engine interface currently declares.
class _CancellableFakeEngine extends UnavailableAsrEngine
    implements CancellableAsrEngine {
  int cancelCalls = 0;

  @override
  String get id => 'fake';

  @override
  Future<void> cancel() async => cancelCalls++;

  @override
  Future<List<Backend>> availableBackends() async => const [Backend.cpu];

  @override
  Future<EngineCapabilities> capabilities() async =>
      const EngineCapabilities(available: true, backends: {Backend.cpu});

  @override
  Future<void> load(EngineModelSpec spec, Backend backend) async {}

  @override
  Stream<TranscribeProgress> transcribe(TranscribeRequest request) =>
      const Stream<TranscribeProgress>.empty();
}

/// Blocks like a native call and throws once [isCancelled] flips.
class _BlockingService extends TranscriptionService {
  _BlockingService() : super(engine: const UnavailableAsrEngine());

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
    void Function(TranscribeProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    while (!(isCancelled?.call() ?? false)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    throw const EngineCancelledException('stopped between chunks');
  }
}
