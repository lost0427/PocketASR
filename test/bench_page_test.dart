import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/chunk_planner.dart';
import 'package:pocket_asr/engine/asr_engine.dart';
import 'package:pocket_asr/engine/model_catalog.dart';
import 'package:pocket_asr/features/bench/bench_page.dart';
import 'package:pocket_asr/features/transcribe/transcription_service.dart';
import 'package:pocket_asr/l10n/app_localizations.dart';

/// Engine whose capabilities the test fixes; extends the unavailable stand-in
/// so it inherits whatever `planVad` signature the interface declares.
class _FakeEngine extends UnavailableAsrEngine {
  const _FakeEngine({this.available = true});

  final bool available;

  @override
  String get id => 'fake';

  @override
  Future<EngineCapabilities> capabilities() async => available
      ? const EngineCapabilities(
          available: true,
          backends: {Backend.cpu},
        )
      : const EngineCapabilities.unavailable('no native library');

  @override
  Future<List<Backend>> availableBackends() async =>
      available ? const [Backend.cpu] : const [];
}

class _CancellableEngine extends _FakeEngine implements CancellableAsrEngine {
  int cancelCalls = 0;

  @override
  Future<void> cancel() async => cancelCalls++;
}

class _NamedEngine extends _FakeEngine {
  _NamedEngine(this.engineId);

  final String engineId;
  bool disposed = false;

  @override
  String get id => engineId;

  @override
  Future<void> dispose() async => disposed = true;
}

class _RoutingService extends TranscriptionService {
  _RoutingService(AsrEngine engine, this.calls) : super(engine: engine);

  final List<(String, EngineModelSpec)> calls;

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
    calls.add((engine.id, model));
    return TranscriptionJobResult(
      text: 'ok',
      elapsed: const Duration(milliseconds: 100),
      audioDuration: const Duration(seconds: 1),
      engine: engine.id,
      model: model,
      backend: backend,
      originalLufs: -16,
      gainDb: 0,
    );
  }
}

/// Returns results with controlled numbers so the medians are predictable:
/// elapsed 100/200/300 ms, RTF 0.10/0.20/0.30 and chars/s 20/10/6.7.
class _ScriptedService extends TranscriptionService {
  _ScriptedService() : super(engine: const _FakeEngine());

  final List<String> paths = [];

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
    final n = paths.length;
    paths.add(audioPath);
    const millis = [100, 200, 300];
    return TranscriptionJobResult(
      text: 'ok',
      elapsed: Duration(milliseconds: millis[n % 3]),
      audioDuration: const Duration(seconds: 1),
      engine: 'fake',
      model: model,
      backend: backend,
      originalLufs: -16,
      gainDb: 0,
    );
  }
}

/// Always fails, so the page must show the failure, not a number.
class _FailingService extends TranscriptionService {
  _FailingService() : super(engine: const _FakeEngine());

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
    throw const EngineUnavailableException('model file is gone');
  }
}

/// Blocks until [isCancelled] flips, like a native call in flight.
class _BlockingService extends TranscriptionService {
  _BlockingService() : super(engine: const _FakeEngine());

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
    while (!(isCancelled?.call() ?? false)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    throw const EngineCancelledException('stopped');
  }
}

const _sense = ModelEntry(
  id: 'sense',
  displayName: 'SenseVoice',
  fileName: 'sense.onnx',
  family: 'sensevoice',
  quant: 'q4_k',
  engine: 'sherpa',
);

