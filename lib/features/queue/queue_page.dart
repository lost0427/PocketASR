import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../engine/asr_engine.dart';
import '../../data/transcript_repo.dart';
import '../../l10n/app_localizations.dart';
import '../transcribe/transcription_service.dart';
import 'queue_worker.dart';
import 'transcription_queue.dart';

/// Queue tab: line up audio files and run them one at a time.
///
/// Uses the same shared [AppState] as the transcribe page, so the chosen model,
/// its family/quant, the backend and the chunk settings are identical in both
/// flows. A worker is built per run from the current state.
class QueuePage extends StatefulWidget {
  const QueuePage({
    super.key,
    required this.engine,
    required this.transcriptRepo,
    this.state,
    this.service,
  });

  final AsrEngine engine;
  final TranscriptRepo transcriptRepo;

  /// App-wide settings shared with the transcribe page. Null only in tests.
  final AppState? state;

  /// Service seam for tests; production builds one from [engine].
  final TranscriptionService? service;

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  final _queue = TranscriptionQueue();
  QueueWorker? _worker;

  /// Model path used only when no [AppState] is injected.
  String? _localModelPath;

  /// The full model spec shared with the transcribe page, companions included;
  /// the local path is only the no-AppState test seam.
  EngineModelSpec? get _modelSpec {
    final state = widget.state;
    if (state != null) return state.modelSpec;
    final path = _localModelPath;
    return path == null ? null : EngineModelSpec(path: path);
  }

  /// Shared, persisted model path; a pick in either page updates the same value.
  String? get _modelPath => _modelSpec?.path;

  bool get _running => _worker?.running ?? false;

  bool get _needsDecoder =>
      widget.state?.selectionNeedsMissingCompanion ?? false;

  Future<void> _add() async {
    if (_running) return; // a run owns the current queue
    final l10n = AppLocalizations.of(context);
    final files = await openFiles(
      acceptedTypeGroups: [
        XTypeGroup(
          label: l10n.fileTypeAudio,
          extensions: const ['wav', 'm4a', 'mp3', 'flac'],
        ),
      ],
    );
    if (!mounted) return;
    setState(() {
      for (final file in files) {
        _queue.add(TranscriptionJob(id: file.path, audioPath: file.path));
      }
    });
  }

  Future<void> _run() async {
    if (_running) return; // one worker at a time
    final model = _modelSpec;
    if (model == null || _needsDecoder) return;
    final state = widget.state;
    final worker = QueueWorker(
      _queue,
      widget.service ?? TranscriptionService(engine: widget.engine),
      model,
      transcriptRepo: widget.transcriptRepo,
      chunkSettings: state?.chunkSettings,
      backend: state?.backend ?? Backend.cpu,
    );
    _worker = worker;
    state?.engineBusy = true; // the Models page must not swap this instance
    setState(() {}); // disable the controls that would change this run
    try {
      await worker.run();
    } finally {
      state?.engineBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _pickModel() async {
    if (_running) return; // a run owns the current model
    final l10n = AppLocalizations.of(context);
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: l10n.fileTypeModel,
          extensions: const ['gguf', 'onnx', 'bin'],
        ),
      ],
    );
    if (!mounted || file == null) return;
    _localModelPath = file.path;
    widget.state?.modelPath = file.path;
    setState(() {});
  }

  String _statusLabel(AppLocalizations l10n, TranscriptionJobStatus status) =>
      switch (status) {
        TranscriptionJobStatus.pending => l10n.queueStatusPending,
        TranscriptionJobStatus.running => l10n.queueStatusRunning,
        TranscriptionJobStatus.done => l10n.queueStatusDone,
        TranscriptionJobStatus.failed => l10n.queueStatusFailed,
        TranscriptionJobStatus.cancelled => l10n.queueStatusCancelled,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final jobs = _queue.jobs;
    final running = _running;
    final modelPath = _modelPath;
    final needsDecoder = _needsDecoder;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: running ? null : _add,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.queueAddAudio),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: running ? null : _pickModel,
                  icon: const Icon(Icons.model_training_outlined),
                  label: Text(
                    modelPath == null
                        ? l10n.queueChooseModel
                        : l10n.queueChangeModel,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (needsDecoder)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _Note(
              icon: Icons.warning_amber_rounded,
              text: l10n.modelNeedsDecoder,
              color: scheme.error,
            ),
          )
        else if (widget.state?.modelSelectionMissing ?? false)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _Note(
              icon: Icons.warning_amber_rounded,
              text: l10n.modelSelectionMissing,
              color: scheme.error,
            ),
          )
        else if (modelPath == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _Note(
              icon: Icons.info_outline,
              text: l10n.queueModelRequired,
              color: scheme.onSurfaceVariant,
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.icon(
            onPressed: modelPath != null && !needsDecoder && _queue.hasPending && !running
                ? _run
                : null,
            icon: const Icon(Icons.play_arrow),
            label: Text(l10n.queueRun),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: jobs.isEmpty
              ? Center(child: Text(l10n.queueEmpty))
              : ListView.builder(
                  itemCount: jobs.length,
                  itemBuilder: (_, index) {
                    final job = jobs[index];
                    return ListTile(
                      leading: Icon(_icon(job.status)),
                      title: Text(job.audioPath.split(RegExp(r'[\\/]')).last),
                      subtitle: Text(
                        job.error ?? _statusLabel(l10n, job.status),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: job.status == TranscriptionJobStatus.pending
                            ? () {
                                setState(() => _queue.remove(job.id));
                              }
                            : null,
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

/// One-line note under the controls: why the queue cannot run yet.
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}
