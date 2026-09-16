import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../engine/model_catalog.dart';
import '../../engine/model_downloader.dart';
import '../../l10n/app_localizations.dart';

/// Runs one model download. Matches [ModelDownloader.download] so production can
/// pass the real method and tests can pass a fake.
typedef ModelDownloadRunner =
    Future<void> Function(
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
  const ModelsPage({super.key, this.entries, this.store, this.download});

  /// Pre-loaded catalog; when null the page reads [modelAllowlistAsset].
  final List<ModelEntry>? entries;

  /// Model files to inspect; when null the page builds a [LocalModelStore] over
  /// the app-private model directory.
  final ModelStore? store;

  /// Download implementation; when null the page builds a [ModelDownloader].
  final ModelDownloadRunner? download;

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

  Future<List<ModelEntry>> _loadEntries() async =>
      widget.entries ?? await loadModelAllowlist();

  Future<ModelStore?> _resolveStore() async {
    final injected = widget.store;
    if (injected != null) return injected;
    try {
      return LocalModelStore(await _modelDirectory());
    } catch (_) {
      return null; // no directory: offer no downloads rather than fake one
    }
  }

  /// App-private directory the models are downloaded into.
  Future<Directory> _modelDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}models');
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
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _UsageCard(
          label: l10n.modelsTotalUsage,
          value: store == null
              ? l10n.metricUnavailable
              : _formatBytes(store.diskUsageBytes(entries)),
        ),
        const SizedBox(height: 16),
        for (final entry in entries) ...[
          _ModelTile(
            entry: entry,
            store: store,
            job: _jobs[entry.id],
            downloadable: entry.url != null && entry.url!.isNotEmpty,
            canStart: store != null && runner != null,
            onDownload: (store == null || runner == null)
                ? null
                : () => _startDownload(entry, store, runner),
            onCancel: () => _cancelDownload(entry),
            onDelete: store == null ? null : () => _delete(entry, store),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

/// One in-flight download. Mutable by design; the page owns its transitions.
class _DownloadJob {
  final Completer<void> cancel = Completer<void>();
  ModelDownloadProgress? progress;
  bool cancelRequested = false;
  String? error;

  bool get isActive => error == null;
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
    // catalog's declared size when it has one, and omit it otherwise.
    final size = downloaded ? store!.diskUsageBytes([entry]) : entry.sizeBytes;
    final details = [
      if (entry.family != null) entry.family!,
      if (entry.quant != null) entry.quant!,
      if (size != null) _formatBytes(size),
    ];

    final (String status, _StatusTone tone) = _status(
      l10n,
      downloaded: downloaded,
      active: active,
      downloadable: downloadable,
    );
    // Downloaded entries can be deleted; entries the allowlist gives no URL
    // never get a download button, no matter what the runner could do.
    final action = downloaded
        ? onDelete
        : (downloadable ? onDownload : null);

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
          if (!active && action != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: downloaded
                  ? OutlinedButton.icon(
                      onPressed: action,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text(l10n.modelsDelete),
                    )
                  : FilledButton.tonalIcon(
                      onPressed: action,
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: Text(l10n.modelsDownload),
                    ),
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
      _StatusTone.active => (scheme.primaryContainer, scheme.onPrimaryContainer),
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
