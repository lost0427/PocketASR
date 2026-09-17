import '../../core/audio/chunk_planner.dart';
import '../../engine/asr_engine.dart';
import '../../data/transcript_repo.dart';
import '../transcribe/transcription_service.dart';
import 'transcription_queue.dart';

/// Runs a [TranscriptionQueue] through one service, one job at a time.
///
/// Cancellation is cooperative and owned by the page that started the run: it
/// flips the job to [TranscriptionJobStatus.cancelling] and, when the engine is
/// a [CancellableAsrEngine], asks it to `cancel()`. This worker only polls
/// [isCancelling] through the service so the abort lands at the next chunk
/// boundary, and it never persists a cancelled job's text.
class QueueWorker {
  QueueWorker(
    this.queue,
    this.service,
    this.model, {
    this.transcriptRepo,
    this.chunkSettings,
    this.neuralVad,
    this.backend = Backend.cpu,
  });

  final TranscriptionQueue queue;
  final TranscriptionService service;
  final EngineModelSpec model;
  final TranscriptRepo? transcriptRepo;

  /// Chunking handed to every job; null keeps the service's single-request path
  /// (or, in neural mode, is null because [neuralVad] is set instead).
  final ChunkSettings? chunkSettings;

  /// Real neural VAD settings handed to every job. Mutually exclusive with
  /// [chunkSettings] — the service rejects both at once.
  final NeuralVadSettings? neuralVad;

  final Backend backend;
  bool _running = false;

  bool get running => _running;

  Future<void> run() async {
    if (_running) return;
    _running = true;
    try {
      // Claim until nothing is pending: a job cancelled while queued is never
      // claimed, and a job cancelled mid-run is drained as cancelled.
      while (true) {
        final job = queue.claimNext();
        if (job == null) break;
        final id = job.id;
        try {
          final result = await service.transcribe(
            audioPath: job.audioPath,
            model: model,
            backend: backend,
            chunkSettings: chunkSettings,
            neuralVad: neuralVad,
            onStage: (stage) => queue.updateStage(id, stage),
            isCancelled: () => queue.isCancelling(id),
          );
          // A cancel that landed after the engine returned: discard the text
          // (a cancelled job must not be persisted as a success) and report it
          // as cancelled.
          if (queue.isCancelling(id)) {
            queue.markCancelled(id);
            continue;
          }
          transcriptRepo?.insert(
            title: job.displayName,
            text: result.text,
            audioPath: job.audioPath,
            audioSeconds: result.audioDuration.inMilliseconds / 1000,
            engine: result.engine,
            modelFamily: result.model.family,
            modelPath: result.model.path,
            backend: result.backend.name,
            rtf: result.rtf,
            tokens: result.tokens,
            totalMs: result.elapsed.inMilliseconds,
            avgTokensPerSec: result.avgTokensPerSec,
          );
          queue.complete(id);
        } on EngineCancelledException {
          // Requested cancellation, surfaced when the native call returned.
          queue.markCancelled(id);
        } catch (error) {
          if (queue.isCancelling(id)) {
            queue.markCancelled(id);
          } else {
            queue.fail(id, error.toString());
          }
        }
      }
    } finally {
      _running = false;
    }
  }
}
