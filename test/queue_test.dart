import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/features/queue/transcription_queue.dart';

TranscriptionJob job(String id) =>
    TranscriptionJob(id: id, audioPath: 'audio/$id.wav');

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
}
