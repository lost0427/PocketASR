import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/chunk_planner.dart';
import 'package:pocket_asr/engine/asr_engine.dart';
import 'package:pocket_asr/features/queue/queue_worker.dart';
import 'package:pocket_asr/features/queue/transcription_queue.dart';
import 'package:pocket_asr/features/transcribe/transcription_service.dart';

TranscriptionJob job(String id) =>
    TranscriptionJob(id: id, audioPath: 'audio/$id.wav');

/// Records what the worker actually sent; the engine is never touched because
/// [transcribe] is overridden.
class _RecordingService extends TranscriptionService {
  _RecordingService() : super(engine: const UnavailableAsrEngine());

  final List<EngineModelSpec> models = [];
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
    models.add(model);
    lastBackend = backend;
    lastChunkSettings = chunkSettings;
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

void main() {
  test('add appends in insertion order and remove drops by id', () {
    final queue = TranscriptionQueue();
    queue.add(job('a'));
    queue.add(job('b'));

    expect(queue.jobs.map((j) => j.id), ['a', 'b']);
    expect(queue.remove('a'), isTrue);
    expect(queue.remove('missing'), isFalse);
    expect(queue.jobs.map((j) => j.id), ['b']);
  });

  test('reorder moves a job and rejects out-of-range indices', () {
    final queue = TranscriptionQueue();
    for (final id in ['a', 'b', 'c']) {
      queue.add(job(id));
    }

    expect(queue.reorder(0, 2), isTrue);
    expect(queue.jobs.map((j) => j.id), ['b', 'c', 'a']);
    expect(queue.reorder(0, 5), isFalse);
    expect(queue.reorder(-1, 0), isFalse);
    expect(queue.jobs.map((j) => j.id), ['b', 'c', 'a']);
  });

  test('claimNext runs the first pending job and counts attempts', () {
    final queue = TranscriptionQueue();
    queue.add(job('a'));
    queue.add(job('b'));

    final first = queue.claimNext();
    expect(first?.id, 'a');
    expect(first?.status, TranscriptionJobStatus.running);
    expect(first?.attempts, 1);

    // Running job isn't re-claimed; next pending is.
    expect(queue.claimNext()?.id, 'b');
    expect(queue.claimNext(), isNull);
  });

  test('complete only applies to running jobs', () {
    final queue = TranscriptionQueue();
    queue.add(job('a'));

    expect(queue.complete('a'), isFalse); // still pending
    queue.claimNext();
    expect(queue.complete('a'), isTrue);
    expect(queue.byId('a')?.status, TranscriptionJobStatus.done);
  });

  test('cancel stops pending and running jobs but not finished ones', () {
    final queue = TranscriptionQueue();
    queue.add(job('a'));
    queue.add(job('b'));
    queue.claimNext(); // a running

    expect(queue.cancel('a'), isTrue);
    expect(queue.cancel('b'), isTrue);
    expect(queue.cancel('a'), isFalse); // already cancelled
    expect(queue.cancel('missing'), isFalse);
    expect(queue.jobs.every((j) => j.isFinished), isTrue);
  });

  test('failed job retries back to pending and can run again', () {
    final queue = TranscriptionQueue();
    queue.add(job('a'));

    expect(queue.fail('a'), isFalse); // not running yet
    queue.claimNext();
    expect(queue.fail('a', 'boom'), isTrue);
    expect(queue.byId('a')?.status, TranscriptionJobStatus.failed);
    expect(queue.byId('a')?.error, 'boom');

    expect(queue.retry('a'), isTrue);
    expect(queue.byId('a')?.status, TranscriptionJobStatus.pending);
    expect(queue.byId('a')?.error, isNull);

    expect(queue.claimNext()?.attempts, 2);
    expect(queue.retry('a'), isFalse); // running again, not failed
  });

  test('worker sends the family, quant, backend and chunk settings it was given', () async {
    final queue = TranscriptionQueue()..add(job('a'));
    final service = _RecordingService();
    final worker = QueueWorker(
      queue,
      service,
      const EngineModelSpec(path: 'm.onnx', family: 'sensevoice', quant: 'q4_k'),
      backend: Backend.cpu,
      chunkSettings: const ChunkSettings(
        mode: ChunkMode.energy,
        chunkSeconds: 12,
      ),
    );

    await worker.run();

    expect(queue.byId('a')?.status, TranscriptionJobStatus.done);
    expect(service.models, hasLength(1));
    expect(service.models.single.path, 'm.onnx');
    expect(service.models.single.family, 'sensevoice');
    expect(service.models.single.quant, 'q4_k');
    expect(service.lastBackend, Backend.cpu);
    expect(service.lastChunkSettings?.mode, ChunkMode.energy);
    expect(service.lastChunkSettings?.chunkSeconds, 12);
  });
}
