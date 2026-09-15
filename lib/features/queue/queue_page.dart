import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../engine/asr_engine.dart';
import '../transcribe/transcription_service.dart';
import 'queue_worker.dart';
import 'transcription_queue.dart';

class QueuePage extends StatefulWidget {
  const QueuePage({super.key, required this.engine});

  final AsrEngine engine;

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  final _queue = TranscriptionQueue();
  QueueWorker? _worker;

  Future<void> _add() async {
    final files = await openFiles(acceptedTypeGroups: const [
      XTypeGroup(label: 'Audio', extensions: ['wav', 'm4a', 'mp3', 'flac']),
    ]);
    if (!mounted) return;
    setState(() {
      for (final file in files) {
        _queue.add(TranscriptionJob(id: file.path, audioPath: file.path));
      }
    });
  }

  Future<void> _run() async {
    final worker = QueueWorker(
      _queue,
      TranscriptionService(engine: widget.engine),
      const EngineModelSpec(path: ''),
    );
    _worker = worker;
    await worker.run();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final jobs = _queue.jobs;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Expanded(child: OutlinedButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add audio'))),
            const SizedBox(width: 12),
            Expanded(child: FilledButton.icon(onPressed: _queue.hasPending && !(_worker?.running ?? false) ? _run : null, icon: const Icon(Icons.play_arrow), label: const Text('Run queue'))),
          ]),
        ),
        Expanded(
          child: jobs.isEmpty
              ? const Center(child: Text('Queue is empty'))
              : ListView.builder(
                  itemCount: jobs.length,
                  itemBuilder: (_, index) {
                    final job = jobs[index];
                    return ListTile(
                      leading: Icon(_icon(job.status)),
                      title: Text(job.audioPath.split(RegExp(r'[\\/]')).last),
                      subtitle: Text(job.error ?? job.status.name),
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: job.status == TranscriptionJobStatus.pending ? () { setState(() => _queue.remove(job.id)); } : null,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  IconData _icon(TranscriptionJobStatus status) => switch (status) {
    TranscriptionJobStatus.pending => Icons.schedule,
    TranscriptionJobStatus.running => Icons.sync,
    TranscriptionJobStatus.done => Icons.check_circle,
    TranscriptionJobStatus.failed => Icons.error,
    TranscriptionJobStatus.cancelled => Icons.cancel,
  };
}
