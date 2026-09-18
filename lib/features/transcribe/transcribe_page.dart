import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/asr_engine.dart';
import '../../engine/system_metrics.dart';
import '../../app/app_state.dart';
import '../../data/transcript_repo.dart';
import '../../core/audio/audio_picker.dart';
import '../../core/audio/audio_preprocessor.dart';
import '../../core/audio/audio_source.dart';
import '../../core/audio/pcm_file.dart';
import '../../core/text/token_counter.dart';
import '../models/model_library.dart';
import '../models/model_picker.dart';
import 'transcription_service.dart';
import 'recording_controls.dart';
import '../../l10n/app_localizations.dart';

/// Transcribe tab.
///
/// Lays out the whole single-file flow and its honest empty states, and asks
/// the injected [AsrEngine] what it can actually do. Production passes
/// `AppState.engine` (sherpa-onnx by default); when that engine's runtime
/// capabilities say unavailable, every control that needs it stays disabled and
/// the banner shows why — the page never pretends a transcript happened.
class TranscribePage extends StatefulWidget {
  const TranscribePage({
    super.key,
    required this.engine,
    this.state,
    this.transcriptRepo,
    this.service,
    this.metricsSamplerFactory,
    this.modelLibrary,
    this.onManageModels,
  });

  /// The engine to report status for; resolved from `AppState.engine` in
  /// production and injected directly in tests.
  final AsrEngine engine;

  /// App-wide settings shared with the queue page: model path, family, quant,
  /// backend, loudness and chunk settings all come from here. Null only in
  /// tests that exercise the page without an [AppState].
  final AppState? state;

  final TranscriptRepo? transcriptRepo;
  final TranscriptionService? service;
  final ModelLibrary? modelLibrary;
  final VoidCallback? onManageModels;

  /// Builds the process metrics sampler used only while a run is active.
  /// Tests inject a sampler with fixed readings; production uses the real
  /// [/proc] reader, which honestly reports null where it cannot measure.
  final SystemMetricsSampler Function()? metricsSamplerFactory;

  @override
  State<TranscribePage> createState() => _TranscribePageState();
}

class _TranscribePageState extends State<TranscribePage> {
  late Future<EngineCapabilities> _capabilities;

  String? _fileName;
  String? _filePath;

  /// The full catalog spec shared with the queue page, companions included.
  EngineModelSpec? get _modelSpec => widget.state?.modelSpec;

  /// Shared, persisted model path; a pick in either page updates the same value.
  String? get _modelPath => _modelSpec?.path;

  // Live run state, all rewritten from real engine progress.
  String _result = '';
  String _partialText = '';
  double? _progress;
  TranscriptionStage? _stage;
  bool _running = false;
  bool _recordingBusy = false;
  String? _error;

  double? _charsPerSec;
  Duration? _elapsed;
  double? _rtf;
  Backend? _runBackend;
  AudioDecoderInfo? _decoderInfo;

  /// Process readings taken only while a run is active; null means "not
  /// measured", which renders as `—` rather than a made-up number.
  double? _cpuPercent;
  int? _memoryBytes;

  /// Periodic sampler driving the CPU/memory tiles during a run.
  Timer? _metricsTimer;
  bool _sampling = false;

  /// Set when the user cancels the running job or its VAD plan; polled by the
  /// service so the abort lands at the next safe boundary.
  bool _cancelRequested = false;

  /// The last real neural-VAD preview of the picked file, plus the settings it
  /// was produced with so a Settings change can be called out as stale.
  VadPreview? _vadPreview;
  String? _vadPreviewSignature;
  String? _vadPreviewError;
  bool _previewing = false;
  bool _previewCancelRequested = false;

  @override
  void initState() {
    super.initState();
    _capabilities = widget.engine.capabilities();
  }

