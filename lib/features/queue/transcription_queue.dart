/// Lifecycle of a queued transcription.
enum TranscriptionJobStatus {
  pending,
  running,
  done,
  failed,
  cancelled,
}

/// A single transcription request waiting to run.
///
/// Status, [attempts] and [error] are mutable; the queue owns those
/// transitions, callers only read them.
class TranscriptionJob {
  TranscriptionJob({required this.id, required this.audioPath});

  final String id;
  final String audioPath;

  TranscriptionJobStatus status = TranscriptionJobStatus.pending;

  /// How many times the job has been claimed (starts at 1 on first run).
  int attempts = 0;

  /// Last failure message, or null.
  String? error;

  bool get isFinished =>
      status == TranscriptionJobStatus.done ||
      status == TranscriptionJobStatus.cancelled;

  @override
  String toString() => 'TranscriptionJob($id, $status)';
}

/// In-memory FIFO queue of [TranscriptionJob]s. No engine, no persistence —
/// callers drive it with [claimNext]/[complete]/[fail].
class TranscriptionQueue {
  final List<TranscriptionJob> _jobs = [];

  /// Snapshot of the queue in run order.
  List<TranscriptionJob> get jobs => List.unmodifiable(_jobs);

  int get length => _jobs.length;

  bool get isEmpty => _jobs.isEmpty;

  TranscriptionJob? byId(String id) {
    for (final job in _jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  /// Appends [job] to the back of the queue.
  void add(TranscriptionJob job) => _jobs.add(job);

  /// Drops the job with [id]. Returns false when it wasn't queued.
  bool remove(String id) {
    final index = _jobs.indexWhere((job) => job.id == id);
    if (index < 0) return false;
    _jobs.removeAt(index);
    return true;
  }

  /// Moves the job at [oldIndex] to [newIndex] (indices as seen before the
  /// move). Returns false when either index is out of range.
  bool reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _jobs.length ||
        newIndex < 0 ||
        newIndex >= _jobs.length) {
      return false;
    }
    if (oldIndex == newIndex) return true;
    final job = _jobs.removeAt(oldIndex);
    _jobs.insert(newIndex, job);
    return true;
  }

  /// Cancels a job that hasn't finished. Returns false when [id] is unknown or
  /// already done/cancelled.
  bool cancel(String id) {
    final job = byId(id);
    if (job == null || job.isFinished) return false;
    job.status = TranscriptionJobStatus.cancelled;
    return true;
  }

  /// Puts a failed job back at the end of the queue. Returns false unless [id]
  /// is a failed job.
  bool retry(String id) {
    final job = byId(id);
    if (job == null || job.status != TranscriptionJobStatus.failed) {
      return false;
    }
    job.status = TranscriptionJobStatus.pending;
    job.error = null;
    return true;
  }

  /// Claims the first pending job, marks it running and bumps its attempts.
  /// Returns null when nothing is pending.
  TranscriptionJob? claimNext() {
    for (final job in _jobs) {
      if (job.status == TranscriptionJobStatus.pending) {
        job.status = TranscriptionJobStatus.running;
        job.attempts++;
        return job;
      }
    }
    return null;
  }

  /// Marks a running job done. Returns false when it isn't running.
  bool complete(String id) {
    final job = byId(id);
    if (job == null || job.status != TranscriptionJobStatus.running) {
      return false;
    }
    job.status = TranscriptionJobStatus.done;
    return true;
  }

  /// Marks a running job failed with [error]. Returns false when it isn't
  /// running.
  bool fail(String id, [String? error]) {
    final job = byId(id);
    if (job == null || job.status != TranscriptionJobStatus.running) {
      return false;
    }
    job.status = TranscriptionJobStatus.failed;
    job.error = error;
    return true;
  }
}
