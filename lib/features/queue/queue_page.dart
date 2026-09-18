import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/audio/audio_picker.dart';
import '../../core/audio/audio_source.dart';
import '../../engine/asr_engine.dart';
import '../../data/transcript_repo.dart';
import '../../l10n/app_localizations.dart';
import '../models/model_library.dart';
import '../models/model_picker.dart';
import '../transcribe/transcription_service.dart';
import 'queue_worker.dart';
import 'transcription_queue.dart';

/// Queue tab: line up audio files and run them one at a time.
///
/// Uses the same shared [AppState] as the transcribe page, so the chosen model,
/// its family/quant, the backend, the chunk settings and the "an engine is
/// busy" flag are identical in both flows. A worker is built per run from the
/// current state and the queue is a [ChangeNotifier], so every real status
/// transition (claim, cancel, failure) repaints without a manual refresh.
class QueuePage extends StatefulWidget {
  const QueuePage({
    super.key,
    required this.engine,
    required this.transcriptRepo,
    this.state,
    this.service,
    this.modelLibrary,
    this.onManageModels,
  });

  final AsrEngine engine;
  final TranscriptRepo transcriptRepo;

  /// App-wide settings shared with the transcribe page. Null only in tests.
  final AppState? state;

  /// Service seam for tests; production builds one from [engine].
  final TranscriptionService? service;
  final ModelLibrary? modelLibrary;
  final VoidCallback? onManageModels;

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  final _queue = TranscriptionQueue();
  QueueWorker? _worker;

  /// Monotonic suffix so the same file added twice yields two distinct ids
  /// instead of one job shadowing the other.
  int _seq = 0;

  /// The full catalog spec shared with the transcribe page, companions included.
  EngineModelSpec? get _modelSpec => widget.state?.modelSpec;

  /// Shared, persisted model path; a pick in either page updates the same value.
  String? get _modelPath => _modelSpec?.path;

  bool get _running => _worker?.running ?? false;

  /// True when another page's run owns the shared engine; this page must not
  /// start a second one on top of it.
  bool get _engineBusyElsewhere =>
      (widget.state?.engineBusy ?? false) && !_running;

  bool get _needsDecoder =>
      widget.state?.selectionNeedsMissingCompanion ?? false;

  /// Neural mode needs a real VAD model on disk; without one the queue must not
  /// start (and must not silently fall back to the energy gate).
  bool get _needsVadModel =>
      (widget.state?.chunkStrategy ?? ChunkStrategy.fixed) ==
          ChunkStrategy.neural &&
      !(widget.state?.neuralVadReady ?? false);

  @override
  void dispose() {
    _queue.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    if (_running) return; // a run owns the current queue
    final l10n = AppLocalizations.of(context);
    final files = await const AudioPicker().pickMany(
      typeLabel: l10n.fileTypeAudio,
    );
    if (!mounted) return;
    if (files.isEmpty) return;
    setState(() {
      for (final file in files) {
        _queue.add(
          TranscriptionJob(
            id: '${file.source}#${_seq++}',
            audioPath: file.source,
            displayName: file.name,
          ),
        );
      }
    });
  }

