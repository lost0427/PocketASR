import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../engine/asr_engine.dart';
import '../../engine/embedder.dart';
import '../../engine/model_catalog.dart';
import '../../engine/model_downloader.dart';
import '../../l10n/app_localizations.dart';
import 'model_library.dart';

/// Runs one model download. Matches [ModelDownloader.download] so production can
/// pass the real method and tests can pass a fake.
typedef ModelDownloadRunner = Future<void> Function(
  ModelEntry entry, {
  void Function(ModelDownloadProgress progress)? onProgress,
  Future<void>? cancel,
});

/// Models tab: the curated allowlist, what is on disk, and the download/delete
/// chain for each entry.
///
/// Production resolves the app-private model directory through `path_provider`
/// and builds a [LocalModelStore] plus a [ModelDownloader]; an entry with no
/// `url` says "not available for download" rather than showing a button that
/// cannot work. [entries], [store] and [download] are injection seams for
/// tests, which keep the page off the network and the platform channel.
class ModelsPage extends StatefulWidget {
  const ModelsPage({
    super.key,
    this.entries,
    this.store,
    this.download,
    this.state,
    this.library,
  });

  /// Pre-loaded catalog; when null the page reads [modelAllowlistAsset].
  final List<ModelEntry>? entries;

  /// Model files to inspect; when null the page builds a [LocalModelStore] over
  /// the app-private model directory.
  final ModelStore? store;

  /// Download implementation; when null the page builds a [ModelDownloader].
  final ModelDownloadRunner? download;

  /// App-wide selection shared with the transcribe and queue pages. Picking a
  /// bundle here is what those pages then load, so it must be the same object.
  /// Null only in tests that render the list without a selection.
  final AppState? state;

  /// Shared production catalog/store. Explicit [entries] and [store] remain
  /// available as focused test seams and take precedence.
  final ModelLibrary? library;

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  late final Future<List<ModelEntry>> _entries = _loadEntries();

  /// Resolves the store in the background. Until it lands — and if it fails —
  /// the list still renders, just without local file facts or downloads.
  late final Future<ModelStore?> _store = _resolveStore();

  /// Live downloads by entry id; an absent id means "not downloading".
  final Map<String, _DownloadJob> _jobs = {};

  Future<List<ModelEntry>> _loadEntries() async {
    final entries = widget.entries;
    if (entries != null) return entries;
    final library = widget.library;
    if (library != null) return library.entries;
    return loadModelAllowlist();
  }

  Future<ModelStore?> _resolveStore() async {
    final injected = widget.store;
    if (injected != null) return injected;
    try {
      final library = widget.library;
      if (library != null) return await library.store;
      return await ModelLibrary.local().store;
    } catch (_) {
      return null; // no directory: offer no downloads rather than fake one
    }
  }

  /// Real downloader when the page owns the store, else the injected runner.
  /// Null means downloads cannot run, so the tile must not offer one.
  ModelDownloadRunner? _runnerFor(ModelStore? store) {
    if (widget.download != null) return widget.download;
    if (store is LocalModelStore) return ModelDownloader(store).download;
    return null;
  }

