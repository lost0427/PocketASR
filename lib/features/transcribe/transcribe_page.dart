import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine/asr_engine.dart';
import '../../l10n/app_localizations.dart';

/// Transcribe tab.
///
/// Phase 4 lays out the whole single-file flow and its honest empty states, and
/// asks the injected [AsrEngine] what it can actually do. No native library is
/// bundled yet, so the default [UnavailableAsrEngine] reports unavailable and
/// every control that needs the engine stays disabled — the page never pretends
/// a transcript happened. Phase 4 swaps in `CrispAsrEngine` and fills in
/// [_copy]'s source plus the run loop.
class TranscribePage extends StatefulWidget {
  const TranscribePage({super.key, this.engine = const UnavailableAsrEngine()});

  /// The engine to report status for. Defaults to the "no native library"
  /// stand-in; callers pass `CrispAsrEngine` once the `.so` is bundled.
  final AsrEngine engine;

  @override
  State<TranscribePage> createState() => _TranscribePageState();
}

class _TranscribePageState extends State<TranscribePage> {
  late Future<EngineCapabilities> _capabilities;

  String? _fileName;

  // Phase 4 replaces these with live run state (progress stream + result text).
  final String _result = '';
  final double? _progress = null;

  @override
  void initState() {
    super.initState();
    _capabilities = widget.engine.capabilities();
  }

  void _notify(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _pickFile() {
    // Phase 4: replace with the platform audio picker.
    _notify(AppLocalizations.of(context).transcribePickerUnavailable);
  }

  void _start() {
    // Reached only once the engine reports available, which Phase 4 pairs with
    // the real `engine.transcribe(request)` call.
    _notify(AppLocalizations.of(context).transcribeStartUnavailable);
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
        final running = _progress != null;
        final canStart = engineAvailable && _fileName != null && !running;
        final hasResult = _result.isNotEmpty;

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
                        child: _StatusTile(
                          icon: Icons.layers_outlined,
                          label: l10n.transcribeModel,
                          value: l10n.transcribeModelNone,
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
                  const _MetricsGrid(),
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
                    child: hasResult
                        ? SelectableText(
                            _result,
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
    required this.onPick,
  });

  final String? fileName;
  final String hint;
  final String actionLabel;
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
            onPressed: onPick,
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
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
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

/// Six metric tiles. Values stay `—` until Phase 6 feeds real samples in; the
/// page never invents numbers.
class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final metrics = <(String, IconData)>[
      (l10n.metricTokensPerSec, Icons.speed),
      (l10n.metricCharsPerSec, Icons.abc),
      (l10n.metricRtf, Icons.timer_outlined),
      (l10n.metricElapsed, Icons.schedule),
      (l10n.metricCpu, Icons.memory),
      (l10n.metricMemory, Icons.storage),
    ];

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.9,
      children: [
        for (final (label, icon) in metrics)
          _MetricTile(label: label, icon: icon, value: l10n.metricUnavailable),
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
