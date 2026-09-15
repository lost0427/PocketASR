import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/search_repo.dart';
import '../../data/transcript_repo.dart';

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
    _reload();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _reload() {
    final query = _query.text.trim();
    setState(() {
      _rows = query.isEmpty
          ? (_trash ? widget.repo.listTrash() : widget.repo.list())
          : widget.search.searchLiteral(query, includeTrash: _trash);
    });
  }

  Future<void> _copy(Transcript row) async {
    await Clipboard.setData(ClipboardData(text: row.text));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
  }

  void _delete(Transcript row) {
    widget.repo.softDelete(row.id);
    _reload();
  }

  void _restore(Transcript row) {
    widget.repo.restore(row.id);
    _reload();
  }

  void _purge(Transcript row) {
    widget.repo.purge(row.id);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _query,
            onChanged: (_) => _reload(),
            decoration: InputDecoration(
              hintText: 'Search transcripts',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.text.isEmpty ? null : IconButton(
                onPressed: () { _query.clear(); _reload(); },
                icon: const Icon(Icons.clear),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              FilterChip(
                label: Text(_trash ? 'Trash' : 'History'),
                selected: _trash,
                onSelected: (value) { setState(() => _trash = value); _reload(); },
              ),
              const Spacer(),
              Text('${_rows.length}', style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
        ),
        Expanded(
          child: _rows.isEmpty
              ? const Center(child: Text('No transcripts'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  itemCount: _rows.length,
                  itemBuilder: (context, index) {
                    final row = _rows[index];
                    return Card(
                      child: ListTile(
                        title: Text(row.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(row.text, maxLines: 3, overflow: TextOverflow.ellipsis),
                        onTap: () => _copy(row),
                        trailing: PopupMenuButton<String>(
                          onSelected: (action) {
                            if (action == 'copy') _copy(row);
                            if (action == 'delete') _delete(row);
                            if (action == 'restore') _restore(row);
                            if (action == 'purge') _purge(row);
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'copy', child: Text('Copy')),
                            if (_trash) ...[
                              const PopupMenuItem(value: 'restore', child: Text('Restore')),
                              const PopupMenuItem(value: 'purge', child: Text('Delete permanently')),
                            ] else const PopupMenuItem(value: 'delete', child: Text('Move to trash')),
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