  Future<void> _run() async {
    if (_running) return; // one worker at a time
    if (widget.state?.engineBusy ?? false) return; // another page is running
    final model = _modelSpec;
    if (model == null || _needsDecoder || _needsVadModel) return;
    final state = widget.state;
    // A cancel replaces the VAD worker; make sure the run starts on a fresh one.
    state?.resetVadEngine();
    final worker = QueueWorker(
      _queue,
      widget.service ??
          TranscriptionService(
            engine: widget.engine,
            vadEngine: state?.activeVadEngine,
            decoderPreference:
                state?.audioDecoderPreference ??
                AudioDecoderPreference.automatic,
          ),
      model,
      transcriptRepo: widget.transcriptRepo,
      chunkSettings: state?.chunkSettings,
      neuralVad: state?.neuralVadSettings,
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

  /// Asks one job to stop. A still-queued job is cancelled immediately; a
  /// running one enters "cancelling" and the engine is asked to abort so the
  /// in-flight native block ends at its next safe boundary.
  void _cancelJob(TranscriptionJob job) {
    final wasRunning = job.status == TranscriptionJobStatus.running;
    if (!_queue.cancel(job.id)) return;
    if (wasRunning && widget.engine is CancellableAsrEngine) {
      // Cooperative: the engine refuses later chunks and surfaces the abort
      // once the native call in flight returns.
      (widget.engine as CancellableAsrEngine).cancel();
    }
    if (wasRunning) {
      // Neural VAD plans on its own worker, so a cancel must reach that one too.
      widget.state?.cancelVad();
    }
    setState(() {});
  }

  Future<void> _pickModel() async {
    if (_running) return; // a run owns the current model
    final state = widget.state;
    final library = widget.modelLibrary;
    if (state == null || library == null) return;
    await showDownloadedModelPicker(
      context: context,
      library: library,
      state: state,
      onManageModels: widget.onManageModels,
    );
  }

  String _statusLabel(AppLocalizations l10n, TranscriptionJobStatus status) =>
      switch (status) {
        TranscriptionJobStatus.pending => l10n.queueStatusPending,
        TranscriptionJobStatus.running => l10n.queueStatusRunning,
        TranscriptionJobStatus.cancelling => l10n.queueStatusCancelling,
        TranscriptionJobStatus.done => l10n.queueStatusDone,
        TranscriptionJobStatus.failed => l10n.queueStatusFailed,
        TranscriptionJobStatus.cancelled => l10n.queueStatusCancelled,
      };

  String _stageLabel(AppLocalizations l10n, TranscriptionStage stage) =>
      switch (stage) {
        TranscriptionStage.decoding => l10n.transcribeStageDecoding,
        TranscriptionStage.analyzing => l10n.transcribeStageAnalyzing,
        TranscriptionStage.segmenting => l10n.transcribeStageSegmenting,
        TranscriptionStage.loadingModel => l10n.transcribeStageLoadingModel,
        TranscriptionStage.transcribing => l10n.transcribeStageTranscribing,
        TranscriptionStage.finalizing => l10n.transcribeStageFinalizing,
      };

  String _jobStatusLabel(AppLocalizations l10n, TranscriptionJob job) {
    final stage = job.stage;
    if (job.status == TranscriptionJobStatus.running && stage != null) {
      return _stageLabel(l10n, stage);
    }
    return _statusLabel(l10n, job.status);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    // Rebuild on queue transitions and on the shared state's busy flag, so a
    // run started on the transcribe page disables this one too.
    return ListenableBuilder(
      listenable: state == null ? _queue : Listenable.merge([_queue, state]),
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final jobs = _queue.jobs;
    final running = _running;
    final modelPath = _modelPath;
    final needsDecoder = _needsDecoder;
    final needsVad = _needsVadModel;
    final busyElsewhere = _engineBusyElsewhere;

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
                  onPressed:
                      running ||
                          busyElsewhere ||
                          widget.state == null ||
                          widget.modelLibrary == null
                      ? null
                      : _pickModel,
                  icon: const Icon(Icons.model_training_outlined),
                  label: modelPath == null
                      ? Text(l10n.queueChooseModel)
                      : SelectedModelName(
                          library: widget.modelLibrary,
                          state: widget.state!,
                          emptyLabel: l10n.queueChooseModel,
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
        if (busyElsewhere)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _Note(
              icon: Icons.sync,
              text: l10n.engineBusyNote,
              color: scheme.onSurfaceVariant,
            ),
          ),
        if (needsVad)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _Note(
              icon: Icons.warning_amber_rounded,
              text: l10n.vadModelRequired,
              color: scheme.error,
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.icon(
            onPressed:
                modelPath != null &&
                    !needsDecoder &&
                    !needsVad &&
                    _queue.hasPending &&
                    !running &&
                    !busyElsewhere
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
                      title: Text(
                        job.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        job.error ?? _jobStatusLabel(l10n, job),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: _actions(l10n, job, index, jobs.length),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Per-row controls: reorder/remove while pending, cancel while running,
  /// retry/remove once failed or cancelled.
  Widget _actions(
    AppLocalizations l10n,
    TranscriptionJob job,
    int index,
    int count,
  ) {
    final status = job.status;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (status == TranscriptionJobStatus.pending) ...[
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: l10n.queueMoveUp,
            icon: const Icon(Icons.arrow_upward, size: 18),
            onPressed: index == 0
                ? null
                : () => setState(() => _queue.reorder(index, index - 1)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: l10n.queueMoveDown,
            icon: const Icon(Icons.arrow_downward, size: 18),
            onPressed: index >= count - 1
                ? null
                : () => setState(() => _queue.reorder(index, index + 1)),
          ),
        ],
        if (status == TranscriptionJobStatus.running)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: l10n.queueCancel,
            icon: const Icon(Icons.cancel_outlined, size: 18),
            onPressed: () => _cancelJob(job),
          ),
        if (status == TranscriptionJobStatus.cancelling)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (status == TranscriptionJobStatus.failed ||
            status == TranscriptionJobStatus.cancelled)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: l10n.queueRetry,
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: () {
              // A cancelled run left the VAD worker flag set; a retry needs a
              // fresh worker, not the one that was told to abort.
              widget.state?.resetVadEngine();
              setState(() => _queue.retry(job.id));
            },
          ),
        if (status != TranscriptionJobStatus.running &&
            status != TranscriptionJobStatus.cancelling)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: l10n.queueRemove,
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _queue.remove(job.id)),
          ),
      ],
    );
  }

  IconData _icon(TranscriptionJobStatus status) => switch (status) {
    TranscriptionJobStatus.pending => Icons.schedule,
    TranscriptionJobStatus.running => Icons.sync,
    TranscriptionJobStatus.cancelling => Icons.hourglass_bottom,
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
