import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/search_repo.dart';
import '../../data/semantic_indexer.dart';
import '../../data/transcript_repo.dart';
import '../../l10n/app_localizations.dart';

/// How the query is matched. Semantic and hybrid need a loaded [embedder].
enum SearchMode { literal, semantic, hybrid }

/// History tab: local transcripts, search, and the trash flow.
///
/// Listens to [TranscriptRepo]'s ChangeNotifier, so a transcript saved by the
/// transcribe or queue page appears here without a manual refresh. The trash
/// scope searches the trash *alone* ([SearchRepo.searchLiteral] `onlyTrash`),
/// and permanent deletion is confirmed before a row is erased.
class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    required this.repo,
    required this.search,
    this.indexer,
  });

  final TranscriptRepo repo;
  final SearchRepo search;

  /// The semantic indexer, when an embedding model is loaded. Drives the
  /// indexing status row and its retry/rebuild actions.
  final SemanticIndexer? indexer;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final _query = TextEditingController();
  bool _trash = false;
  SearchMode _mode = SearchMode.literal;
  List<Transcript> _rows = const [];

  bool get _hasEmbedder => widget.search.embedder != null;

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
    } else if (!identical(widget.search, oldWidget.search)) {
      // The embedder changed: a semantic/hybrid mode may no longer be valid.
      if (!_hasEmbedder && _mode != SearchMode.literal) {
        _mode = SearchMode.literal;
      }
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

  /// Guards the async semantic/hybrid reloads: only the newest request may
  /// write [_rows], so a slow encode for an older query can never overwrite
  /// the result of a newer one, and a result arriving after dispose is
  /// dropped instead of a setState-after-dispose crash.
  int _reloadSeq = 0;

  void _reload() {
    final query = _query.text.trim();
    final mode = _hasEmbedder ? _mode : SearchMode.literal;
    final seq = ++_reloadSeq;
    if (query.isEmpty) {
      setState(() {
        _rows = _trash ? widget.repo.listTrash() : widget.repo.list();
      });
      return;
    }
    if (mode == SearchMode.literal) {
      setState(() {
        _rows = widget.search.searchLiteral(query, onlyTrash: _trash);
      });
      return;
    }
    // Semantic/hybrid embed on the worker isolate, so the rows land later.
    unawaited(() async {
      final rows = await (mode == SearchMode.semantic
          ? widget.search.searchSemantic(query, onlyTrash: _trash)
          : widget.search.searchHybrid(query, onlyTrash: _trash));
      if (!mounted || seq != _reloadSeq) return; // superseded or disposed
      setState(() => _rows = rows);
    }());
  }

  /// Compact status row for the semantic indexer: a live phase, its error, and
  /// the retry/rebuild actions. Nothing here invents progress.
  Widget _indexStatus(AppLocalizations l10n) {
    final indexer = widget.indexer!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ValueListenableBuilder<SemanticIndexPhase>(
      valueListenable: indexer.phase,
      builder: (context, phase, _) {
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              if (phase == SemanticIndexPhase.running) ...[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  l10n.historyIndexing,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ] else if (phase == SemanticIndexPhase.failed) ...[
                Icon(Icons.error_outline, size: 16, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${l10n.historyIndexFailed}: ${indexer.lastError ?? ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: indexer.indexPending,
                  child: Text(l10n.historyIndexRetry),
                ),
              ],
              const Spacer(),
              TextButton(
                onPressed: indexer.rebuild,
                child: Text(l10n.historyIndexRebuild),
              ),
            ],
          ),
        );
      },
    );
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
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
                  Text('${_rows.length}', style: theme.textTheme.labelMedium),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  SegmentedButton<SearchMode>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: SearchMode.literal,
                        label: Text(l10n.historySearchLiteral),
                      ),
                      ButtonSegment(
                        value: SearchMode.semantic,
                        enabled: _hasEmbedder,
                        label: Text(l10n.historySearchSemantic),
                      ),
                      ButtonSegment(
                        value: SearchMode.hybrid,
                        enabled: _hasEmbedder,
                        label: Text(l10n.historySearchHybrid),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (selection) {
                      setState(() => _mode = selection.first);
                      _reload();
                    },
                  ),
                ],
              ),
              if (!_hasEmbedder)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    l10n.historySearchSemanticOff,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (widget.indexer != null) _indexStatus(l10n),
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