void main() {
  late Directory dir;
  late LocalModelStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pocket_asr_bench');
    store = LocalModelStore(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void download(ModelEntry entry) {
    for (final file in entry.bundleFiles) {
      File(store.pathToFile(entry, file))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List.filled(16, 0));
    }
  }

  /// A tall surface so every control and result is laid out in the test.
  Future<void> pumpBench(
    WidgetTester tester, {
    AsrEngine engine = const _FakeEngine(),
    TranscriptionService? service,
    BenchmarkEngineFactory? engineFactory,
    BenchmarkServiceFactory? serviceFactory,
    List<ModelEntry> entries = const [],
    String? audio,
    Future<void> Function(String, String)? exportFile,
  }) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BenchPage(
          engine: engine,
          service: service,
          engineFactory: engineFactory,
          serviceFactory: serviceFactory,
          entries: entries,
          store: store,
          pickAudio: () async => audio,
          exportFile: exportFile,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an unavailable engine blocks the run and says why', (
    tester,
  ) async {
    await pumpBench(
      tester,
      engine: const _FakeEngine(available: false),
      entries: const [_sense],
    );

    expect(find.text('Nothing can run in this build'), findsOneWidget);
    expect(find.textContaining('native speech engine'), findsOneWidget);
    final run = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Run benchmark'),
    );
    expect(run.onPressed, isNull);
  });

  testWidgets('only downloaded models are listed', (tester) async {
    await pumpBench(tester, entries: const [_sense]);
    expect(find.text('No downloaded speech models'), findsOneWidget);
    expect(find.text('SenseVoice'), findsNothing);

    download(_sense);
    // A fresh State so the setup future re-runs against the new files.
    await tester.pumpWidget(const SizedBox());
    await pumpBench(tester, entries: const [_sense]);
    expect(find.text('SenseVoice'), findsOneWidget);
    expect(find.text('No downloaded speech models'), findsNothing);
  });

  testWidgets('runs the same picked audio three times and shows the median', (
    tester,
  ) async {
    download(_sense);
    final service = _ScriptedService();
    final saved = <String, String>{};

    await pumpBench(
      tester,
      service: service,
      entries: const [_sense],
      audio: 'picked.wav',
      exportFile: (name, contents) async => saved[name] = contents,
    );

    // No audio yet: the run is refused with a hint.
    expect(find.text('Choose an audio file before running.'), findsOneWidget);
    final before = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Run benchmark'),
    );
    expect(before.onPressed, isNull);

    await tester.tap(find.text('Choose audio'));
    await tester.pumpAndSettle();
    expect(find.text('picked.wav'), findsOneWidget);

    await tester.tap(find.text('Run benchmark'));
    await tester.pumpAndSettle();

    // Three real runs of the one picked file.
    expect(service.paths, ['picked.wav', 'picked.wav', 'picked.wav']);
    // Medians: 200ms, 0.20 RTF, 10.0 chars/s, 3/3 runs.
    expect(find.text('200ms'), findsOneWidget);
    expect(find.text('0.20'), findsOneWidget);
    expect(find.text('10.0'), findsOneWidget);
    expect(find.text('3/3'), findsOneWidget);

    await tester.tap(find.text('Export JSON'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();
    expect(
      saved.keys,
      containsAll(['pocketasr_benchmark.json', 'pocketasr_benchmark.csv']),
    );
    expect(saved['pocketasr_benchmark.json'], contains('"rtf": 0.2'));
    expect(saved['pocketasr_benchmark.csv'], contains('"sensevoice"'));
  });

  testWidgets('routes bundles to their engines with complete model specs', (
    tester,
  ) async {
    const whisper = ModelEntry(
      id: 'whisper',
      displayName: 'Whisper',
      fileName: 'encoder.onnx',
      family: 'whisper',
      quant: 'int8',
      engine: 'sherpa',
      files: [
        ModelFile(fileName: 'encoder.onnx', role: 'encoder'),
        ModelFile(fileName: 'decoder.onnx', role: 'decoder'),
        ModelFile(fileName: 'tokens.txt', role: 'tokens'),
      ],
    );
    const crisp = ModelEntry(
      id: 'crisp',
      displayName: 'Crisp',
      fileName: 'model.gguf',
      family: 'sensevoice',
      quant: 'q4_k',
      engine: 'crispasr',
    );
    download(whisper);
    download(crisp);

    final engines = <_NamedEngine>[];
    final calls = <(String, EngineModelSpec)>[];
    await pumpBench(
      tester,
      entries: const [whisper, crisp],
      audio: 'picked.wav',
      engineFactory: (id) {
        final engine = _NamedEngine(id);
        engines.add(engine);
        return engine;
      },
      serviceFactory: (engine) => _RoutingService(engine, calls),
    );

    await tester.tap(find.text('Choose audio'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run benchmark'));
    await tester.pumpAndSettle();

    expect(engines.map((engine) => engine.id), ['sherpa', 'crispasr']);
    expect(calls, hasLength(6));
    expect(calls.take(3).every((call) => call.$1 == 'sherpa'), isTrue);
    expect(calls.skip(3).every((call) => call.$1 == 'crispasr'), isTrue);
    final whisperSpec = calls.first.$2;
    expect(whisperSpec.encoderPath, endsWith('encoder.onnx'));
    expect(whisperSpec.decoderPath, endsWith('decoder.onnx'));
    expect(whisperSpec.tokensPath, endsWith('tokens.txt'));
    expect(engines.every((engine) => engine.disposed), isTrue);
  });

  testWidgets('a failed model shows the failure, never a number', (
    tester,
  ) async {
    download(_sense);
    await pumpBench(
      tester,
      service: _FailingService(),
      entries: const [_sense],
      audio: 'picked.wav',
    );

    await tester.tap(find.text('Choose audio'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run benchmark'));
    await tester.pumpAndSettle();

    expect(find.textContaining('model file is gone'), findsWidgets);
    expect(find.text('0/3'), findsOneWidget); // no successful run
  });

  testWidgets('cancelling asks a cancellable engine to stop', (tester) async {
    download(_sense);
    final engine = _CancellableEngine();
    await pumpBench(
      tester,
      engine: engine,
      service: _BlockingService(),
      entries: const [_sense],
      audio: 'picked.wav',
    );

    await tester.tap(find.text('Choose audio'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run benchmark'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(engine.cancelCalls, 1);
    expect(find.text('Cancelled'), findsOneWidget);
  });
}