  @override
  void dispose() {
    _metricsTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(TranscribePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Switching engines must re-probe: the cached future belongs to the old
    // engine, and its availability says nothing about the new one.
    if (!identical(widget.engine, oldWidget.engine)) {
      _capabilities = widget.engine.capabilities();
    }
  }

  /// Mirrors engine progress into the page. Character speed changes only when
  /// a chunk completes, then stays visible while the next chunk is running.
  void _onProgress(TranscribeProgress progress) {
    if (!mounted) return;
    final partial = progress.partialText.trim();
    final chunkText = progress.completedChunkText;
    final chunkElapsed = progress.completedChunkElapsed;
    setState(() {
      if (progress.ratio >= 0) _progress = progress.ratio;
      _elapsed = progress.elapsed;
      if (partial.isNotEmpty) {
        _partialText = partial;
      }
      if (chunkText != null && chunkElapsed != null) {
        _charsPerSec = graphemesPerSecond(chunkText, chunkElapsed);
      }
    });
  }

  void _onStage(TranscriptionStage stage) {
    if (!mounted) return;
    setState(() => _stage = stage);
  }

  String _stageLabel(AppLocalizations l10n, TranscriptionStage? stage) =>
      switch (stage) {
        TranscriptionStage.decoding => l10n.transcribeStageDecoding,
        TranscriptionStage.analyzing => l10n.transcribeStageAnalyzing,
        TranscriptionStage.segmenting => l10n.transcribeStageSegmenting,
        TranscriptionStage.loadingModel => l10n.transcribeStageLoadingModel,
        TranscriptionStage.transcribing => l10n.transcribeStageTranscribing,
        TranscriptionStage.finalizing => l10n.transcribeStageFinalizing,
        null => l10n.transcribeProgress,
      };

  void _notify(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickFile() async {
    if (_running) return; // a run owns the current file
    final l10n = AppLocalizations.of(context);
    final file = await const AudioPicker().pickOne(
      typeLabel: l10n.fileTypeAudio,
    );
    if (!mounted || file == null) return;
    setState(() {
      _filePath = file.source;
      _fileName = file.name;
      // A preview belongs to the file it was taken from.
      _vadPreview = null;
      _vadPreviewSignature = null;
      _vadPreviewError = null;
    });
  }

  /// The service for a run or a preview: injected in tests, otherwise the real
  /// ASR engine plus the independent (sherpa-onnx) VAD worker.
  TranscriptionService _service(AppState? state) =>
      widget.service ??
      TranscriptionService(
        engine: widget.engine,
        vadEngine: state?.activeVadEngine,
        decoderPreference:
            state?.audioDecoderPreference ?? AudioDecoderPreference.automatic,
        preprocessor: AudioPreprocessor(
          enabled: state?.loudnessEnabled ?? true,
          targetLufs: state?.loudnessTargetLufs ?? -16,
        ),
      );

  Future<void> _start() async {
    final l10n = AppLocalizations.of(context);
    final state = widget.state;
    if (state?.engineBusy ?? false) return; // another page owns the engine
    final model = _modelSpec;
    if (_filePath == null || model == null) {
      _notify(l10n.transcribeModelRequired);
      return;
    }
    if (state?.selectionNeedsMissingCompanion ?? false) {
      _notify(l10n.modelNeedsDecoder);
      return;
    }
    // Neural mode is only real when its own model is on disk: without it the
    // run is refused, never silently downgraded to the energy gate.
    final neuralVad = state?.neuralVadSettings;
    if (state?.chunkStrategy == ChunkStrategy.neural && neuralVad == null) {
      _notify(l10n.vadModelRequired);
      return;
    }
    // A previous cancel replaces the VAD worker; start this run on a fresh one.
    state?.resetVadEngine();
    final service = _service(state);
    state?.engineBusy = true; // the Models page must not swap this instance
    setState(() {
      _running = true;
      _error = null;
      _cancelRequested = false;
      _progress = 0;
      _stage = TranscriptionStage.decoding;
      _result = '';
      _partialText = '';
      _charsPerSec = null;
      _elapsed = null;
      _rtf = null;
      _runBackend = null;
      _decoderInfo = null;
      _cpuPercent = null;
      _memoryBytes = null;
    });
    _startMetricsSampling();
    try {
      final result = await service.transcribe(
        audioPath: _filePath!,
        model: model,
        backend: state?.backend ?? Backend.cpu,
        chunkSettings: state?.chunkSettings,
        neuralVad: neuralVad,
        onStage: (stage) {
          _onStage(stage);
          if (stage == TranscriptionStage.analyzing && mounted) {
            setState(() => _decoderInfo = service.lastDecoderInfo);
          }
        },
        onProgress: _onProgress,
        isCancelled: () => _cancelRequested,
      );
      // A cancel that landed after the engine returned is still a cancel: the
      // late text is dropped, never persisted and never shown as a success.
      if (_cancelRequested) return;
      // Saving the successful result is unchanged; only the live view grew.
      widget.transcriptRepo?.insert(
        title: _fileName ?? _filePath!,
        text: result.text,
        audioPath: _filePath,
        audioSeconds: result.audioDuration.inMilliseconds / 1000,
        engine: result.engine,
        modelFamily: result.model.family,
        modelPath: result.model.path,
        backend: result.backend.name,
        rtf: result.rtf,
        totalMs: result.elapsed.inMilliseconds,
      );
      if (mounted) {
        setState(() {
          _result = result.text;
          _partialText = '';
          _progress = 1;
          _elapsed = result.elapsed;
          _rtf = result.rtf;
          _runBackend = result.backend;
          _decoderInfo = result.decoderInfo;
          _charsPerSec = result.text.isEmpty
              ? null
              : graphemesPerSecond(result.text, result.elapsed);
        });
      }
    } catch (error) {
      // A user cancel is a state, not a failure; it must not turn into a red
      // error once the cooperative abort finally lands.
      if (mounted && !_cancelRequested) {
        setState(() => _error = error.toString());
      }
    } finally {
      _metricsTimer?.cancel();
      _metricsTimer = null;
      state?.engineBusy = false;
      // A cancelled run leaves the VAD worker's cancel flag set; drop it so a
      // retry starts clean.
      state?.resetVadEngine();
      if (mounted) {
        setState(() {
          _running = false;
          _stage = null;
        });
      }
    }
  }

  /// Asks the running job to stop. The engine refuses later chunks and the VAD
  /// worker is told too (a neural job may still be planning); both surface the
  /// abort at their next safe boundary.
  void _cancelRun() {
    if (!_running || _cancelRequested) return;
    setState(() => _cancelRequested = true);
    final engine = widget.engine;
    if (engine is CancellableAsrEngine) engine.cancel();
    widget.state?.cancelVad();
  }

  /// Runs the real neural VAD over the picked file *without* touching the ASR
  /// engine, so the user can see the windows a neural job would transcribe and
  /// re-run it after changing the Settings knobs.
  Future<void> _previewVad() async {
    final state = widget.state;
    final neuralVad = state?.neuralVadSettings;
    final path = _filePath;
    if (_previewing || _running || path == null || neuralVad == null) return;
    state?.resetVadEngine();
    setState(() {
      _previewing = true;
      _previewCancelRequested = false;
      _vadPreviewError = null;
    });
    try {
      final preview = await _service(state).previewVad(
        audioPath: path,
        neuralVad: neuralVad,
        isCancelled: () => _previewCancelRequested,
      );
      // A cancel that landed while planning drops the late plan, and a
      // disposed page has nowhere to show it.
      if (!mounted || _previewCancelRequested) return;
      setState(() {
        _vadPreview = preview;
        _vadPreviewSignature = state?.neuralVadSignature;
      });
    } catch (error) {
      if (mounted && !_previewCancelRequested) {
        setState(() => _vadPreviewError = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() {
          _previewing = false;
          // A cancelled preview needs a fresh worker for the next attempt.
          widget.state?.resetVadEngine();
        });
      }
    }
  }

  void _cancelPreview() {
    if (!_previewing || _previewCancelRequested) return;
    setState(() => _previewCancelRequested = true);
    widget.state?.cancelVad();
  }

  /// Samples process CPU/memory once a second while a run is in flight. The
  /// real sampler needs two readings for a CPU rate and stays null until it
  /// has them; nothing is estimated. The timer is cancelled in `finally` and in
  /// [dispose], so sampling never outlives the run or the page.
  void _startMetricsSampling() {
    _metricsTimer?.cancel();
    final sampler =
        (widget.metricsSamplerFactory ?? SystemMetricsSampler.new)();
    _metricsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _sampleMetrics(sampler),
    );
  }

  Future<void> _sampleMetrics(SystemMetricsSampler sampler) async {
    if (_sampling) return; // a slow read must not stack up
    _sampling = true;
    try {
      final metrics = await sampler.sample();
      if (!mounted) return; // the page went away mid-read
      setState(() {
        _cpuPercent = metrics.cpuPercent;
        _memoryBytes = metrics.memoryBytes;
      });
    } catch (_) {
      // A failed read is not a number: leave the tile at `—`.
    } finally {
      _sampling = false;
    }
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

  Future<void> _copy() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _result));
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l10n.transcribeCopied)));
  }

  String _backendLabel(
    EngineCapabilities? capabilities,
    AppLocalizations l10n,
  ) {
    // Once a run finished, the tile shows the backend that actually ran.
    final ran = _runBackend;
    if (ran != null) return ran.name.toUpperCase();
    final backends = capabilities?.backends ?? const <Backend>{};
    if (backends.isEmpty) return l10n.metricUnavailable;
    return backends.map((b) => b.name.toUpperCase()).join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    if (state == null) return _build(context);
    // Rebuild when the shared "engine busy" flag flips, so a run started on
    // the queue page disables this page's Start too.
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return FutureBuilder<EngineCapabilities>(
      future: _capabilities,
      builder: (context, snapshot) {
        final capabilities = snapshot.data;
        final engineAvailable = capabilities?.available ?? false;
        final running = _running;
        final modelPath = _modelPath;
        final needsDecoder =
            widget.state?.selectionNeedsMissingCompanion ?? false;
        final state = widget.state;
        final neuralSelected =
            (state?.chunkStrategy ?? ChunkStrategy.fixed) ==
            ChunkStrategy.neural;
        // Neural mode without its own model cannot start; no silent fallback.
        final needsVadModel =
            neuralSelected && !(state?.neuralVadReady ?? false);
        // Another page's run owns the shared engine; this one must not start.
        final busyElsewhere = (widget.state?.engineBusy ?? false) && !running;
        // Nothing starts without a model bundle, and an incomplete restored
        // selection (such as whisper without its decoder) is refused up front.
        final canStart =
            engineAvailable &&
            _fileName != null &&
            modelPath != null &&
            !running &&
            !busyElsewhere &&
            !needsDecoder &&
            !needsVadModel &&
            !_previewing &&
            !_recordingBusy;
        final hasResult = _result.isNotEmpty;
        // While running the panel echoes the engine's own partial text; it is
        // replaced by the finished transcript, never fabricated.
        final transcript = _result.isNotEmpty ? _result : _partialText;

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            48 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.transcribeBody,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _SourceCard(
                    fileName: _fileName,
                    hint: l10n.transcribeFileHint,
                    actionLabel: _fileName == null
                        ? l10n.transcribeChooseFile
                        : l10n.transcribeChangeFile,
                    enabled: !running && !_previewing && !_recordingBusy,
                    onPick: _pickFile,
                  ),
                  const SizedBox(height: 12),
                  RecordingControls(
                    enabled: !running && !_previewing && !busyElsewhere,
                    onBusy: (busy) => setState(() => _recordingBusy = busy),
                    onRecorded: (path) => setState(() {
                      _filePath = path;
                      _fileName = path
                          .split(RegExp(r'[\\/]'))
                          .reversed
                          .skip(1)
                          .first;
                      _vadPreview = null;
                      _vadPreviewSignature = null;
                      _vadPreviewError = null;
                      _result = '';
                    }),
                  ),
                  if (!engineAvailable) ...[
                    const SizedBox(height: 16),
                    _EngineBanner(
                      title: l10n.transcribeEngineUnavailableTitle,
                      body: l10n.transcribeEngineUnavailableBody,
                    ),
                  ],
                  const SizedBox(height: 32),
                  _SectionLabel(l10n.transcribeEngineSection),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final modelTile = _StatusTile(
                        icon: Icons.layers_outlined,
                        label: l10n.transcribeModel,
                        valueChild: state == null
                            ? Text(
                                l10n.transcribeModelNone,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium,
                              )
                            : SelectedModelName(
                                library: widget.modelLibrary,
                                state: state,
                                emptyLabel: l10n.transcribeModelNone,
                                style: theme.textTheme.titleMedium,
                              ),
                      );
                      final engineTile = _StatusTile(
                        icon: Icons.memory_outlined,
                        label: l10n.transcribeEngineSection,
                        value: widget.engine.id,
                      );
                      final backendTile = _StatusTile(
                        icon: Icons.developer_board_outlined,
                        label: l10n.transcribeBackend,
                        value: _backendLabel(capabilities, l10n),
                      );

                      if (constraints.maxWidth >= 480) {
                        return Row(
                          children: [
                            Expanded(flex: 2, child: modelTile),
                            const SizedBox(width: 12),
                            Expanded(child: engineTile),
                            const SizedBox(width: 12),
                            Expanded(child: backendTile),
                          ],
                        );
                      }
                      if (constraints.maxWidth >= 300) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            modelTile,
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(child: engineTile),
                                const SizedBox(width: 12),
                                Expanded(child: backendTile),
                              ],
                            ),
                          ],
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          modelTile,
                          const SizedBox(height: 12),
                          engineTile,
                          const SizedBox(height: 12),
                          backendTile,
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed:
                        running ||
                            busyElsewhere ||
                            state == null ||
                            widget.modelLibrary == null
                        ? null
                        : _pickModel,
                    icon: const Icon(Icons.model_training_outlined),
                    label: Text(
                      modelPath == null
                          ? l10n.transcribeChooseModel
                          : l10n.transcribeChangeModel,
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                  ),
                  if (needsDecoder) ...[
                    const SizedBox(height: 12),
                    _Hint(
                      icon: Icons.warning_amber_rounded,
                      text: l10n.modelNeedsDecoder,
                      color: scheme.error,
                    ),
                  ] else if (widget.state?.modelSelectionMissing ?? false) ...[
                    const SizedBox(height: 12),
                    _Hint(
                      icon: Icons.warning_amber_rounded,
                      text: l10n.modelSelectionMissing,
                      color: scheme.error,
                    ),
                  ] else if (modelPath == null) ...[
                    const SizedBox(height: 12),
                    _Hint(
                      icon: Icons.info_outline,
                      text: l10n.transcribeModelRequired,
                      color: scheme.onSurfaceVariant,
                    ),
                  ] else if (busyElsewhere) ...[
                    const SizedBox(height: 12),
                    _Hint(
                      icon: Icons.sync,
                      text: l10n.engineBusyNote,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                  if (needsVadModel) ...[
                    const SizedBox(height: 12),
                    _Hint(
                      icon: Icons.warning_amber_rounded,
                      text: l10n.vadModelRequired,
                      color: scheme.error,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: scheme.error)),
                  ],
                  if (neuralSelected) ...[
                    const SizedBox(height: 16),
                    _buildVadPreview(context),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: canStart ? _start : null,
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: Text(l10n.transcribeStart),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                            textStyle: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      if (running) ...[
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: _cancelRequested ? null : _cancelRun,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 52),
                          ),
                          child: Text(
                            _cancelRequested
                                ? l10n.transcribeCancelling
                                : l10n.transcribeCancel,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 28),
                  _SectionLabel(l10n.transcribeMetrics),
                  const SizedBox(height: 12),
                  _ProgressPanel(
                    // A cooperative cancel is not instant: say so while the
                    // abort is still landing, instead of faking a stopped run.
                    label: !running
                        ? l10n.transcribeProgressIdle
                        : _cancelRequested
                        ? l10n.transcribeCancelling
                        : _stageLabel(l10n, _stage),
                    value: running && _stage != TranscriptionStage.transcribing
                        ? null
                        : _progress ?? 0,
                  ),
                  const SizedBox(height: 12),
                  _MetricsGrid(
                    charsPerSec: _charsPerSec,
                    rtf: _rtf,
                    elapsed: _elapsed,
                    cpuPercent: _cpuPercent,
                    memoryBytes: _memoryBytes,
                    decoderInfo: _decoderInfo,
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      _SectionLabel(l10n.transcribeResult),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: hasResult ? _copy : null,
                        icon: const Icon(Icons.copy_all_outlined, size: 18),
                        label: Text(l10n.transcribeCopy),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _Panel(
                    child: transcript.isNotEmpty
                        ? SelectableText(
                            transcript,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.5,
                            ),
                          )
                        : Text(
                            l10n.transcribeResultEmpty,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.5,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The neural-VAD preview card: real windows for the picked file, with the
  /// times they cover, a re-preview button (the knobs live in Settings) and a
  /// cancel for a slow plan. Shown only in neural mode.
  Widget _buildVadPreview(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final preview = _vadPreview;
    final canPreview =
        _filePath != null &&
        !_previewing &&
        !_running &&
        !_recordingBusy &&
        (widget.state?.neuralVadReady ?? false);
    final stale =
        preview != null &&
        _vadPreviewSignature != widget.state?.neuralVadSignature;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.graphic_eq, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(l10n.vadPreview, style: theme.textTheme.titleSmall),
              ),
              TextButton.icon(
                onPressed: canPreview ? _previewVad : null,
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: Text(
                  preview == null ? l10n.vadPreviewRun : l10n.vadPreviewAgain,
                ),
              ),
            ],
          ),
          if (_previewing) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(l10n.vadPreviewing)),
                TextButton(
                  onPressed: _previewCancelRequested ? null : _cancelPreview,
                  child: Text(l10n.queueCancel),
                ),
              ],
            ),
          ],
          if (_vadPreviewError != null) ...[
            const SizedBox(height: 8),
            Text(
              _vadPreviewError!,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
          if (preview != null && !_previewing) ...[
            const SizedBox(height: 8),
            Text(
              l10n.vadPreviewSummary(
                preview.windows.length,
                _seconds(preview.speechDuration),
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (stale) ...[
              const SizedBox(height: 4),
              Text(
                l10n.vadPreviewStale,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: 8),
            for (var i = 0; i < preview.windows.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.vadPreviewWindow(i + 1),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    for (final span in preview.windows[i])
                      Text(
                        l10n.vadPreviewSegment(
                          _seconds(span.start),
                          _seconds(span.end),
                        ),
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// Whole seconds with two decimals — the timeline unit the preview speaks.
  static String _seconds(Duration value) =>
      (value.inMicroseconds / 1000000).toStringAsFixed(2);
}

/// Rounded surface used for the result, progress and status blocks.
class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.fileName,
    required this.hint,
    required this.actionLabel,
    required this.enabled,
    required this.onPick,
  });

  final String? fileName;
  final String hint;
  final String actionLabel;
  final bool enabled;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = fileName != null;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  selected ? Icons.audio_file : Icons.mic_none,
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName ?? l10n.transcribeNoFile,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: enabled ? onPick : null,
            icon: const Icon(Icons.folder_open_outlined, size: 20),
            label: Text(actionLabel),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
            ),
          ),
        ],
      ),
    );
  }
}