  Future<void> _startDownload(
    ModelEntry entry,
    ModelStore store,
    ModelDownloadRunner runner,
  ) async {
    final job = _DownloadJob();
    setState(() => _jobs[entry.id] = job);
    try {
      await runner(
        entry,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _jobs[entry.id]?.progress = progress);
        },
        cancel: job.cancel.future,
      );
      if (!mounted) return;
      setState(() => _jobs.remove(entry.id)); // file is on disk now
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (job.cancelRequested) {
          _jobs.remove(entry.id); // user cancelled: back to the idle state
        } else {
          job.error = error.toString();
        }
      });
    }
  }

  /// Asks the running download to stop; the runner throws once it notices.
  void _cancelDownload(ModelEntry entry) {
    final job = _jobs[entry.id];
    if (job == null || job.cancelRequested) return;
    setState(() => job.cancelRequested = true);
    job.cancel.complete();
  }

  Future<void> _delete(ModelEntry entry, ModelStore store) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.modelsDeleteConfirmTitle),
        content: Text(l10n.modelsDeleteConfirmBody(entry.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.modelsCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.modelsDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await store.delete(entry);
    // Deleting the selected bundle leaves nothing to run: clear just the
    // selection that pointed at this bundle (ASR, VAD and embedding are
    // independent choices) and let the pages fall back.
    final state = widget.state;
    if (state != null) {
      final path = store.pathFor(entry);
      if (state.modelSpec?.path == path) state.clearModelSelection();
      if (state.embeddingPath == path) state.clearEmbedding();
      if (state.vadModelPath == path) state.clearVadSelection();
    }
    if (mounted) setState(() {});
  }

  /// Adopts a downloaded bundle as the model the transcribe and queue flows
  /// load: one call carries engine, family, quant and the full spec, so the
  /// companions this entry ships reach the engine instead of being dropped.
  void _use(ModelEntry entry, ModelStore store, AppState state) {
    if (state.engineBusy) return; // a run owns the loaded instance
    state.selectModel(
      spec: store.specFor(entry),
      engineId: entry.engine ?? state.engineId,
      family: entry.family,
      quant: entry.quant,
    );
  }

  /// Routes a tile's Use button to the selection it actually changes. A VAD
  /// bundle is *never* adopted as the ASR model.
  void _adopt(
    _ModelKind kind,
    ModelEntry entry,
    ModelStore store,
    AppState state,
  ) {
    switch (kind) {
      case _ModelKind.asr:
        _use(entry, store, state);
      case _ModelKind.embedding:
        state.selectEmbedding(
          path: store.pathFor(entry),
          profile: switch (entry.family) {
            'qwen3' => EmbeddingModelProfile.qwen3,
            _ => EmbeddingModelProfile.metadata,
          },
        );
      case _ModelKind.vad:
        state.selectVad(
          path: store.pathFor(entry),
          family: switch (entry.family) {
            'ten' => VadModelFamily.ten,
            'silero' => VadModelFamily.silero,
            _ => throw StateError(
              'Unsupported VAD model family "${entry.family}".',
            ),
          },
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final content = _buildContent(context);
    if (state == null) return content;
    // Rebuild on selection/busy changes even when no ancestor listens.
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return FutureBuilder<List<ModelEntry>>(
      future: _entries,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                snapshot.error.toString(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          );
        }
        final entries = snapshot.data;
        if (entries == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (entries.isEmpty) {
          return Center(
            child: Text(
              l10n.modelsNoModels,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }

        return FutureBuilder<ModelStore?>(
          future: _store,
          builder: (context, storeSnapshot) =>
              _buildList(context, l10n, entries, storeSnapshot.data),
        );
      },
    );
  }

  Widget _buildList(
    BuildContext context,
    AppLocalizations l10n,
    List<ModelEntry> entries,
    ModelStore? store,
  ) {
    final runner = _runnerFor(store);
    final state = widget.state;
    final scheme = Theme.of(context).colorScheme;
    final asr = [
      for (final e in entries)
        if (e.type != 'embedding' && e.type != 'vad') e,
    ];
    final vad = [
      for (final e in entries)
        if (e.type == 'vad') e,
    ];
    final embedding = [
      for (final e in entries)
        if (e.type == 'embedding') e,
    ];

    Widget tile(
      ModelEntry entry, {
      required _ModelKind kind,
      required bool selectable,
    }) {
      final canSelect =
          selectable &&
          store != null &&
          state != null &&
          store.isDownloaded(entry);
      final path = store?.pathFor(entry);
      final selected =
          state != null &&
          store != null &&
          store.isDownloaded(entry) &&
          switch (kind) {
            _ModelKind.asr => state.modelSpec?.path == path,
            _ModelKind.embedding => state.embeddingPath == path,
            _ModelKind.vad => state.vadModelPath == path,
          };
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _ModelTile(
          entry: entry,
          store: store,
          job: _jobs[entry.id],
          downloadable: entry.url != null && entry.url!.isNotEmpty,
          canStart: store != null && runner != null,
          selectable: canSelect,
          selected: selected,
          busy: state?.engineBusy ?? false,
          onUse: canSelect ? () => _adopt(kind, entry, store, state) : null,
          onDownload: (store == null || runner == null)
              ? null
              : () => _startDownload(entry, store, runner),
          onCancel: () => _cancelDownload(entry),
          onDelete: store == null ? null : () => _delete(entry, store),
        ),
      );
    }

    Iterable<Widget> frameworkTiles(
      List<ModelEntry> models,
      _ModelKind kind,
    ) sync* {
      final groups = <String?, List<ModelEntry>>{};
      for (final model in models) {
        groups.putIfAbsent(model.engine, () => []).add(model);
      }

      var firstGroup = true;
      for (final group in groups.values) {
        if (!firstGroup) {
          yield Divider(
            height: 24,
            thickness: 0.6,
            color: scheme.outlineVariant,
          );
        }
        firstGroup = false;
        for (final entry in group) {
          yield tile(entry, kind: kind, selectable: true);
        }
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (state?.modelSelectionMissing ?? false) ...[
          _Notice(
            icon: Icons.warning_amber_rounded,
            text: l10n.modelSelectionMissing,
            color: scheme.error,
          ),
          const SizedBox(height: 12),
        ],
        if (state?.vadSelectionMissing ?? false) ...[
          _Notice(
            icon: Icons.warning_amber_rounded,
            text: l10n.vadModelRequired,
            color: scheme.error,
          ),
          const SizedBox(height: 12),
        ],
        if (state?.engineBusy ?? false) ...[
          _Notice(
            icon: Icons.sync,
            text: l10n.modelsBusyNote,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
        ],
        if ((state?.embeddingPath ?? '').isNotEmpty &&
            !(state?.embeddingReady ?? false)) ...[
          _Notice(
            icon: Icons.warning_amber_rounded,
            text: '${l10n.modelsEmbeddingError} ${state!.embeddingError ?? ''}',
            color: scheme.error,
          ),
          const SizedBox(height: 12),
        ],
        _UsageCard(
          label: l10n.modelsTotalUsage,
          value: store == null
              ? l10n.metricUnavailable
              : _formatBytes(store.diskUsageBytes(entries)),
        ),
        if (asr.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionLabel(l10n.modelsAsrSection),
          const SizedBox(height: 12),
          ...frameworkTiles(asr, _ModelKind.asr),
        ],
        if (vad.isNotEmpty) ...[
          const SizedBox(height: 12),
          _SectionLabel(l10n.modelsVadSection),
          const SizedBox(height: 6),
          Text(
            l10n.modelsVadNote,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
          ),
          const SizedBox(height: 12),
          ...frameworkTiles(vad, _ModelKind.vad),
        ],
        if (embedding.isNotEmpty) ...[
          const SizedBox(height: 12),
          _SectionLabel(l10n.modelsEmbeddingSection),
          const SizedBox(height: 6),
          Text(
            l10n.modelsEmbeddingNote,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
          ),
          const SizedBox(height: 12),
          ...frameworkTiles(embedding, _ModelKind.embedding),
        ],
      ],
    );
  }
}

/// Which independent selection a model tile's Use button changes.
enum _ModelKind { asr, embedding, vad }

/// One in-flight download. Mutable by design; the page owns its transitions.
class _DownloadJob {
  final Completer<void> cancel = Completer<void>();
  ModelDownloadProgress? progress;
  bool cancelRequested = false;
  String? error;

  bool get isActive => error == null;
}

/// One-line note above the list: a selection file is gone, or a run is active.
class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, required this.color});

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

/// Section heading matching the transcribe/settings labels.
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

/// Total disk space the downloaded models take.
class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.storage, color: scheme.onSecondaryContainer),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.entry,
    required this.store,
    required this.job,
    required this.downloadable,
    required this.canStart,
    required this.selectable,
    required this.selected,
    required this.busy,
    required this.onUse,
    required this.onDownload,
    required this.onCancel,
    required this.onDelete,
  });

  final ModelEntry entry;

  /// Null until the model directory resolves; then no local facts are known.
  final ModelStore? store;

  final _DownloadJob? job;

  /// True when the allowlist carries a URL for this entry.
  final bool downloadable;

  /// True when a store and runner exist to actually perform the download.
  final bool canStart;

  /// True when this entry is a downloaded ASR bundle that can be adopted.
  final bool selectable;

  /// True when this entry is the model the transcribe/queue flows will load.
  final bool selected;

  /// True while a run owns the loaded instance; selecting is refused then.
  final bool busy;

  final VoidCallback? onUse;
  final VoidCallback? onDownload;
  final VoidCallback onCancel;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final downloaded = store?.isDownloaded(entry) ?? false;
    final active = job != null && job!.isActive;

    // Downloaded entries show what is really on disk; the rest show the
    // catalog's declared size when it has one, and omit it otherwise. Engine,
    // languages and license come straight from the allowlist.
    final size = downloaded ? store!.diskUsageBytes([entry]) : entry.sizeBytes;
    final details = [
      if (entry.engine != null) entry.engine!,
      if (entry.family != null) entry.family!,
      if (entry.quant != null) entry.quant!,
      if (entry.parameters != null)
        l10n.modelsParameterCount(
          (entry.parameters! / 1000000).toStringAsFixed(1),
        ),
      if (entry.languages.isNotEmpty) entry.languages.join('/'),
      if (size != null) _formatBytes(size),
    ];

    final (String status, _StatusTone tone) = _status(
      l10n,
      downloaded: downloaded,
      active: active,
      downloadable: downloadable,
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.layers_outlined,
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.displayName, style: theme.textTheme.titleSmall),
                    if (details.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        details.join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (entry.license != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        entry.license!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _StatusChip(label: status, tone: tone),
            ],
          ),
          if (active) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: job!.progress?.ratio,
                minHeight: 8,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _progressLabel(l10n, job!.progress),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: job!.cancelRequested ? null : onCancel,
                  child: Text(l10n.modelsCancel),
                ),
              ],
            ),
          ],
          if (!active && job?.error != null) ...[
            const SizedBox(height: 8),
            Text(
              '${l10n.modelsDownloadFailed}: ${job!.error}',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
          if (!active && (selectable || downloaded || downloadable)) ...[
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                if (selectable) ...[
                  FilledButton.tonalIcon(
                    onPressed: (selected || busy || onUse == null)
                        ? null
                        : onUse,
                    icon: Icon(
                      selected
                          ? Icons.check_circle_outline
                          : Icons.play_circle_outline,
                      size: 18,
                    ),
                    label: Text(selected ? l10n.modelsInUse : l10n.modelsUse),
                  ),
                ],
                // Downloaded entries can be deleted; entries the allowlist
                // gives no URL never get a download button.
                if (downloaded && onDelete != null)
                  OutlinedButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text(l10n.modelsDelete),
                  )
                else if (!downloaded && downloadable && onDownload != null)
                  FilledButton.tonalIcon(
                    onPressed: onDownload,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: Text(l10n.modelsDownload),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  (String, _StatusTone) _status(
    AppLocalizations l10n, {
    required bool downloaded,
    required bool active,
    required bool downloadable,
  }) {
    if (active) return (l10n.modelsDownloading, _StatusTone.busy);
    if (downloaded) return (l10n.modelsDownloaded, _StatusTone.active);
    if (!downloadable || !canStart) {
      return (l10n.modelsNotDownloadable, _StatusTone.idle);
    }
    return (l10n.modelsNotDownloaded, _StatusTone.idle);
  }
}

enum _StatusTone { active, busy, idle }

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.tone});

  final String label;
  final _StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (Color background, Color foreground) = switch (tone) {
      _StatusTone.active => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      _StatusTone.busy => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      _StatusTone.idle => (Colors.transparent, scheme.onSurfaceVariant),
    };

    return Container(
      constraints: const BoxConstraints(maxWidth: 168),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: tone == _StatusTone.idle ? scheme.outlineVariant : background,
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: theme.textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Percent while the total is known, otherwise an indeterminate "Downloading".
String _progressLabel(AppLocalizations l10n, ModelDownloadProgress? progress) {
  final ratio = progress?.ratio;
  if (ratio == null) return l10n.modelsDownloading;
  return '${(ratio * 100).round()}%';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit - 1]}';
}
