import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';

import '../../engine/asr_engine.dart';
import '../../engine/metrics.dart';
import '../../app/app_state.dart';
import '../../data/transcript_repo.dart';
import '../../core/audio/audio_preprocessor.dart';
import '../../core/text/token_counter.dart';
import 'transcription_service.dart';
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

  @override
  State<TranscribePage> createState() => _TranscribePageState();
}

class _TranscribePageState extends State<TranscribePage> {
  late Future<EngineCapabilities> _capabilities;

  String? _fileName;
  String? _filePath;

  /// Model path used only when no [AppState] is injected.
  String? _localModelPath;

  /// Shared, persisted model path; a pick in either page updates the same value.
  String? get _modelPath => widget.state?.modelPath ?? _localModelPath;

  /// Rolling tokens/s across engine-reported true token counts. Its `tokens`
  /// also carries the latest cumulative token count for the run.
  final TokenRateTracker _tokenRates = TokenRateTracker();

  // Live run state, all rewritten from real engine progress.
  String _result = '';
  String _partialText = '';
  double? _progress;
  bool _running = false;
  String? _error;

  double? _tokensPerSec;
  double? _charsPerSec;
  Duration? _elapsed;
  double? _rtf;
  Backend? _runBackend;

  @override
  void initState() {
    super.initState();
    _capabilities = widget.engine.capabilities();
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

  /// Mirrors one engine progress update into the live metrics. A negative or
  /// missing token count is ignored by [TokenRateTracker], so nothing is
  /// invented; unknown figures stay null and render as `—`.
  void _onProgress(TranscribeProgress progress) {
    if (!mounted) return;
    if (progress.tokens != null) {
      _tokenRates.add(progress.tokens!, progress.elapsed);
    }
    final partial = progress.partialText.trim();
    setState(() {
      if (progress.ratio >= 0) _progress = progress.ratio;
      _elapsed = progress.elapsed;
      _tokensPerSec = _tokenRates.tokensPerSecond;
      if (partial.isNotEmpty) {
        _partialText = partial;
        _charsPerSec = graphemesPerSecond(partial, progress.elapsed);
      }
    });
  }

  void _notify(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickFile() async {
    if (_running) return; // a run owns the current file
    final l10n = AppLocalizations.of(context);
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: l10n.fileTypeAudio,
          extensions: const ['wav', 'm4a', 'mp3', 'flac'],
        ),
      ],
    );
    if (!mounted || file == null) return;
    setState(() {
      _filePath = file.path;
      _fileName = file.name;
    });
  }

  Future<void> _start() async {
    final l10n = AppLocalizations.of(context);
    final state = widget.state;
    final modelPath = _modelPath;
    if (_filePath == null || modelPath == null) {
      _notify(l10n.transcribeModelRequired);
      return;
    }
    if (state?.selectionNeedsMissingCompanion ?? false) {
      _notify(l10n.modelNeedsDecoder);
      return;
    }
    final service = widget.service ?? TranscriptionService(
      engine: widget.engine,
      preprocessor: AudioPreprocessor(
        enabled: state?.loudnessEnabled ?? true,
        targetLufs: state?.loudnessTargetLufs ?? -16,
      ),
    );
    _tokenRates.reset();
    setState(() {
      _running = true;
      _error = null;
      _progress = 0;
      _result = '';
      _partialText = '';
      _tokensPerSec = null;
      _charsPerSec = null;
      _elapsed = null;
      _rtf = null;
      _runBackend = null;
    });
    try {
      final result = await service.transcribe(
        audioPath: _filePath!,
        model: EngineModelSpec(
          path: modelPath,
          family: state?.modelFamily,
          quant: state?.modelQuant,
        ),
        backend: state?.backend ?? Backend.cpu,
        chunkSettings: state?.chunkSettings,
        onProgress: _onProgress,
      );
      // Saving the successful result is unchanged; only the live view grew.
      widget.transcriptRepo?.insert(
        title: _fileName ?? _filePath!,
        text: result.text,
        audioPath: _filePath,
        audioSeconds: result.audioDuration.inMilliseconds / 1000,
        engine: result.engine,
        modelPath: result.model.path,
        backend: result.backend.name,
        rtf: result.rtf,
        tokens: result.tokens,
        totalMs: result.elapsed.inMilliseconds,
        avgTokensPerSec: result.avgTokensPerSec,
      );
      if (mounted) {
        setState(() {
          _result = result.text;
          _partialText = '';
          _progress = 1;
          _elapsed = result.elapsed;
          _rtf = result.rtf;
          _runBackend = result.backend;
          _tokensPerSec = result.avgTokensPerSec ?? _tokensPerSec;
          _charsPerSec = result.text.isEmpty
              ? null
              : graphemesPerSecond(result.text, result.elapsed);
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _running = false);
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
    // Store it in the shared state so the queue page sees the same model, and
    // fall back to a local copy when no state was injected.
    _localModelPath = file.path;
    widget.state?.modelPath = file.path;
    setState(() {});
  }

  Future<void> _copy() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _result));
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l10n.transcribeCopied)));
  }

  String _backendLabel(EngineCapabilities? capabilities, AppLocalizations l10n) {
    // Once a run finished, the tile shows the backend that actually ran.
    final ran = _runBackend;
    if (ran != null) return ran.name.toUpperCase();
    final backends = capabilities?.backends ?? const <Backend>{};
    if (backends.isEmpty) return l10n.metricUnavailable;
    return backends.map((b) => b.name.toUpperCase()).join(', ');
  }

  @override
  Widget build(BuildContext context) {
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
        // Nothing starts without a model file, and a selection the engine cannot
        // load (whisper without its decoder) is refused up front.
        final canStart =
            engineAvailable &&
            _fileName != null &&
            modelPath != null &&
            !running &&
            !needsDecoder;
        final hasResult = _result.isNotEmpty;
        // While running the panel echoes the engine's own partial text; it is
        // replaced by the finished transcript, never fabricated.
        final transcript = _result.isNotEmpty ? _result : _partialText;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
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
                  const SizedBox(height: 20),
                  _SourceCard(
                    fileName: _fileName,
                    hint: l10n.transcribeFileHint,
                    actionLabel: _fileName == null
                        ? l10n.transcribeChooseFile
                        : l10n.transcribeChangeFile,
                    enabled: !running,
                    onPick: _pickFile,
                  ),
                  if (!engineAvailable) ...[
                    const SizedBox(height: 16),
                    _EngineBanner(
                      title: l10n.transcribeEngineUnavailableTitle,
                      body: l10n.transcribeEngineUnavailableBody,
                    ),
                  ],
                  const SizedBox(height: 24),
                  _SectionLabel(l10n.transcribeEngineSection),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: _StatusTile(
                          icon: Icons.layers_outlined,
                          label: l10n.transcribeModel,
                          value: _modelPath == null
                              ? l10n.transcribeModelNone
                              : _modelPath!.split(RegExp(r'[\\/]')).last,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatusTile(
                          icon: Icons.memory_outlined,
                          label: l10n.transcribeEngineSection,
                          value: widget.engine.id,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatusTile(
                          icon: Icons.developer_board_outlined,
                          label: l10n.transcribeBackend,
                          value: _backendLabel(capabilities, l10n),
                        ),
                      ),
                    ],
                  ),
                  OutlinedButton.icon(
                    onPressed: running ? null : _pickModel,
                    icon: const Icon(Icons.model_training_outlined),
                    label: Text(l10n.transcribeChooseModel),
                  ),
                  if (needsDecoder) ...[
                    const SizedBox(height: 12),
                    _Hint(
                      icon: Icons.warning_amber_rounded,
                      text: l10n.modelNeedsDecoder,
                      color: scheme.error,
                    ),
                  ] else if (modelPath == null) ...[
                    const SizedBox(height: 12),
                    _Hint(
                      icon: Icons.info_outline,
                      text: l10n.transcribeModelRequired,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: scheme.error)),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
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
                  const SizedBox(height: 28),
                  _SectionLabel(l10n.transcribeMetrics),
                  const SizedBox(height: 12),
                  _ProgressPanel(
                    label: running
                        ? l10n.transcribeProgress
                        : l10n.transcribeProgressIdle,
                    value: _progress ?? 0,
                  ),
                  const SizedBox(height: 12),
                  _MetricsGrid(
                    tokensPerSec: _tokensPerSec,
                    charsPerSec: _charsPerSec,
                    rtf: _rtf,
                    elapsed: _elapsed,
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
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

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
          Text(
            value,
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
  final double value;

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
              Text(
                '${(value * 100).round()}%',
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
  return millis < 1000 ? '${millis}ms' : '${(millis / 1000).toStringAsFixed(1)}s';
}

/// Six metric tiles fed by the live run. CPU and memory have no engine source
/// yet, and every unknown value stays `—` — the page never invents numbers.
class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({
    required this.tokensPerSec,
    required this.charsPerSec,
    required this.rtf,
    required this.elapsed,
  });

  final double? tokensPerSec;
  final double? charsPerSec;
  final double? rtf;
  final Duration? elapsed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final unknown = l10n.metricUnavailable;
    final metrics = <(String, IconData, String)>[
      (l10n.metricTokensPerSec, Icons.speed, _rate(tokensPerSec) ?? unknown),
      (l10n.metricCharsPerSec, Icons.abc, _rate(charsPerSec) ?? unknown),
      (
        l10n.metricRtf,
        Icons.timer_outlined,
        rtf?.toStringAsFixed(2) ?? unknown,
      ),
      (l10n.metricElapsed, Icons.schedule, _elapsed(elapsed) ?? unknown),
      (l10n.metricCpu, Icons.memory, unknown),
      (l10n.metricMemory, Icons.storage, unknown),
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
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
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