class _EngineBanner extends StatelessWidget {
  const _EngineBanner({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onErrorContainer,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One-line note under a control: why the current selection cannot run.
class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text, required this.color});

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

class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.icon,
    required this.label,
    this.value,
    this.valueChild,
  }) : assert(value != null || valueChild != null);

  final IconData icon;
  final String label;
  final String? value;
  final Widget? valueChild;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _Panel(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          valueChild ??
              Text(
                value!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
        ],
      ),
    );
  }
}

class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({required this.label, required this.value});

  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (value != null)
                Text(
                  '${(value! * 100).round()}%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

/// Formats a real rate with one decimal, or null when it was never measured.
String? _rate(double? value) => value?.toStringAsFixed(1);

/// Wall clock as `500ms` or `2.0s`, or null when no progress was seen.
String? _elapsed(Duration? value) {
  if (value == null) return null;
  final millis = value.inMilliseconds;
  return millis < 1000
      ? '${millis}ms'
      : '${(millis / 1000).toStringAsFixed(1)}s';
}

/// One-decimal MiB for a measured RSS, or null when not measured.
String? _memory(int? bytes) =>
    bytes == null ? null : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// Metric tiles fed by the live run. CPU and memory come from the periodic
/// sampler and stay `—` whenever a reading could not be taken — the page never
/// invents numbers.
class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({
    required this.charsPerSec,
    required this.rtf,
    required this.elapsed,
    required this.cpuPercent,
    required this.memoryBytes,
    required this.decoderInfo,
  });

  final double? charsPerSec;
  final double? rtf;
  final Duration? elapsed;
  final double? cpuPercent;
  final int? memoryBytes;
  final AudioDecoderInfo? decoderInfo;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final unknown = l10n.metricUnavailable;
    final metrics = <(String, IconData, String)>[
      (l10n.metricCharsPerSec, Icons.speed, _rate(charsPerSec) ?? unknown),
      (
        l10n.metricRtf,
        Icons.timer_outlined,
        rtf?.toStringAsFixed(2) ?? unknown,
      ),
      (l10n.metricElapsed, Icons.schedule, _elapsed(elapsed) ?? unknown),
      (
        l10n.metricCpu,
        Icons.memory,
        cpuPercent == null ? unknown : '${cpuPercent!.toStringAsFixed(0)}%',
      ),
      (l10n.metricMemory, Icons.storage, _memory(memoryBytes) ?? unknown),
      (
        l10n.metricDecoder,
        Icons.audio_file_outlined,
        _decoderMode(decoderInfo, l10n),
      ),
    ];

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.9,
      children: [
        for (final (label, icon, value) in metrics)
          _MetricTile(label: label, icon: icon, value: value),
      ],
    );
  }
}

String _decoderMode(AudioDecoderInfo? info, AppLocalizations l10n) {
  if (info == null) return l10n.metricUnavailable;
  final mode = switch (info.isHardware) {
    true => l10n.decoderHardware,
    false => l10n.decoderSoftware,
    null => l10n.decoderUnknown,
  };
  return '${info.name}\n$mode';
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.icon,
    required this.value,
  });

  final String label;
  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _Panel(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          Tooltip(
            message: value,
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      ),
    );
  }
}
