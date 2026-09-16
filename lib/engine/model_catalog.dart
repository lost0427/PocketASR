/// Model catalog domain layer — the curated allowlist plus local file facts.
///
/// The allowlist is a shipped asset, not a network response. Each entry is a
/// *bundle*: one primary model file plus companions (`tokens.txt`, a whisper
/// encoder/decoder). [LocalModelStore] keeps each bundle in its own directory
/// so two bundles shipping the same file name cannot collide, and reports a
/// bundle ready only when every file exists with its verified size.
/// [ModelStore.specFor] maps an entry to the [EngineModelSpec] the engine
/// layer loads; [ModelDownloader] fetches the bundle file by file.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'asr_engine.dart';

/// Asset path of the curated allowlist.
const String modelAllowlistAsset = 'assets/model_allowlist.json';

/// One file inside a [ModelEntry] bundle.
class ModelFile {
  const ModelFile({
    required this.fileName,
    this.role,
    this.url,
    this.sizeBytes,
    this.sha256,
  });

  factory ModelFile.fromJson(Map<String, Object?> json, String modelId) {
    final fileName = _stringOrNull(json['fileName']);
    if (fileName == null || fileName.isEmpty) {
      throw FormatException('model "$modelId" has a file without "fileName"');
    }
    _checkPlainName(modelId, fileName);
    return ModelFile(
      fileName: fileName,
      role: _stringOrNull(json['role']),
      url: _stringOrNull(json['url']),
      sizeBytes: _sizeOrNull(json['sizeBytes'], modelId, fileName),
      sha256: _stringOrNull(json['sha256']),
    );
  }

  /// Name on disk inside the bundle directory; a plain file name only
  /// (enforced by [_checkPlainName]) so it cannot escape the bundle dir.
  final String fileName;

  /// Engine-relevant role: `model` (primary), `tokens`, `encoder`, `decoder`.
  /// A null or `model` role marks the primary file.
  final String? role;

  final String? url;

  /// Verified download size, or null when unverified. Store readiness
  /// compares actual length against this; a null size degrades to "exists".
  final int? sizeBytes;
  final String? sha256;

  bool get isPrimary => role == null || role == 'model';
}

/// One model bundle the app is allowed to run.
class ModelEntry {
  const ModelEntry({
    required this.id,
    required this.displayName,
    required this.fileName,
    this.files = const [],
    this.family,
    this.quant,
    this.engine,
    this.type = 'asr',
    this.license,
    this.languages = const [],
    this.sizeBytes,
    this.url,
    this.sha256,
  });

  /// Parses one allowlist object, rejecting entries the store could not map
  /// to files (unsafe names, malformed sizes) instead of dropping them.
  factory ModelEntry.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('model entry needs a non-empty "id"');
    }
    _checkPlainName(id, id); // the id doubles as the bundle directory name

    final rawFiles = json['files'];
    final files = <ModelFile>[];
    if (rawFiles != null) {
      if (rawFiles is! List) {
        throw FormatException('model "$id" has a non-list "files"');
      }
      for (final file in rawFiles) {
        if (file is! Map) {
          throw FormatException('model "$id" has a non-object file entry');
        }
        files.add(
          ModelFile.fromJson(file.cast<String, Object?>(), id),
        );
      }
    }
    final primary = files.isEmpty
        ? null
        : files.firstWhere((f) => f.isPrimary, orElse: () => files.first);

    final fileName = _stringOrNull(json['fileName']) ?? primary?.fileName;
    if (fileName == null || fileName.isEmpty) {
      throw FormatException('model "$id" needs a "fileName" or a "files" entry');
    }
    if (primary == null) _checkPlainName(id, fileName);

    final rawLanguages = json['languages'];
    final languages = <String>[];
    if (rawLanguages != null) {
      if (rawLanguages is! List ||
          rawLanguages.any((l) => l is! String || l.isEmpty)) {
        throw FormatException('model "$id" has a malformed "languages" list');
      }
      languages.addAll(rawLanguages.cast<String>());
    }

    // Bundle total: only when every file size is verified; the top-level
    // "sizeBytes" on legacy flat entries stays a display estimate.
    final total = files.isNotEmpty && files.every((f) => f.sizeBytes != null)
        ? files.fold<int>(0, (sum, f) => sum + f.sizeBytes!)
        : null;

    return ModelEntry(
      id: id,
      displayName: _stringOrNull(json['displayName']) ?? id,
      fileName: fileName,
      files: files,
      family: _stringOrNull(json['family']),
      quant: _stringOrNull(json['quant']),
      engine: _stringOrNull(json['engine']),
      type: _stringOrNull(json['type']) ?? 'asr',
      license: _stringOrNull(json['license']),
      languages: languages,
      sizeBytes: total ?? _sizeOrNull(json['sizeBytes'], id, fileName),
      url: _stringOrNull(json['url']) ?? primary?.url,
      sha256: _stringOrNull(json['sha256']) ?? primary?.sha256,
    );
  }

  /// Stable catalog id, e.g. `sherpa-sensevoice-int8`. Also the bundle
  /// directory name inside the store, so it must be a plain name.
  final String id;

  /// Human-readable name; falls back to [id] when the allowlist omits it.
  final String displayName;

  /// File name of the primary model file inside the bundle directory.
  final String fileName;

  /// Every file in the bundle, primary included. Empty on legacy flat
  /// entries, which [bundleFiles] then synthesizes from the single-file
  /// fields below.
  final List<ModelFile> files;

  /// Served model family (`sensevoice`, `whisper`, ...), for labels/logs.
  final String? family;

  /// Quantization tag (`q8_0`, `q4_k`, ...), for labels/logs.
  final String? quant;

  /// Engine that runs this bundle (`sherpa`, `crispasr`, `crispembed`).
  final String? engine;

  /// What the model produces: `asr` or `embedding`.
  final String type;

  /// Upstream license note, verbatim from the allowlist; null means the
  /// catalog never confirmed one.
  final String? license;

  /// Language tags the model claims; empty when unverified.
  final List<String> languages;

  /// Confirmed bundle size (sum of verified file sizes), or the legacy
  /// declared size; null when the catalog has neither.
  final int? sizeBytes;

  /// Primary file URL and checksum; conveniences over [files] for the
  /// single-file case and for existing callers.
  final String? url;
  final String? sha256;

  /// The files that must all be on disk for this entry to count as ready:
  /// the declared bundle, or a single file synthesized from the flat fields
  /// (whose entry-level size stays a display estimate, not a verified one).
  List<ModelFile> get bundleFiles => files.isNotEmpty
      ? files
      : [ModelFile(fileName: fileName, url: url, sha256: sha256)];

  ModelFile get primaryFile => bundleFiles.firstWhere(
    (f) => f.isPrimary,
    orElse: () => bundleFiles.first,
  );
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
abstract interface class ModelStore {
  /// Absolute path of [entry]'s primary model file inside its bundle dir.
  String pathFor(ModelEntry entry);

