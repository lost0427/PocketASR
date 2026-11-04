import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../core/audio/audio_source.dart';
import '../../core/backup/backup_service.dart';
import '../../core/update/release_check.dart';
import '../../l10n/app_localizations.dart';
import '../bench/bench_page.dart';
import '../bench/seven_tap.dart';
import '../models/model_library.dart';
import '../models/model_picker.dart';

/// Version shown in About. Keep in step with `pubspec.yaml` (`version:`).
const String settingsAppVersion = '1.0.29';

const String _systemLanguage = 'system';

/// Settings tab: appearance, language, the active downloaded model, CPU thread
/// count and — on Android only — the decoder preference.
///
/// Controls write to [AppState], which persists user settings on this device.
/// Backend has no picker on purpose: the first release is CPU-only, and
/// [AppState.backend] already carries the value so one can be added later
/// without touching callers (plan D17).
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    this.modelLibrary,
    this.onManageModels,
    this.showDecoderPreference,
    this.showAndroidTools,
  });

  final ModelLibrary? modelLibrary;
  final VoidCallback? onManageModels;

  /// Overrides the Android-only decoder preference visibility (test seam).
  final bool? showDecoderPreference;

  /// Overrides the Android-only backup tools visibility (test seam).
  final bool? showAndroidTools;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final state = AppStateScope.of(context);
    final showDecoder = showDecoderPreference ?? Platform.isAndroid;
    final showDataTools = showAndroidTools ?? Platform.isAndroid;

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
            ButtonSegment(value: ThemeMode.light, label: Text(l10n.themeLight)),
            ButtonSegment(value: ThemeMode.dark, label: Text(l10n.themeDark)),
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
        _Card(
          child: _ModelControl(
            state: state,
            modelLibrary: modelLibrary,
            onManageModels: onManageModels,
          ),
        ),
        const SizedBox(height: 28),
        _SectionLabel(l10n.settingsPerformance),
        const SizedBox(height: 12),
        _Card(
          child: Column(
            children: [
              _ThreadsControl(state: state),
              if (showDecoder) ...[
                const SizedBox(height: 20),
                _DecoderPreferenceControl(state: state),
              ],
            ],
          ),
        ),
        const SizedBox(height: 28),
        _SectionLabel(l10n.settingsChunking),
        const SizedBox(height: 12),
        _Card(child: _ChunkControl(state: state)),
        const SizedBox(height: 28),
        _SectionLabel(l10n.settingsTextCorrection),
        const SizedBox(height: 12),
        _Card(
          child: Material(
            color: Colors.transparent,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(
                Icons.auto_fix_high_outlined,
                color: scheme.onSurfaceVariant,
              ),
              title: Text(l10n.settingsMergePeriods),
              subtitle: Text(l10n.settingsMergePeriodsHint),
              value: state.autoCorrectPeriods,
              onChanged: (value) => state.autoCorrectPeriods = value,
            ),
          ),
        ),
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
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (showDataTools) ...[
          const SizedBox(height: 20),
          _DataSection(modelLibrary: modelLibrary),
          const SizedBox(height: 28),
          const _UpdatesSection(),
        ],
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.save_outlined, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.settingsPersistenceHint,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _openBench(BuildContext context) {
    // Each catalog bundle gets its declared engine. Engines are reused within
    // the run and owned by the benchmark, so the user's selection is unchanged.
    final state = AppStateScope.of(context);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BenchPage(
          state: state,
          engineFactory: (id) =>
              state.engineRegistry.createAsr(id, threads: state.threads),
        ),
      ),
    );
  }
}

class _ModelControl extends StatelessWidget {
  const _ModelControl({
    required this.state,
    required this.modelLibrary,
    required this.onManageModels,
  });

