import '../../engine/asr_engine.dart';
import '../transcribe/transcription_service.dart';
import 'transcription_queue.dart';

class QueueWorker {
  QueueWorker(this.queue, this.service, this.model);

  final TranscriptionQueue queue;
  final TranscriptionService service;
  final EngineModelSpec model;
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
          await service.transcribe(
            audioPath: job.audioPath,
            model: model,
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
