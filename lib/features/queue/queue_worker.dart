import '../../engine/asr_engine.dart';
import '../../data/transcript_repo.dart';
import '../transcribe/transcription_service.dart';
import 'transcription_queue.dart';

class QueueWorker {
  QueueWorker(this.queue, this.service, this.model, {this.transcriptRepo});

  final TranscriptionQueue queue;
  final TranscriptionService service;
  final EngineModelSpec model;
  final TranscriptRepo? transcriptRepo;
  bool _running = false;

  bool get running => _running;

  Future<void> run() async {
    if (_running) return;
    _running = true;
    try {
      while (queue.hasPending) {
        final job = queue.claimNext();
        if (job == null) break;
        try {
          final result = await service.transcribe(
            audioPath: job.audioPath,
            model: model,
          );
          transcriptRepo?.insert(
            title: job.audioPath.split(RegExp(r'[\\/]')).last,
            text: result.text,
            audioPath: job.audioPath,
            audioSeconds: result.audioDuration.inMilliseconds / 1000,
            engine: result.engine,
            modelPath: result.model.path,
            backend: result.backend.name,
            rtf: result.rtf,
            tokens: result.tokens,
            totalMs: result.elapsed.inMilliseconds,
            avgTokensPerSec: result.avgTokensPerSec,
          );
          queue.complete(job.id);
        } catch (error) {
          queue.fail(job.id, error.toString());
        }
      }
    } finally {
      _running = false;
    }
  }
}