  final AppState state;
  final ModelLibrary? modelLibrary;
  final VoidCallback? onManageModels;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ControlLabel(l10n.settingsActiveModel),
        const SizedBox(height: 6),
        SelectedModelName(
          library: modelLibrary,
          state: state,
          emptyLabel: l10n.settingsActiveModelNone,
          maxLines: 2,
          style: theme.textTheme.bodyMedium,
        ),
        if (state.modelSelectionMissing) ...[
          const SizedBox(height: 4),
          Text(
            l10n.modelSelectionMissing,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ],
        if (state.modelSpec != null) ...[
          const SizedBox(height: 4),
          Text(
            [state.engineId, state.modelFamily, state.modelQuant].join(' | '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: state.engineBusy || modelLibrary == null
              ? null
              : () => showDownloadedModelPicker(
                  context: context,
                  library: modelLibrary!,
                  state: state,
                  onManageModels: onManageModels,
                ),
          icon: const Icon(Icons.model_training_outlined),
          label: Text(
            state.modelSpec == null
                ? l10n.transcribeChooseModel
                : l10n.transcribeChangeModel,
          ),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
          ),
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
              child: Text(
                l10n.settingsThreads,
                style: theme.textTheme.bodyMedium,
              ),
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
          // Only on release: the embedding worker re-reads the model per
          // reload, so a drag must not rebuild it once per step.
          onChangeEnd: (value) => state.applyThreads(),
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

class _DecoderPreferenceControl extends StatelessWidget {
  const _DecoderPreferenceControl({required this.state});

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
            Icon(
              Icons.audio_file_outlined,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.settingsDecoderPreference,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SegmentedButton<AudioDecoderPreference>(
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: AudioDecoderPreference.automatic,
              label: Text(l10n.decoderPreferenceAutomatic),
            ),
            ButtonSegment(
              value: AudioDecoderPreference.preferHardware,
              label: Text(l10n.decoderPreferenceHardware),
            ),
            ButtonSegment(
              value: AudioDecoderPreference.preferSoftware,
              label: Text(l10n.decoderPreferenceSoftware),
            ),
          ],
          selected: {state.audioDecoderPreference},
          onSelectionChanged: (selection) =>
              state.audioDecoderPreference = selection.first,
        ),
        const SizedBox(height: 8),
        Text(
          l10n.settingsDecoderPreferenceHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.45,
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
          divisions: ((AppState.maxChunkSeconds - AppState.minChunkSeconds) / 5)
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
              l10n.settingsVadSecondsValue(
                _seconds(state.vadMinSilenceSeconds),
              ),
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
class _UpdatesSection extends StatefulWidget {
  const _UpdatesSection();

  @override
  State<_UpdatesSection> createState() => _UpdatesSectionState();
}

class _UpdatesSectionState extends State<_UpdatesSection> {
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _checking = true);
    try {
      final info = await ReleaseChecker(currentVersion: settingsAppVersion)
          .check();
      if (!mounted) return;
      if (info == null) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(l10n.settingsUpToDate)));
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.settingsUpdateAvailableTitle),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.settingsUpdateAvailableBody(info.version)),
                if (info.notes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.settingsUpdateNotes,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(info.notes),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.modelsCancel),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(context).pop();
                try {
                  final opened = await launchUrl(
                    Uri.parse(info.downloadUrl),
                    mode: LaunchMode.externalApplication,
                  );
                  if (!opened) throw StateError('No browser available');
                } catch (error) {
                  messenger
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      SnackBar(
                        content: Text('${l10n.settingsUpdateFailed}: $error'),
                      ),
                    );
                }
              },
              child: Text(l10n.settingsUpdateDownload),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('${l10n.settingsUpdateFailed}: $error')),
        );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(l10n.settingsUpdates),
        const SizedBox(height: 12),
        _Card(
          child: Material(
            color: Colors.transparent,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.system_update_alt_outlined),
              title: Text(l10n.settingsCheckUpdates),
              subtitle: Text(l10n.settingsCheckUpdatesHint),
              trailing: _checking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              enabled: !_checking,
              onTap: _check,
            ),
          ),
        ),
      ],
    );
  }
}

class _DataSection extends StatefulWidget {
  const _DataSection({required this.modelLibrary});

  final ModelLibrary? modelLibrary;

  @override
  State<_DataSection> createState() => _DataSectionState();
}

class _DataSectionState extends State<_DataSection> {
  bool _busy = false;
  BackupProgress? _progress;
  StreamSubscription<BackupProgress>? _progressSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted) return;
        final documents = await getApplicationDocumentsDirectory();
        final error = BackupService.takeRestoreError(documents.path);
        if (error == null || !mounted) return;
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l10n.settingsBackupFailed}: $error')),
        );
      } catch (_) {
        // path_provider is unavailable in widget tests; nothing to surface.
      }
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<BackupService?> _create() async {
    final library = widget.modelLibrary;
    if (library == null) return null;
    final state = AppStateScope.of(context);
    return BackupService.create(
      database: state.database,
      library: library,
      appVersion: settingsAppVersion,
    );
  }

  void _listen(BackupService service) {
    _progressSub?.cancel();
    _progress = null;
    _progressSub = service.progress.listen((value) {
      if (mounted) setState(() => _progress = value);
    });
  }

  Future<void> _export() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final service = await _create();
      if (service == null) return;
      final plan = await service.plan();
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.settingsBackupConfirmTitle),
          content: Text(
            l10n.settingsBackupConfirmBody(_formatBytes(plan.totalBytes)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.modelsCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.settingsExportBackup),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      _listen(service);
      final saved = await service.export(plan);
      if (!mounted) return;
      if (saved) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(l10n.settingsBackupExported)));
      }
    } catch (error) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('${l10n.settingsBackupFailed}: $error')),
        );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
      await _progressSub?.cancel();
      _progressSub = null;
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsBackupOverwriteTitle),
        content: Text(l10n.settingsBackupOverwriteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.modelsCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.settingsImportBackup),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final service = await _create();
      if (service == null) return;
      _listen(service);
      final staged = await service.pickAndStage();
      if (!mounted || staged == null) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.settingsBackupRestartTitle),
          content: Text(l10n.settingsBackupRestartBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.settingsBackupRestartLater),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                SystemNavigator.pop();
              },
              child: Text(l10n.settingsBackupRestartNow),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('${l10n.settingsBackupFailed}: $error')),
        );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
      await _progressSub?.cancel();
      _progressSub = null;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1 << 30) {
      return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1 << 20) {
      return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1 << 10) {
      return '${(bytes / (1 << 10)).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final enabled = !_busy && widget.modelLibrary != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(l10n.settingsData),
        const SizedBox(height: 12),
        _Card(
          child: Column(
            children: [
              Material(
                color: Colors.transparent,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.archive_outlined),
                  title: Text(l10n.settingsExportBackup),
                  subtitle: Text(l10n.settingsExportBackupHint),
                  enabled: enabled,
                  onTap: _export,
                ),
              ),
              const Divider(height: 1),
              Material(
                color: Colors.transparent,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.unarchive_outlined),
                  title: Text(l10n.settingsImportBackup),
                  subtitle: Text(l10n.settingsImportBackupHint),
                  enabled: enabled,
                  onTap: _import,
                ),
              ),
              if (_busy)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(value: _progress?.fraction),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

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