  /// True when every file of [entry]'s bundle is present with a correct size.
  bool isDownloaded(ModelEntry entry);

  /// Total bytes the downloaded files of [entries] occupy; missing files
  /// count as zero.
  int diskUsageBytes(Iterable<ModelEntry> entries);

  /// Deletes the whole bundle. Missing files are a no-op, so callers need
  /// not check [isDownloaded] first.
  Future<void> delete(ModelEntry entry);

  /// Resolves [entry] into the spec its engine loads: primary file as
  /// `path`, companion roles as `tokensPath`/`encoderPath`/`decoderPath`.
  EngineModelSpec specFor(ModelEntry entry);
}

/// [ModelStore] backed by a directory tree on the local filesystem.
///
/// Layout is `<dir>/<entry.id>/<file.fileName>`: one directory per bundle so
/// e.g. sensevoice and whisper can each ship a tokens file without fighting
/// over one flat name.
class LocalModelStore implements ModelStore {
  LocalModelStore(this.directory);

  /// Root directory holding the per-bundle model folders.
  final Directory directory;

  /// Directory isolating one bundle's files from every other bundle's.
  String bundleDirFor(ModelEntry entry) =>
      '${directory.path}${Platform.pathSeparator}${entry.id}';

  /// Absolute path of one bundle file. The plain-name guard lives here too
  /// (not only in [ModelEntry.fromJson]) because const-constructed entries
  /// in tests and future callers bypass the parser.
  String pathToFile(ModelEntry entry, ModelFile file) {
    if (file.fileName.contains('/') ||
        file.fileName.contains('\\') ||
        file.fileName.contains('..')) {
      throw StateError(
        'refusing unsafe model file name "${file.fileName}"',
      );
    }
    return '${bundleDirFor(entry)}${Platform.pathSeparator}${file.fileName}';
  }

  @override
  String pathFor(ModelEntry entry) => pathToFile(entry, entry.primaryFile);

  @override
  bool isDownloaded(ModelEntry entry) {
    for (final file in entry.bundleFiles) {
      if (!isFileReady(entry, file)) return false;
    }
    return true;
  }

  /// True when one bundle file exists with its verified size (or exists at
  /// all when the catalog never confirmed a size for it).
  ///
  /// ponytail: readiness checks size, not content; the downloader pins
  /// sha256 at fetch time. Re-hash lazily if on-disk drift ever matters.
  bool isFileReady(ModelEntry entry, ModelFile file) {
    final f = File(pathToFile(entry, file));
    if (!f.existsSync()) return false;
    return file.sizeBytes == null || f.lengthSync() == file.sizeBytes;
  }

  @override
  int diskUsageBytes(Iterable<ModelEntry> entries) {
    var total = 0;
    for (final entry in entries) {
      for (final file in entry.bundleFiles) {
        final f = File(pathToFile(entry, file));
        if (f.existsSync()) total += f.lengthSync();
      }
    }
    return total;
  }

  @override
  Future<void> delete(ModelEntry entry) async {
    // Whole bundle at once: completed files plus in-flight `.part` debris.
    final dir = Directory(bundleDirFor(entry));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  @override
  EngineModelSpec specFor(ModelEntry entry) {
    String? pathForRole(String role) {
      for (final file in entry.bundleFiles) {
        if (file.role == role) return pathToFile(entry, file);
      }
      return null;
    }

    return EngineModelSpec(
      path: pathFor(entry),
      family: entry.family,
      quant: entry.quant,
      tokensPath: pathForRole('tokens'),
      encoderPath: pathForRole('encoder'),
      decoderPath: pathForRole('decoder'),
    );
  }
}

/// Rejects names that could escape a bundle directory once joined to a path.
void _checkPlainName(String modelId, String name) {
  if (name.contains('/') || name.contains('\\') || name.contains('..')) {
    throw FormatException(
      'model "$modelId" uses "$name", which is not a plain file name',
    );
  }
}

int? _sizeOrNull(Object? value, String id, String name) {
  if (value == null) return null;
  if (value is! int || value < 0) {
    throw FormatException('model "$id" file "$name" has a bad "sizeBytes"');
  }
  return value;
}

String? _stringOrNull(Object? value) => value is String ? value : null;
