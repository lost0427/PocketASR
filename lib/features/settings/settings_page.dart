import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../bench/bench_page.dart';
import '../bench/seven_tap.dart';

/// Model families the first release may run (plan D15 whitelist).
const List<String> settingsModelFamilies = <String>[
  'sensevoice',
  'whisper',
  'qwen3',
  'funasr',
  'parakeet',
];

/// Quantization tags the catalog exposes (plan D17). `int8` is here because the
/// curated sherpa bundles ship int8, and a selected bundle writes its quant
/// into [AppState.modelQuant].
const List<String> settingsQuants = <String>['q8_0', 'q4_k', 'q6_k', 'int8'];

/// Target loudness values in LUFS (plan Phase 3).
const List<double> settingsLoudnessTargets = <double>[-16, -14, -23];

/// Version shown in About. Keep in step with `pubspec.yaml` (`version:`).
const String settingsAppVersion = '0.1.0';

const String _systemLanguage = 'system';

/// Settings tab: appearance, language, the day-to-day model/quant entry, CPU
/// thread count and loudness normalization.
///
/// Every control writes to the in-memory [AppState] — nothing is persisted yet
/// (plan Phase 5 adds the settings table). Backend has no picker on purpose:
/// the first release is CPU-only, and [AppState.backend] already carries the
/// value so one can be added later without touching callers (plan D17).
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final state = AppStateScope.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _SectionLabel(l10n.settingsAppearance),
        const SizedBox(height: 12),
        SegmentedButton<ThemeMode>(
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: ThemeMode.system,
              label: Text(l10n.themeSystem),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              label: Text(l10n.themeLight),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              label: Text(l10n.themeDark),
            ),
          ],
          selected: {state.themeMode},
          onSelectionChanged: (selection) => state.themeMode = selection.first,
        ),
        const SizedBox(height: 28),
        _SectionLabel(l10n.settingsLanguage),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: _systemLanguage,
              label: Text(l10n.languageSystem),
            ),
            ButtonSegment(value: 'en', label: Text(l10n.languageEnglish)),
            ButtonSegment(value: 'zh', label: Text(l10n.languageChinese)),
          ],
          selected: {state.locale?.languageCode ?? _systemLanguage},
          onSelectionChanged: (selection) {
            final code = selection.first;
            state.locale = code == _systemLanguage ? null : Locale(code);
          },
        ),
        const SizedBox(height: 28),
        _SectionLabel(l10n.settingsModel),
        const SizedBox(height: 12),
        _Card(child: _ModelControl(state: state)),
        const SizedBox(height: 28),
        _SectionLabel(l10n.settingsPerformance),
        const SizedBox(height: 12),
        _Card(child: _ThreadsControl(state: state)),
        const SizedBox(height: 28),
        _SectionLabel(l10n.settingsAudio),
        const SizedBox(height: 12),
        _Card(child: _LoudnessControl(state: state)),
        const SizedBox(height: 28),
        _SectionLabel(l10n.settingsChunking),
        const SizedBox(height: 12),
        _Card(child: _ChunkControl(state: state)),
        const SizedBox(height: 28),
        _SectionLabel(l10n.settingsAbout),
        const SizedBox(height: 12),
        _Card(
          child: SevenTapGate(
            onTriggered: () => _openBench(context),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.settingsVersion(settingsAppVersion),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsAboutHint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.save_outlined, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.settingsNotPersisted,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _openBench(BuildContext context) {
    // The benchmark runs the same engine the rest of the app would; it builds
    // its own service so a benchmark never writes a transcript.
    final state = AppStateScope.of(context);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BenchPage(engine: state.engine, state: state),
      ),
    );
  }
}

class _ModelControl extends StatelessWidget {
  const _ModelControl({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final spec = state.modelSpec;
    final selectedName = spec == null
        ? l10n.settingsActiveModelNone
        : spec.path.split(RegExp(r'[\\/]')).last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ControlLabel(l10n.settingsActiveModel),
        const SizedBox(height: 6),
        Text(selectedName, style: theme.textTheme.bodyMedium),
        if (state.modelSelectionMissing) ...[
          const SizedBox(height: 4),
          Text(
            l10n.modelSelectionMissing,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ] else if (state.modelSelectionIsManual) ...[
          const SizedBox(height: 4),
          Text(
            l10n.settingsActiveModelManual,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ],
        const SizedBox(height: 20),
        _ControlLabel(l10n.settingsModelFamily),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final family in settingsModelFamilies)
              ChoiceChip(
                label: Text(family),
                selected: state.modelFamily == family,
                onSelected: (_) => state.modelFamily = family,
              ),
          ],
        ),
        const SizedBox(height: 20),
        _ControlLabel(l10n.settingsQuantization),
        const SizedBox(height: 10),
        SegmentedButton<String>(
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          segments: [
            for (final quant in settingsQuants)
              ButtonSegment(value: quant, label: Text(quant)),
          ],
          selected: {state.modelQuant},
          onSelectionChanged: (selection) =>
              state.modelQuant = selection.first,
        ),
      ],
    );
  }
}

