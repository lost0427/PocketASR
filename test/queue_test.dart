import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/chunk_planner.dart';
import 'package:pocket_asr/data/db.dart';
import 'package:pocket_asr/data/transcript_repo.dart';
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
    // Object? keeps this override valid under both the pre-VAD and neural-VAD
    // service signature.
    Object? neuralVad,
    void Function(TranscriptionStage stage)? onStage,
    void Function(TranscribeProgress progress)? onProgress,
    bool Function()? isCancelled,
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

  test('cancel stops a pending job at once and a running one cooperatively', () {
    final queue = TranscriptionQueue();
    queue.add(job('a'));
    queue.add(job('b'));
    queue.claimNext(); // a running

    // Running -> cancelling (the native block in flight must return first).
    expect(queue.cancel('a'), isTrue);
    expect(queue.byId('a')?.status, TranscriptionJobStatus.cancelling);
    expect(queue.isCancelling('a'), isTrue);
    expect(queue.cancel('a'), isFalse); // already requested
    expect(queue.byId('a')?.isFinished, isFalse); // not finished yet

    // Pending -> cancelled immediately.
    expect(queue.cancel('b'), isTrue);
    expect(queue.byId('b')?.status, TranscriptionJobStatus.cancelled);
    expect(queue.cancel('missing'), isFalse);

    // The worker observed the abort and drained the job.
    expect(queue.markCancelled('a'), isTrue);
    expect(queue.byId('a')?.status, TranscriptionJobStatus.cancelled);
    expect(queue.byId('a')?.isFinished, isTrue);
    expect(queue.markCancelled('a'), isFalse); // already finished
    expect(queue.jobs.every((j) => j.isFinished), isTrue);
  });

  test('mutations notify listeners so the page can repaint', () {
    final queue = TranscriptionQueue();
    var notifications = 0;
    queue.addListener(() => notifications++);

    queue.add(job('a')); // 1
    queue.add(job('b')); // 2
    queue.claimNext(); // 3: claims a
    queue.fail('a', 'boom'); // 4
    queue.retry('a'); // 5
    queue.reorder(0, 1); // 6
    queue.cancel('a'); // 7: pending -> cancelled
    queue.remove('b'); // 8

    expect(notifications, 8);
    expect(queue.byId('a')?.status, TranscriptionJobStatus.cancelled);
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
    final db = AppDatabase.open();
    addTearDown(db.close);
    final repo = TranscriptRepo(db);

    final queue = TranscriptionQueue()
      ..add(
        TranscriptionJob(
          id: 'a',
          audioPath: 'content://media/external/audio/49',
          displayName: 'meeting 49.mp3',
        ),
      );
    final service = _RecordingService();
    final worker = QueueWorker(
      queue,
      service,
      const EngineModelSpec(path: 'm.onnx', family: 'sensevoice', quant: 'q4_k'),
      transcriptRepo: repo,
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
    // The saved row records the run's model family, not just its path.
    expect(repo.list().single.modelFamily, 'sensevoice');
    expect(repo.list().single.title, 'meeting 49.mp3');
  });

  test('a cancelled job is never persisted and ends as cancelled', () async {
    final db = AppDatabase.open();
    addTearDown(db.close);
    final repo = TranscriptRepo(db);

    final queue = TranscriptionQueue();
    queue.add(job('a'));
    // The service blocks like a real native call and throws once the queue
    // marks the job cancelling — exactly the cooperative contract.
    final service = _BlockingService();
    final worker = QueueWorker(
      queue,
      service,
      const EngineModelSpec(path: 'm.onnx', family: 'sensevoice'),
      transcriptRepo: repo,
    );

    final running = worker.run();
    // Let the worker claim the job and reach the "native" await.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(queue.byId('a')?.status, TranscriptionJobStatus.running);

    queue.cancel('a'); // running -> cancelling, isCancelled now true
    await running;

    expect(queue.byId('a')?.status, TranscriptionJobStatus.cancelled);
    expect(repo.list(), isEmpty); // a cancelled result is not a success
  });

  test('a result landing after a cancel request is discarded', () async {
    final db = AppDatabase.open();
    addTearDown(db.close);
    final repo = TranscriptRepo(db);

    final queue = TranscriptionQueue();
    queue.add(job('a'));
    // The service finishes "successfully" only after we release it, which
    // models a native call that returns after the user asked to stop.
    final service = _GatedService();
    final worker = QueueWorker(
      queue,
      service,
      const EngineModelSpec(path: 'm.onnx', family: 'sensevoice'),
      transcriptRepo: repo,
    );

    final running = worker.run();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    queue.cancel('a');
    service.release.complete();
    await running;

    expect(queue.byId('a')?.status, TranscriptionJobStatus.cancelled);
    expect(repo.list(), isEmpty); // the text was thrown away, not saved
  });

  test('worker exposes the current processing stage on the job', () async {
    final queue = TranscriptionQueue()..add(job('a'));
    final service = _GatedService();
    final worker = QueueWorker(
      queue,
      service,
      const EngineModelSpec(path: 'm.onnx', family: 'sensevoice'),
    );

    final running = worker.run();
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(queue.byId('a')?.status, TranscriptionJobStatus.running);
    expect(queue.byId('a')?.stage, TranscriptionStage.loadingModel);

    service.release.complete();
    await running;
    expect(queue.byId('a')?.stage, isNull);
  });
}

/// Polls [isCancelled] like a real chunk loop and throws once it is true.
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
    void Function(TranscriptionStage stage)? onStage,
    void Function(TranscribeProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    while (!(isCancelled?.call() ?? false)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    throw const EngineCancelledException('stopped between chunks');
  }
}

/// Finishes successfully, but only once [release] is completed.
class _GatedService extends TranscriptionService {
  _GatedService() : super(engine: const UnavailableAsrEngine());

  final release = Completer<void>();

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
    onStage?.call(TranscriptionStage.loadingModel);
    await release.future;
    return TranscriptionJobResult(
      text: 'late success',
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
