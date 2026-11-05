import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../engine/model_catalog.dart';

typedef ModelEntriesLoader = Future<List<ModelEntry>> Function();
typedef ModelStoreLoader = Future<ModelStore> Function();

/// Deletes bundles whose engine no longer exists in this build.
///
/// Runs before any engine can load a model, so the directory is not in use.
/// On Windows a locked file must not fail startup: it is left for the next run.
Future<void> retireRemovedModelBundles(String supportPath) async {
  const removed = ['crispasr-sensevoice-q8', 'crispasr-qwen3-asr-0.6b-q8'];
  final models = '$supportPath${Platform.pathSeparator}models';
  for (final id in removed) {
    final dir = Directory('$models${Platform.pathSeparator}$id');
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {
      // Retried on the next launch.
    }
  }
}

/// The catalog and local store shared by every model-selection surface.
class ModelLibrary {
  ModelLibrary(this._loadEntries, this._loadStore);

  factory ModelLibrary.local() => ModelLibrary(loadModelAllowlist, () async {
    final base = await getApplicationSupportDirectory();
    return LocalModelStore(
      Directory('${base.path}${Platform.pathSeparator}models'),
    );
  });

  factory ModelLibrary.fixed({
    required List<ModelEntry> entries,
    required ModelStore store,
  }) => ModelLibrary(() async => entries, () async => store);

  final ModelEntriesLoader _loadEntries;
  final ModelStoreLoader _loadStore;

  late final Future<List<ModelEntry>> entries = _loadEntries();
  late final Future<ModelStore> store = _loadStore();
  late final Future<ModelLibraryData> data = _load();
  ModelLibraryData? currentData;

  Future<ModelLibraryData> _load() async {
    final storeFuture = store;
    return currentData = ModelLibraryData(
      entries: await entries,
      store: await storeFuture,
    );
  }
}

class ModelLibraryData {
  const ModelLibraryData({required this.entries, required this.store});

  final List<ModelEntry> entries;
  final ModelStore store;

  /// Re-evaluated on every access so a just-finished download appears without
  /// rebuilding the library.
  List<ModelEntry> get downloadedAsrModels => [
    for (final entry in entries)
      if (entry.type == 'asr' && store.isDownloaded(entry)) entry,
  ];

  ModelEntry? entryForPath(String? path) {
    if (path == null) return null;
    for (final entry in entries) {
      if (entry.type == 'asr' && store.pathFor(entry) == path) return entry;
    }
    return null;
  }
}
