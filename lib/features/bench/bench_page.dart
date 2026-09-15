import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../engine/asr_engine.dart';
import '../../l10n/app_localizations.dart';
import 'seven_tap.dart';

/// Fixed sample every matrix cell must run on, or the numbers are not
/// comparable. Missing in this build — the page says so instead of guessing.
const String benchSampleAsset = 'assets/test/sample_16k.wav';

/// Families in the first-release CPU matrix (plan Phase 10 / D17).
const List<String> benchFamilies = <String>[
  'sensevoice',
  'whisper',
  'qwen3',
  'funasr',
];

/// Quantization tags the first release compares.
const List<String> benchQuants = <String>['q8_0', 'q4_k'];

/// Hidden benchmark page (requirement 15), reached by tapping the version row
/// seven times in Settings and left the same way on this page's title.
///
/// The first release only compares the CPU matrix. This build bundles no native
/// engine and no fixed sample, so the page shows the full matrix plus an honest
/// empty state — it never prints a figure that no run produced. A real runner
/// fills the same cells using `engine/metrics.dart` (`TranscriptionMetrics`) and
/// `core/text/token_counter.dart` (`graphemesPerSecond`) so the numbers match
/// the transcribe page.
class BenchPage extends StatefulWidget {
  const BenchPage({super.key, this.engine = const UnavailableAsrEngine()});

  /// Engine the matrix would load; defaults to the "no native library" stand-in.
  final AsrEngine engine;

  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> {
  late final Future<_BenchProbe> _probe = _runProbe();

  Future<_BenchProbe> _runProbe() async {
    final capabilities = await widget.engine.capabilities();
    return _BenchProbe(
      engineAvailable: capabilities.available,
      sampleAvailable: await _assetExists(benchSampleAsset),
    );
  }

  /// True only when the asset is really bundled; an unreadable asset is a
  /// missing one, and a missing sample means no comparable run.
  Future<bool> _assetExists(String asset) async {
    try {
      await rootBundle.load(asset);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: SevenTapGate(
          onTriggered: () => Navigator.of(context).maybePop(),
          child: Text(l10n.benchTitle),
        ),
      ),
      body: FutureBuilder<_BenchProbe>(
        future: _probe,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final probe = snapshot.data!;
          final canRun = probe.engineAvailable && probe.sampleAvailable;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _Muted(l10n.benchIntro, height: 1.5),
              if (!canRun) ...[
                const SizedBox(height: 16),
                _UnavailableBanner(
                  title: l10n.benchUnavailableTitle,
                  lines: [
                    if (!probe.engineAvailable) l10n.benchUnavailableEngine,
                    if (!probe.sampleAvailable)
                      l10n.benchUnavailableSample(benchSampleAsset),
                  ],
                  honesty: l10n.benchHonesty,
                ),
              ],
              const SizedBox(height: 24),
              _SectionLabel(l10n.benchMatrix),
              const SizedBox(height: 8),
              _Muted(l10n.benchCpuOnly),
              const SizedBox(height: 12),
              _MatrixCard(canRun: canRun),
              const SizedBox(height: 28),
              _SectionLabel(l10n.benchResults),
              const SizedBox(height: 12),
              FilledButton.icon(
                // ponytail: enabled once a real engine + sample land; a button
                // that could not produce a number stays disabled on purpose.
                onPressed: null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(l10n.benchRun),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
              const SizedBox(height: 16),
              _EmptyResults(
                title: l10n.benchNoResultsTitle,
                body: l10n.benchNoResultsBody,
              ),
              const SizedBox(height: 20),
              _Muted(l10n.benchExitHint),
            ],
          );
        },
      ),
    );
  }
}

/// The two facts the page needs before it may claim anything.
class _BenchProbe {
  const _BenchProbe({
    required this.engineAvailable,
    required this.sampleAvailable,
  });

  final bool engineAvailable;
  final bool sampleAvailable;
}

/// Rounded card matching the models/transcribe surfaces.
class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

class _MatrixCard extends StatelessWidget {
  const _MatrixCard({required this.canRun});

  final bool canRun;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MatrixHeader(l10n: l10n),
          Divider(height: 20, color: scheme.outlineVariant),
          for (final family in benchFamilies)
            for (final quant in benchQuants) ...[
              _MatrixRow(family: family, quant: quant, canRun: canRun),
              if (!(family == benchFamilies.last && quant == benchQuants.last))
                Divider(height: 20, color: scheme.outlineVariant),
            ],
        ],
      ),
    );
  }
}

class _MatrixHeader extends StatelessWidget {
  const _MatrixHeader({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    return Row(
      children: [
        Expanded(flex: 4, child: Text(l10n.benchFamily, style: style)),
        Expanded(flex: 2, child: Text(l10n.benchQuant, style: style)),
        Expanded(flex: 2, child: Text(l10n.transcribeBackend, style: style)),
        Expanded(
          flex: 4,
          child: Text(
            l10n.benchStatus,
            textAlign: TextAlign.right,
            style: style,
          ),
        ),
      ],
    );
  }
}

class _MatrixRow extends StatelessWidget {
  const _MatrixRow({
    required this.family,
    required this.quant,
    required this.canRun,
  });

  final String family;
  final String quant;
  final bool canRun;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Row(
      children: [
        Expanded(
          flex: 4,
          child: Text(
            family,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
        ),
        Expanded(flex: 2, child: Text(quant, style: muted)),
        Expanded(flex: 2, child: Text(l10n.transcribeBackendCpu, style: muted)),
        Expanded(
          flex: 4,
          child: Align(
            alignment: Alignment.centerRight,
            child: _StatusPill(
              label: canRun
                  ? l10n.benchStatusNotRun
                  : l10n.benchStatusUnavailable,
              blocked: !canRun,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.blocked});

  final String label;
  final bool blocked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: blocked ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: blocked ? scheme.onErrorContainer : scheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _UnavailableBanner extends StatelessWidget {
  const _UnavailableBanner({
    required this.title,
    required this.lines,
    required this.honesty,
  });

  final String title;
  final List<String> lines;
  final String honesty;

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
                for (final line in lines) ...[
                  const SizedBox(height: 6),
                  Text(
                    line,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                      height: 1.45,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Text(
                  honesty,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onErrorContainer,
                    fontStyle: FontStyle.italic,
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

/// Empty state: the shape of the result table, with no invented values.
class _EmptyResults extends StatelessWidget {
  const _EmptyResults({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          Icon(Icons.speed_outlined, size: 36, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _Muted extends StatelessWidget {
  const _Muted(this.text, {this.height});

  final String text;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        height: height,
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
