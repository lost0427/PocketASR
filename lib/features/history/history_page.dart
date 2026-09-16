import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/search_repo.dart';
import '../../data/transcript_repo.dart';
import '../../l10n/app_localizations.dart';

/// History tab: local transcripts, literal search, and the trash flow.
///
/// Listens to [TranscriptRepo]'s ChangeNotifier, so a transcript saved by the
/// transcribe or queue page appears here without a manual refresh. The trash
/// scope searches the trash *alone* ([SearchRepo.searchLiteral] `onlyTrash`),
/// and permanent deletion is confirmed before a row is erased.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.repo, required this.search});

  final TranscriptRepo repo;
  final SearchRepo search;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final _query = TextEditingController();
  bool _trash = false;
  List<Transcript> _rows = const [];

  @override
  void initState() {
    super.initState();
    widget.repo.addListener(_onRepoChanged);
    _reload();
  }

  @override
  void didUpdateWidget(HistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A rebuilt SearchRepo (e.g. an embedder was selected) arrives with the
    // same repo; only the repo itself needs re-listening.
    if (!identical(widget.repo, oldWidget.repo)) {
      oldWidget.repo.removeListener(_onRepoChanged);
      widget.repo.addListener(_onRepoChanged);
      _reload();
    }
  }

  @override
  void dispose() {
    widget.repo.removeListener(_onRepoChanged);
    _query.dispose();
    super.dispose();
  }

  /// Repo mutations (a new transcript, a trash move) refresh the list.
  void _onRepoChanged() {
    if (mounted) _reload();
  }

  void _reload() {
    final query = _query.text.trim();
    setState(() {
      _rows = query.isEmpty
          ? (_trash ? widget.repo.listTrash() : widget.repo.list())
          : widget.search.searchLiteral(query, onlyTrash: _trash);
    });
  }

  Future<void> _copy(Transcript row) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: row.text));
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l10n.historyCopied)));
  }

  void _moveToTrash(Transcript row) {
    widget.repo.softDelete(row.id);
  }

  void _restore(Transcript row) {
    widget.repo.restore(row.id);
  }

  /// Permanent deletion is irreversible, so it asks first.
  Future<void> _confirmPurge(Transcript row) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.historyDeleteConfirmTitle),
        content: Text(l10n.historyDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.modelsCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.historyDeletePermanently),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.repo.purge(row.id);
  }

  Future<void> _openDetail(Transcript row) async {
    final l10n = AppLocalizations.of(context);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _TranscriptDetailPage(
          row: row,
          onCopy: () => _copy(row),
          actionLabel:
              _trash ? l10n.historyRestore : l10n.historyMoveToTrash,
          onAction: () {
            if (_trash) {
              _restore(row);
            } else {
              _moveToTrash(row);
            }
            Navigator.of(context).maybePop();
          },
        ),
      ),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _query,
            onChanged: (_) => _reload(),
            decoration: InputDecoration(
              hintText: l10n.historySearchHint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _query.clear();
                        _reload();
                      },
                      icon: const Icon(Icons.clear),
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: false,
                    label: Text(l10n.historyScopeHistory),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text(l10n.historyScopeTrash),
                  ),
                ],
                selected: {_trash},
                onSelectionChanged: (selection) {
                  setState(() => _trash = selection.first);
                  _reload();
                },
              ),
              const Spacer(),
              Text('${_rows.length}',
                  style: theme.textTheme.labelMedium),
            ],
          ),
        ),
        Expanded(
          child: _rows.isEmpty
              ? Center(
                  child: Text(_trash ? l10n.historyTrashEmpty : l10n.historyEmpty),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  itemCount: _rows.length,
                  itemBuilder: (context, index) {
                    final row = _rows[index];
                    return Card(
                      child: ListTile(
                        title: Text(
                          row.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          row.text,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _openDetail(row),
                        trailing: PopupMenuButton<String>(
                          onSelected: (action) {
                            switch (action) {
                              case 'copy':
                                _copy(row);
                              case 'trash':
                                _moveToTrash(row);
                              case 'restore':
                                _restore(row);
                              case 'purge':
                                _confirmPurge(row);
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'copy',
                              child: Text(l10n.historyCopy),
                            ),
                            if (_trash) ...[
                              PopupMenuItem(
                                value: 'restore',
                                child: Text(l10n.historyRestore),
                              ),
                              PopupMenuItem(
                                value: 'purge',
                                child: Text(l10n.historyDeletePermanently),
                              ),
                            ] else
                              PopupMenuItem(
                                value: 'trash',
                                child: Text(l10n.historyMoveToTrash),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Full-text detail for one transcript, with its real recorded statistics.
class _TranscriptDetailPage extends StatelessWidget {
  const _TranscriptDetailPage({
    required this.row,
    required this.onCopy,
    required this.actionLabel,
    required this.onAction,
  });

  final Transcript row;
  final VoidCallback onCopy;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final localizations = MaterialLocalizations.of(context);
    final created =
        '${localizations.formatFullDate(row.createdAt.toLocal())} '
        '${localizations.formatTimeOfDay(
          TimeOfDay.fromDateTime(row.createdAt.toLocal()),
        )}';

    final metrics = <(String, String)>[
      (l10n.historyDetailCreated, created),
      if (row.engine != null) (l10n.transcribeEngineSection, row.engine!),
      if (row.backend != null) (l10n.transcribeBackend, row.backend!),
      if (row.modelPath != null)
        (
          l10n.transcribeModel,
          row.modelPath!.split(RegExp(r'[\\/]')).last,
        ),
      if (row.rtf != null) (l10n.metricRtf, row.rtf!.toStringAsFixed(2)),
      if (row.avgTokensPerSec != null)
        (l10n.metricTokensPerSec, row.avgTokensPerSec!.toStringAsFixed(1)),
      if (row.tokens != null) ('Tokens', '${row.tokens}'),
      if (row.audioSeconds != null)
        (l10n.historyDetailAudio, '${row.audioSeconds!.toStringAsFixed(1)} s'),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(l10n.historyDetailTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(row.title, style: theme.textTheme.titleMedium),
              ),
              IconButton(
                tooltip: l10n.historyCopy,
                onPressed: onCopy,
                icon: const Icon(Icons.copy_all_outlined),
              ),
              TextButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ),
          const SizedBox(height: 12),
          if (row.audioPath != null)
            Text(
              row.audioPath!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (label, value) in metrics)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 120,
                          child: Text(
                            label,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(value, style: theme.textTheme.bodyMedium),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: SelectableText(
              row.text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
