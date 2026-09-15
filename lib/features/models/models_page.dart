import 'package:flutter/material.dart';

import '../../engine/model_catalog.dart';

/// Models tab: the curated allowlist and whether each file is on disk.
///
/// This build ships no downloader, so an entry can only be "not downloaded";
/// the page says exactly that instead of showing a download button that would
/// do nothing. [store] is injected so wiring a real model directory (and the
/// localized status strings) can land with the download work.
class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key, this.entries, this.store});

  /// Pre-loaded catalog; when null the page reads [modelAllowlistAsset].
  final List<ModelEntry>? entries;

  /// Local files to check; when null every entry reads as not downloaded.
  final ModelStore? store;

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  late final Future<List<ModelEntry>> _entries = widget.entries != null
      ? Future.value(widget.entries!)
      : loadModelAllowlist();

  @override
  Widget build(BuildContext context) {
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
              _emptyLabel(context),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          itemCount: entries.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) =>
              _ModelTile(entry: entries[index], store: widget.store),
        );
      },
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({required this.entry, this.store});

  final ModelEntry entry;
  final ModelStore? store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final downloaded = store?.isDownloaded(entry) ?? false;

    final details = [
      if (entry.family != null) entry.family!,
      if (entry.quant != null) entry.quant!,
      if (entry.sizeBytes != null) _formatBytes(entry.sizeBytes!),
    ];

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
          Chip(
            label: Text(
              downloaded ? _downloadedLabel(context) : _notDownloadedLabel(context),
            ),
            visualDensity: VisualDensity.compact,
            side: BorderSide(
              color: downloaded ? scheme.primary : scheme.outlineVariant,
            ),
            backgroundColor: downloaded
                ? scheme.primaryContainer
                : Colors.transparent,
          ),
        ],
      ),
    );
  }
}

// ponytail: l10n files are outside this phase's write scope, so these two
// strings are picked by locale here. Move to app_en/app_zh.arb when the page
// is wired into the nav.
String _notDownloadedLabel(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh'
    ? '未下载'
    : 'Not downloaded';

String _downloadedLabel(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh' ? '已下载' : 'Downloaded';

String _emptyLabel(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh'
    ? '没有可用模型'
    : 'No models available';

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
