import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/text/token_counter.dart';
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
  final Set<int> _selectedIds = {};

  bool get _hasEmbedder => widget.search.embedder != null;
  bool get _selecting => _selectedIds.isNotEmpty;

  List<Transcript> get _selectedRows => [
    for (final row in _rows)
      if (_selectedIds.contains(row.id)) row,
  ];

  /// The literal terms to mark in results. Only a literal search has words that
  /// really occur in the text, so semantic/hybrid mark nothing: a semantic hit
  /// that shares no word with the query must not look like a literal one.
  List<String> get _hitTerms {
    if (_mode != SearchMode.literal) return const [];
    final query = _query.text.trim();
    if (query.isEmpty) return const [];
    return query.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  }

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
      _selectedIds.clear();
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

  void _showRows(List<Transcript> rows) {
    final visibleIds = rows.map((row) => row.id).toSet();
    setState(() {
      _rows = rows;
      _selectedIds.removeWhere((id) => !visibleIds.contains(id));
    });
  }

  void _reload() {
    final query = _query.text.trim();
    final mode = _hasEmbedder ? _mode : SearchMode.literal;
    final seq = ++_reloadSeq;
    if (query.isEmpty) {
      _showRows(_trash ? widget.repo.listTrash() : widget.repo.list());
      return;
    }
    if (mode == SearchMode.literal) {
      _showRows(widget.search.searchLiteral(query, onlyTrash: _trash));
      return;
    }
    // Semantic/hybrid embed on the worker isolate, so the rows land later.
    unawaited(() async {
      final rows = await (mode == SearchMode.semantic
          ? widget.search.searchSemantic(query, onlyTrash: _trash)
          : widget.search.searchHybrid(query, onlyTrash: _trash));
      if (!mounted || seq != _reloadSeq) return; // superseded or disposed
      _showRows(rows);
    }());
  }

  /// Compact status row for the semantic indexer: a live phase, its error, the
  /// retry/rebuild actions, and — while a job runs — measured progress with the
  /// live encode speed and the ETA that speed implies. Nothing here invents a
  /// figure: the bar, the rates and the ETA only appear once a chunk has really
  /// finished.
  Widget _indexStatus(AppLocalizations l10n) {
    final indexer = widget.indexer!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detailStyle = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return ValueListenableBuilder<SemanticIndexPhase>(
      valueListenable: indexer.phase,
      builder: (context, phase, _) {
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (phase == SemanticIndexPhase.running) ...[
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(l10n.historyIndexing, style: detailStyle),
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
              if (phase == SemanticIndexPhase.running)
                ValueListenableBuilder<SemanticIndexProgress>(
                  valueListenable: indexer.progress,
                  builder: (context, progress, _) {
                    // An empty pending set has no denominator to show.
                    if (progress.graphemesTotal == 0) {
                      return const SizedBox.shrink();
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 6),
                        LinearProgressIndicator(value: progress.fraction),
                        const SizedBox(height: 6),
                        Text(
                          _progressDetail(l10n, progress),
                          style: detailStyle,
                        ),
                      ],
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  /// `3/12 chunks · 812 chars/s · ~2:10 left`, dropping each part that is not
  /// measured yet instead of printing a placeholder for it.
  static String _progressDetail(
    AppLocalizations l10n,
    SemanticIndexProgress progress,
  ) {
    final rate = progress.lastChunkGraphemesPerSecond;
    final remaining = progress.remaining;
    return [
      l10n.historyIndexChunks(progress.chunksDone, progress.chunksTotal),
      if (rate != null) l10n.historyIndexSpeed(rate.round()),
      if (remaining != null) l10n.historyIndexEta(_clock(remaining)),
    ].join(' · ');
  }

  /// `2:10`, `45:00` — minutes and seconds, no locale-specific units, so an
  /// estimate that spans hours stays readable.
  static String _clock(Duration remaining) {
    final seconds = remaining.inSeconds % 60;
    return '${remaining.inMinutes}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _copy(Transcript row) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: row.text));
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l10n.historyCopied)));
  }

  void _startSelection(Transcript row) {
    setState(() => _selectedIds.add(row.id));
  }

  void _toggleSelection(Transcript row) {
    setState(() {
      if (!_selectedIds.remove(row.id)) _selectedIds.add(row.id);
    });
  }

  void _clearSelection() {
    if (!_selecting) return;
    setState(_selectedIds.clear);
  }

  void _toggleSelectAll() {
    setState(() {
      final allSelected =
          _rows.isNotEmpty &&
          _rows.every((row) => _selectedIds.contains(row.id));
      if (allSelected) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(_rows.map((row) => row.id));
      }
    });
  }

  Future<void> _copySelected() async {
    final rows = _selectedRows;
    if (rows.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(
      ClipboardData(text: rows.map((row) => row.text).join('\n\n')),
    );
    if (!mounted) return;
    _clearSelection();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(l10n.historyCopiedMany(rows.length))),
      );
  }

  void _moveSelectedToTrash() {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    _clearSelection();
    widget.repo.softDeleteMany(ids);
  }

  void _restoreSelected() {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    _clearSelection();
    widget.repo.restoreMany(ids);
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

  Future<void> _confirmPurgeSelected() async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.historyDeleteConfirmTitle),
        content: Text(l10n.historyDeleteManyConfirmBody(ids.length)),
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
    if (!mounted || confirmed != true) return;
    _clearSelection();
    widget.repo.purgeMany(ids);
  }

  Widget _selectionBar(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final allSelected =
        _rows.isNotEmpty && _rows.every((row) => _selectedIds.contains(row.id));
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: l10n.modelsCancel,
            onPressed: _clearSelection,
            icon: const Icon(Icons.close),
          ),
          Expanded(
            child: Semantics(
              label: l10n.historySelectedCount(_selectedIds.length),
              child: Text(
                '${_selectedIds.length}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          IconButton(
            tooltip: allSelected
                ? l10n.historyDeselectAll
                : l10n.historySelectAll,
            onPressed: _toggleSelectAll,
            icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          ),
          IconButton(
            tooltip: l10n.historyCopy,
            onPressed: _copySelected,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          if (_trash) ...[
            IconButton(
              tooltip: l10n.historyRestore,
              onPressed: _restoreSelected,
              icon: const Icon(Icons.restore_from_trash_outlined),
            ),
            IconButton(
              tooltip: l10n.historyDeletePermanently,
              onPressed: _confirmPurgeSelected,
              color: scheme.error,
              icon: const Icon(Icons.delete_forever_outlined),
            ),
          ] else
            IconButton(
              tooltip: l10n.historyMoveToTrash,
              onPressed: _moveSelectedToTrash,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
    );
  }

  Future<void> _openDetail(Transcript row) async {
    final l10n = AppLocalizations.of(context);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _TranscriptDetailPage(
          row: row,
          highlightTerms: _hitTerms,
          onCopy: () => _copy(row),
          actionLabel: _trash ? l10n.historyRestore : l10n.historyMoveToTrash,
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
    // Literal hit terms to mark in each row; empty for semantic/hybrid.
    final terms = _hitTerms;
    final mark = _markStyle(theme.colorScheme);

    final body = Column(
      children: [
        if (_selecting) _selectionBar(l10n),
        if (!_selecting)
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
        if (!_selecting)
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
                    Expanded(
                      child: SegmentedButton<SearchMode>(
                        expandedInsets: EdgeInsets.zero,
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
                  child: Text(
                    _trash ? l10n.historyTrashEmpty : l10n.historyEmpty,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  itemCount: _rows.length,
                  itemBuilder: (context, index) {
                    final row = _rows[index];
                    final selected = _selectedIds.contains(row.id);
                    return Card(
                      color: selected
                          ? theme.colorScheme.secondaryContainer
                          : null,
                      child: ListTile(
                        selected: selected,
                        leading: _selecting
                            ? Checkbox(
                                value: selected,
                                onChanged: (_) => _toggleSelection(row),
                              )
                            : null,
                        title: Text.rich(
                          TextSpan(
                            children: _highlight(row.title, terms, mark),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text.rich(
                          TextSpan(children: _highlight(row.text, terms, mark)),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _selecting
                            ? _toggleSelection(row)
                            : _openDetail(row),
                        onLongPress: () => _startSelection(row),
                        trailing: _selecting
                            ? null
                            : PopupMenuButton<String>(
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
                                      child: Text(
                                        l10n.historyDeletePermanently,
                                      ),
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
    return PopScope<void>(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: body,
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
    this.highlightTerms = const [],
  });

  final Transcript row;
  final VoidCallback onCopy;
  final String actionLabel;
  final VoidCallback onAction;

  /// Literal search terms to mark in the body; empty for a plain open, so the
  /// full text reads normally when it was not reached through a literal search.
  final List<String> highlightTerms;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final localizations = MaterialLocalizations.of(context);
    final created =
        '${localizations.formatFullDate(row.createdAt.toLocal())} '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(row.createdAt.toLocal()))}';
    final charsPerSec = row.totalMs == null
        ? null
        : graphemesPerSecond(row.text, Duration(milliseconds: row.totalMs!));

    final metrics = <(String, String)>[
      (l10n.historyDetailCreated, created),
      // Total wall clock for the run, shown with the same shape and label as
      // the transcribe page's elapsed tile.
      if (row.totalMs != null)
        (l10n.metricElapsed, _elapsedLabel(row.totalMs!)),
      if (row.engine != null) (l10n.transcribeEngineSection, row.engine!),
      if (row.backend != null) (l10n.transcribeBackend, row.backend!),
      if (row.modelPath != null)
        (l10n.transcribeModel, row.modelPath!.split(RegExp(r'[\\/]')).last),
      if (row.rtf != null) (l10n.metricRtf, row.rtf!.toStringAsFixed(2)),
      if (charsPerSec != null)
        (l10n.metricCharsPerSec, charsPerSec.toStringAsFixed(1)),
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
            child: SelectableText.rich(
              TextSpan(
                children: _highlight(
                  row.text,
                  highlightTerms,
                  _markStyle(scheme),
                ),
              ),
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Marker for a literal search hit: a soft accent behind the real text, merged
/// with whatever style the surrounding text already has.
TextStyle _markStyle(ColorScheme scheme) => TextStyle(
  backgroundColor: scheme.tertiaryContainer,
  color: scheme.onTertiaryContainer,
  fontWeight: FontWeight.w600,
);

/// Splits [text] into spans, marking every occurrence of a literal search
/// [term]. Matching is a plain, case-insensitive substring scan of the original
/// string — no regex, so query text can never become a pattern, and the
/// original casing is kept in the output. Nothing is marked when nothing
/// matches, so a semantic hit that shares no word with the query stays plain.
List<TextSpan> _highlight(String text, List<String> terms, TextStyle mark) {
  if (terms.isEmpty) return [TextSpan(text: text)];
  final lower = text.toLowerCase();
  final hits = <(int, int)>[];
  for (final term in terms) {
    final needle = term.toLowerCase();
    if (needle.isEmpty) continue;
    for (
      var at = lower.indexOf(needle);
      at >= 0;
      at = lower.indexOf(needle, at + needle.length)
    ) {
      hits.add((at, at + needle.length));
    }
  }
  if (hits.isEmpty) return [TextSpan(text: text)];
  hits.sort((a, b) => a.$1.compareTo(b.$1));

  final spans = <TextSpan>[];
  var cursor = 0;
  for (final (start, end) in hits) {
    if (start < cursor) continue; // already covered by an earlier hit
    if (start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, start)));
    }
    spans.add(TextSpan(text: text.substring(start, end), style: mark));
    cursor = end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return spans;
}

/// Wall clock as `500ms` or `2.0s` — the same shape the transcribe page's
/// elapsed tile uses, so one run reads the same in both places.
String _elapsedLabel(int millis) =>
    millis < 1000 ? '${millis}ms' : '${(millis / 1000).toStringAsFixed(1)}s';
