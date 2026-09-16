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
    void Function(TranscribeProgress progress)? onProgress,
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
}
