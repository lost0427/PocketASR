/// Model catalog domain layer — the curated allowlist plus local file facts.
///
/// The allowlist is a shipped asset, not a network response: this build has no
/// downloader, so the catalog can only say which models the app *may* run and
/// whether the matching file is already on disk. It never invents a download,
/// a size, or a "downloaded" state — a missing size stays null and the UI shows
/// `—`. See `asr_engine.dart` for how a [ModelEntry] feeds [EngineModelSpec].
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// Asset path of the curated allowlist.
const String modelAllowlistAsset = 'assets/model_allowlist.json';

/// One model the app is allowed to run.
class ModelEntry {
  const ModelEntry({
    required this.id,
    required this.displayName,
    required this.fileName,
    this.family,
    this.quant,
    this.sizeBytes,
  });

  /// Parses one allowlist object, rejecting entries the store could not map to
  /// a file.
  factory ModelEntry.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('model entry needs a non-empty "id"');
    }

    final fileName = json['fileName'];
    if (fileName is! String || fileName.isEmpty) {
      throw FormatException('model "$id" needs a non-empty "fileName"');
    }

    final size = json['sizeBytes'];
    if (size != null && (size is! int || size < 0)) {
      throw FormatException('model "$id" has a non-integer "sizeBytes"');
    }

    return ModelEntry(
      id: id,
      displayName: _stringOrNull(json['displayName']) ?? id,
      fileName: fileName,
      family: _stringOrNull(json['family']),
      quant: _stringOrNull(json['quant']),
      sizeBytes: size as int?,
    );
  }

  /// Stable catalog id, e.g. `sensevoice-small`.
  final String id;

  /// Human-readable name; falls back to [id] when the allowlist omits it.
  final String displayName;

  /// File name the model is stored as inside the model directory.
  final String fileName;

  /// Served model family (`sensevoice`, `whisper`, ...), for labels/logs.
  final String? family;

  /// Quantization tag (`q8_0`, `q5`, ...), for labels/logs.
  final String? quant;

  /// Confirmed download size, or null when the catalog has none yet.
  final int? sizeBytes;
}

/// Parses the allowlist [source] into entries, throwing [FormatException] on a
/// malformed document rather than silently dropping models.
List<ModelEntry> parseModelAllowlist(String source) {
  final root = jsonDecode(source);
  if (root is! Map) {
    throw const FormatException('allowlist root must be a JSON object');
  }

  final models = root['models'];
  if (models is! List) {
    throw const FormatException('allowlist needs a "models" array');
  }

  final entries = <ModelEntry>[];
  for (final model in models) {
    if (model is! Map) {
      throw const FormatException('each model must be a JSON object');
    }
    entries.add(ModelEntry.fromJson(model.cast<String, Object?>()));
  }
  return entries;
}

/// Reads and parses the allowlist asset.
///
/// Pass [bundle] in tests; the app uses [rootBundle].
Future<List<ModelEntry>> loadModelAllowlist({
  AssetBundle? bundle,
  String asset = modelAllowlistAsset,
}) async {
  final source = await (bundle ?? rootBundle).loadString(asset);
  return parseModelAllowlist(source);
}

/// Local file facts for catalog models.
///
/// This is the seam a downloader implements later; the catalog UI only needs
/// to know what is already on disk today.
abstract interface class ModelStore {
  /// Absolute path where [entry] lives (or would live).
  String pathFor(ModelEntry entry);

  /// True when the model file is present on disk.
  bool isDownloaded(ModelEntry entry);

  /// Total bytes the downloaded subset of [entries] occupies; missing files
  /// count as zero.
  int diskUsageBytes(Iterable<ModelEntry> entries);

  /// Deletes the model file. Missing file is a no-op, so callers need not
  /// check [isDownloaded] first.
  Future<void> delete(ModelEntry entry);
}

/// [ModelStore] backed by a directory on the local filesystem.
///
/// ponytail: path is `<dir>/<fileName>` with no escaping, fine while allowlist
/// file names are flat (enforced by review). Revisit if nested files land.
class LocalModelStore implements ModelStore {
  LocalModelStore(this.directory);

  /// Directory holding downloaded model files.
  final Directory directory;

  @override
  String pathFor(ModelEntry entry) =>
      '${directory.path}${Platform.pathSeparator}${entry.fileName}';

  @override
  bool isDownloaded(ModelEntry entry) => File(pathFor(entry)).existsSync();

  @override
  int diskUsageBytes(Iterable<ModelEntry> entries) {
    var total = 0;
    for (final entry in entries) {
      final file = File(pathFor(entry));
      if (file.existsSync()) total += file.lengthSync();
    }
    return total;
  }

  @override
  Future<void> delete(ModelEntry entry) async {
    final file = File(pathFor(entry));
    if (file.existsSync()) await file.delete();
  }
}

String? _stringOrNull(Object? value) => value is String ? value : null;
