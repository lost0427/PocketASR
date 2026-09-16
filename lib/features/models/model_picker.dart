import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../engine/model_catalog.dart';
import '../../l10n/app_localizations.dart';
import 'model_library.dart';

Future<void> showDownloadedModelPicker({
  required BuildContext context,
  required ModelLibrary library,
  required AppState state,
  VoidCallback? onManageModels,
}) => showDialog<void>(
  context: context,
  builder: (context) => _DownloadedModelDialog(
    library: library,
    state: state,
    onManageModels: onManageModels,
  ),
);

/// Resolves the catalog display name for the current selection. Legacy manual
/// selections fall back to their file name, but cannot be created by this UI.
class SelectedModelName extends StatelessWidget {
  const SelectedModelName({
    super.key,
    required this.library,
    required this.state,
    required this.emptyLabel,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
    this.style,
  });

  final ModelLibrary? library;
  final AppState state;
  final String emptyLabel;
  final int maxLines;
  final TextOverflow overflow;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => _buildName(),
  );

  Widget _buildName() {
    final path = state.modelSpec?.path;
    if (path == null) {
      return Text(
        emptyLabel,
        maxLines: maxLines,
        overflow: overflow,
        style: style,
      );
    }
    final source = library;
    if (source == null) return _text(_fileName(path));
    final currentName = source.currentData?.entryForPath(path)?.displayName;
    if (currentName != null) return _text(currentName);
    return FutureBuilder<ModelLibraryData>(
      future: source.data,
      builder: (context, snapshot) {
        final name = snapshot.data?.entryForPath(path)?.displayName;
        return _text(name ?? _fileName(path));
      },
    );
  }

  Widget _text(String value) =>
      Text(value, maxLines: maxLines, overflow: overflow, style: style);

  static String _fileName(String path) => path.split(RegExp(r'[\\/]')).last;
}

class _DownloadedModelDialog extends StatelessWidget {
  const _DownloadedModelDialog({
    required this.library,
    required this.state,
    required this.onManageModels,
  });

  final ModelLibrary library;
  final AppState state;
  final VoidCallback? onManageModels;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.modelPickerTitle),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: 480,
        child: FutureBuilder<ModelLibraryData>(
          future: library.data,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  snapshot.error.toString(),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            }
            final data = snapshot.data;
            if (data == null) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return ListenableBuilder(
              listenable: state,
              builder: (context, _) => _list(context, data),
            );
          },
        ),
      ),
      actions: [
        if (onManageModels != null)
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              onManageModels!();
            },
            icon: const Icon(Icons.download_outlined),
            label: Text(l10n.modelPickerManage),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.modelsCancel),
        ),
      ],
    );
  }

  Widget _list(BuildContext context, ModelLibraryData data) {
    final l10n = AppLocalizations.of(context);
    final models = data.downloadedAsrModels;
    if (models.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.download_for_offline_outlined,
              size: 32,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.modelPickerEmpty,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    final selectedPath = state.modelSpec?.path;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state.engineBusy)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.sync, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.modelsBusyNote,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            for (final entry in models)
              _modelTile(context, data, entry, selectedPath),
          ],
        ),
      ),
    );
  }

  Widget _modelTile(
    BuildContext context,
    ModelLibraryData data,
    ModelEntry entry,
    String? selectedPath,
  ) {
    final selected = data.store.pathFor(entry) == selectedPath;
    return ListTile(
      leading: Icon(_engineIcon(entry)),
      title: Text(entry.displayName),
      subtitle: Text(_metadata(entry)),
      trailing: selected
          ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          : null,
      enabled: !state.engineBusy,
      selected: selected,
      onTap: state.engineBusy
          ? null
          : () {
              state.selectModel(
                spec: data.store.specFor(entry),
                engineId: entry.engine ?? state.engineId,
                family: entry.family,
                quant: entry.quant,
              );
              Navigator.of(context).pop();
            },
    );
  }

  static IconData _engineIcon(ModelEntry entry) =>
      entry.engine == 'sherpa' ? Icons.hub_outlined : Icons.memory_outlined;

  static String _metadata(ModelEntry entry) => [
    entry.engine,
    entry.family,
    entry.quant,
    if (entry.languages.isNotEmpty) entry.languages.join('/'),
  ].whereType<String>().where((value) => value.isNotEmpty).join(' | ');
}
