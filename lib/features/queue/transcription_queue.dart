import 'package:flutter/foundation.dart';

import '../transcribe/transcription_stage.dart';

/// Lifecycle of a queued transcription.
///
/// [cancelling] is the cooperative window the running job spends between
/// "the user asked to stop" and "the native block that was already running
/// returned": the engine cannot be hard-killed mid-call, so the job is aborted
/// at the next safe boundary (see [CancellableAsrEngine]).
enum TranscriptionJobStatus {
  pending,
  running,
  cancelling,
  done,
  failed,
  cancelled,
}

/// A single transcription request waiting to run.
///
/// Status, [attempts] and [error] are mutable; the queue owns those
/// transitions, callers only read them.
class TranscriptionJob {
  TranscriptionJob({
    required this.id,
    required this.audioPath,
    String? displayName,
  }) : displayName = displayName ?? audioPath.split(RegExp(r'[\\/]')).last;

  /// Unique id for this queued entry. Two entries may point at the same
  /// [audioPath] — the queue keys on [id], never on the path, so adding the
  /// same file twice cannot make one job shadow the other.
  final String id;
  final String audioPath;
  final String displayName;

  TranscriptionJobStatus status = TranscriptionJobStatus.pending;

  /// How many times the job has been claimed (starts at 1 on first run).
  int attempts = 0;

  /// Last failure message, or null.
  String? error;

  /// Current processing phase while [status] is running.
  TranscriptionStage? stage;

  bool get isFinished =>
      status == TranscriptionJobStatus.done ||
      status == TranscriptionJobStatus.cancelled;

  @override
  String toString() => 'TranscriptionJob($id, $status)';
}

/// In-memory FIFO queue of [TranscriptionJob]s. No engine, no persistence —
/// callers drive it with [claimNext]/[complete]/[fail].
///
/// Notifies after every accepted mutation so a page can rebuild from real
/// status transitions (a worker claim, a cancel, a failure) without polling.
class TranscriptionQueue extends ChangeNotifier {
  final List<TranscriptionJob> _jobs = [];

  /// Snapshot of the queue in run order.
  List<TranscriptionJob> get jobs => List.unmodifiable(_jobs);

  bool get hasPending =>
      _jobs.any((job) => job.status == TranscriptionJobStatus.pending);

  int get length => _jobs.length;

  bool get isEmpty => _jobs.isEmpty;

  TranscriptionJob? byId(String id) {
    for (final job in _jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  /// Appends [job] to the back of the queue.
  void add(TranscriptionJob job) {
    _jobs.add(job);
    notifyListeners();
  }

  /// Drops the job with [id]. Returns false when it wasn't queued.
  bool remove(String id) {
    final index = _jobs.indexWhere((job) => job.id == id);
    if (index < 0) return false;
    _jobs.removeAt(index);
    notifyListeners();
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
    notifyListeners();
    return true;
  }

  /// Requests cancellation of a job that hasn't finished.
  ///
  /// A still-queued job is [TranscriptionJobStatus.cancelled] at once; a
  /// running one enters [TranscriptionJobStatus.cancelling] and finishes as
  /// [TranscriptionJobStatus.cancelled] once the worker observes the abort.
  /// Returns false when [id] is unknown, already finished, or already
  /// cancelling.
  bool cancel(String id) {
    final job = byId(id);
    if (job == null || job.isFinished) return false;
    if (job.status == TranscriptionJobStatus.cancelling) return false;
    job.status = job.status == TranscriptionJobStatus.pending
        ? TranscriptionJobStatus.cancelled
        : TranscriptionJobStatus.cancelling;
    job.stage = null;
    notifyListeners();
    return true;
  }

  /// True while [id]'s running job has been asked to stop but has not yet
  /// returned — the state the worker's `isCancelled` poll reads.
  bool isCancelling(String id) =>
      byId(id)?.status == TranscriptionJobStatus.cancelling;

  /// Marks a running/cancelling job cancelled after the worker aborted it.
  bool markCancelled(String id) {
    final job = byId(id);
    if (job == null) return false;
    if (job.status != TranscriptionJobStatus.running &&
        job.status != TranscriptionJobStatus.cancelling) {
      return false;
    }
    job.status = TranscriptionJobStatus.cancelled;
    job.stage = null;
    notifyListeners();
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
    job.stage = null;
    notifyListeners();
    return true;
  }

  /// Claims the first pending job, marks it running and bumps its attempts.
  /// Returns null when nothing is pending.
  TranscriptionJob? claimNext() {
    for (final job in _jobs) {
      if (job.status == TranscriptionJobStatus.pending) {
        job.status = TranscriptionJobStatus.running;
        job.stage = null;
        job.attempts++;
        notifyListeners();
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
    job.stage = null;
    notifyListeners();
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
    job.stage = null;
    notifyListeners();
    return true;
  }

  /// Updates the visible processing phase of a running job.
  bool updateStage(String id, TranscriptionStage stage) {
    final job = byId(id);
    if (job == null || job.status != TranscriptionJobStatus.running) {
      return false;
    }
    if (job.stage == stage) return true;
    job.stage = stage;
    notifyListeners();
    return true;
  }
}