class _ThreadsControl extends StatelessWidget {
  const _ThreadsControl({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final max = state.maxThreads;
    final sliderMax = max < 2 ? 2 : max;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.memory, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(l10n.settingsThreads, style: theme.textTheme.bodyMedium),
            ),
            Text(
              l10n.settingsThreadsValue(state.threads, max),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        Slider(
          value: state.threads.toDouble(),
          min: 1,
          max: sliderMax.toDouble(),
          divisions: sliderMax - 1,
          label: '${state.threads}',
          onChanged: (value) => state.threads = value.round(),
        ),
        Text(
          l10n.settingsThreadsHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _LoudnessControl extends StatelessWidget {
  const _LoudnessControl({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.graphic_eq, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.settingsLoudness,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Switch(
              value: state.loudnessEnabled,
              onChanged: (value) => state.loudnessEnabled = value,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          l10n.settingsLoudnessHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 20),
        _ControlLabel(l10n.settingsLoudnessTarget),
        const SizedBox(height: 10),
        SegmentedButton<double>(
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          segments: [
            for (final lufs in settingsLoudnessTargets)
              ButtonSegment(value: lufs, label: Text('${lufs.toInt()}')),
          ],
          selected: {state.loudnessTargetLufs},
          onSelectionChanged: state.loudnessEnabled
              ? (selection) => state.loudnessTargetLufs = selection.first
              : null,
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsLoudnessUnit,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ChunkControl extends StatelessWidget {
  const _ChunkControl({required this.state});

  final AppState state;

  /// Two decimals for the VAD's sub-second knobs, trimmed of a trailing zero.
  String _seconds(double value) {
    final text = value.toStringAsFixed(2);
    return text.endsWith('0') ? text.substring(0, text.length - 1) : text;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strategy = state.chunkStrategy;
    final neural = strategy == ChunkStrategy.neural;
    final valueStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ControlLabel(l10n.settingsChunkMode),
        const SizedBox(height: 10),
        SegmentedButton<ChunkStrategy>(
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: ChunkStrategy.fixed,
              label: Text(l10n.settingsChunkFixed),
            ),
            ButtonSegment(
              value: ChunkStrategy.energy,
              label: Text(l10n.settingsChunkEnergy),
            ),
            ButtonSegment(
              value: ChunkStrategy.neural,
              label: Text(l10n.settingsChunkNeural),
            ),
          ],
          selected: {strategy},
          onSelectionChanged: (selection) =>
              state.chunkStrategy = selection.first,
        ),
        const SizedBox(height: 20),
        if (neural)
          _vadControls(context)
        else if (strategy == ChunkStrategy.energy)
          _energyControls(context)
        else
          _fixedControls(context, valueStyle),
        const SizedBox(height: 4),
        Text(
          neural ? l10n.settingsVadHint : l10n.settingsChunkHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: state.resetChunkSettings,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: Text(l10n.settingsChunkReset),
          ),
        ),
      ],
    );
  }

  Widget _fixedControls(BuildContext context, TextStyle? valueStyle) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _ControlLabel(l10n.settingsChunkSeconds)),
            Text(
              l10n.settingsChunkSecondsValue(state.chunkSeconds.round()),
              style: valueStyle,
            ),
          ],
        ),
        Slider(
          value: state.chunkSeconds,
          min: AppState.minChunkSeconds,
          max: AppState.maxChunkSeconds,
          divisions:
              ((AppState.maxChunkSeconds - AppState.minChunkSeconds) / 5)
                  .round(),
          label: l10n.settingsChunkSecondsValue(state.chunkSeconds.round()),
          onChanged: (value) => state.chunkSeconds = value,
        ),
      ],
    );
  }

  Widget _energyControls(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final valueStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _ControlLabel(l10n.settingsEnergyThreshold)),
            Text(state.energyThreshold.toStringAsFixed(3), style: valueStyle),
          ],
        ),
        Slider(
          value: state.energyThreshold,
          min: AppState.minEnergyThreshold,
          max: AppState.maxEnergyThreshold,
          divisions:
              ((AppState.maxEnergyThreshold - AppState.minEnergyThreshold) /
                      0.001)
                  .round(),
          label: state.energyThreshold.toStringAsFixed(3),
          onChanged: (value) => state.energyThreshold = value,
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: _ControlLabel(l10n.settingsSpeechPad)),
            Text(
              l10n.settingsSpeechPadValue(state.speechPadMs),
              style: valueStyle,
            ),
          ],
        ),
        Slider(
          value: state.speechPadMs.toDouble(),
          min: 0,
          max: AppState.maxSpeechPadMs.toDouble(),
          divisions: AppState.maxSpeechPadMs ~/ 25,
          label: l10n.settingsSpeechPadValue(state.speechPadMs),
          onChanged: (value) => state.speechPadMs = value.round(),
        ),
      ],
    );
  }

  Widget _vadControls(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final valueStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    final modelName = state.vadModelPath == null
        ? l10n.settingsVadModelNone
        : state.vadModelPath!.split(RegExp(r'[\\/]')).last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ControlLabel(l10n.settingsVadModel),
        const SizedBox(height: 6),
        Text(modelName, style: theme.textTheme.bodyMedium),
        if (!state.neuralVadReady) ...[
          const SizedBox(height: 4),
          Text(
            l10n.vadModelRequired,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(child: _ControlLabel(l10n.settingsVadThreshold)),
            Text(state.vadThreshold.toStringAsFixed(2), style: valueStyle),
          ],
        ),
        Slider(
          value: state.vadThreshold,
          min: AppState.minVadThreshold,
          max: AppState.maxVadThreshold,
          divisions: 18,
          label: state.vadThreshold.toStringAsFixed(2),
          onChanged: (value) => state.vadThreshold = value,
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: _ControlLabel(l10n.settingsVadMinSilence)),
            Text(
              l10n.settingsVadSecondsValue(_seconds(state.vadMinSilenceSeconds)),
              style: valueStyle,
            ),
          ],
        ),
        Slider(
          value: state.vadMinSilenceSeconds,
          min: AppState.minVadMinSilence,
          max: AppState.maxVadMinSilence,
          divisions: 49,
          label: l10n.settingsVadSecondsValue(
            _seconds(state.vadMinSilenceSeconds),
          ),
          onChanged: (value) => state.vadMinSilenceSeconds = value,
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: _ControlLabel(l10n.settingsVadMinSpeech)),
            Text(
              l10n.settingsVadSecondsValue(_seconds(state.vadMinSpeechSeconds)),
              style: valueStyle,
            ),
          ],
        ),
        Slider(
          value: state.vadMinSpeechSeconds,
          min: AppState.minVadMinSpeech,
          max: AppState.maxVadMinSpeech,
          divisions: 99,
          label: l10n.settingsVadSecondsValue(
            _seconds(state.vadMinSpeechSeconds),
          ),
          onChanged: (value) => state.vadMinSpeechSeconds = value,
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: _ControlLabel(l10n.settingsSpeechPad)),
            Text(
              l10n.settingsSpeechPadValue(state.vadPadMs),
              style: valueStyle,
            ),
          ],
        ),
        Slider(
          value: state.vadPadMs.toDouble(),
          min: 0,
          max: AppState.maxVadPadMs.toDouble(),
          divisions: AppState.maxVadPadMs ~/ 25,
          label: l10n.settingsSpeechPadValue(state.vadPadMs),
          onChanged: (value) => state.vadPadMs = value.round(),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: _ControlLabel(l10n.settingsVadMaxSeconds)),
            Text(
              l10n.settingsVadSecondsValue(_seconds(state.vadMaxSeconds)),
              style: valueStyle,
            ),
          ],
        ),
        Slider(
          value: state.vadMaxSeconds,
          min: AppState.minVadMaxSeconds,
          max: AppState.maxVadMaxSeconds,
          divisions: 23,
          label: l10n.settingsVadSecondsValue(_seconds(state.vadMaxSeconds)),
          onChanged: (value) => state.vadMaxSeconds = value,
        ),
      ],
    );
  }
}

/// Rounded card matching the transcribe/models surfaces.
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

class _ControlLabel extends StatelessWidget {
  const _ControlLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
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
