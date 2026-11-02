import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../data/db.dart';
import '../../features/models/model_library.dart';
import 'backup_manifest.dart';

/// One file copied into the backup zip.
class BackupEntry {
  const BackupEntry({required this.archiveName, required this.path});

  final String archiveName;
  final String path;
}

typedef SaveArchive = Future<bool> Function(
  String suggestedName,
  List<BackupEntry> entries,
  int totalBytes,
);
typedef PickArchive = Future<String?> Function(String stagingDirectory);

const _backupChannel = MethodChannel('pocket_asr/backup');
const _progressChannel = EventChannel('pocket_asr/backup_progress');

Future<bool> _defaultSaveArchive(
  String suggestedName,
  List<BackupEntry> entries,
  int totalBytes,
) async {
  final saved = await _backupChannel.invokeMethod<bool>('exportZip', {
    'suggestedName': suggestedName,
    'totalBytes': totalBytes,
    'entries': [
      for (final entry in entries)
        {'name': entry.archiveName, 'path': entry.path},
    ],
  });
  return saved == true;
}

Future<String?> _defaultPickArchive(String stagingDirectory) => _backupChannel
    .invokeMethod<String>('importZip', {'stagingDirectory': stagingDirectory});

Stream<BackupProgress> _progress() => _progressChannel
    .receiveBroadcastStream()
    .map((event) => BackupProgress.fromMap(event));

class BackupProgress {
  const BackupProgress({
    required this.phase,
    required this.done,
    required this.total,
  });

  final String phase;
  final int done;
  final int total;

  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);

  factory BackupProgress.fromMap(Object? value) {
    if (value is! Map) {
      return const BackupProgress(phase: '', done: 0, total: 0);
    }
    return BackupProgress(
      phase: value['phase'] as String? ?? '',
      done: (value['done'] as num?)?.toInt() ?? 0,
      total: (value['total'] as num?)?.toInt() ?? 0,
    );
  }
}

class BackupFileSource {
  const BackupFileSource({required this.file, required this.path});

  final BackupFile file;
  final String path;
}

class BackupBundle {
  const BackupBundle({required this.id, required this.files});

  final String id;
  final List<BackupFileSource> files;
}

class BackupPlan {
  const BackupPlan({
    required this.bundles,
    required this.modelBytes,
    required this.databaseBytes,
  });

  final List<BackupBundle> bundles;
  final int modelBytes;
  final int databaseBytes;

  int get totalBytes => modelBytes + databaseBytes;
  int get modelCount => bundles.length;
}

class BackupPreview {
  const BackupPreview({required this.manifest, required this.modelBytes});

  final BackupManifest manifest;
  final int modelBytes;

  int get modelCount => manifest.models.length;
}

enum RestoreStatus { none, applied, failed }

class BackupService {
  BackupService({
    required this.database,
    required this.documentsDirectory,
    required this.supportDirectory,
    required this.cacheDirectory,
    required this.library,
    required this.appVersion,
    SaveArchive? saveArchive,
    PickArchive? pickArchive,
    Stream<BackupProgress>? progress,
  }) : _saveArchive = saveArchive ?? _defaultSaveArchive,
       _pickArchive = pickArchive ?? _defaultPickArchive,
       progress = progress ?? _progress();

  final AppDatabase database;
  final String documentsDirectory;
  final String supportDirectory;
  final String cacheDirectory;
  final ModelLibrary library;
  final String appVersion;
  final SaveArchive _saveArchive;
  final PickArchive _pickArchive;
  final Stream<BackupProgress> progress;

  static Future<BackupService> create({
    required AppDatabase database,
    required ModelLibrary library,
    required String appVersion,
  }) async {
    final documents = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final cache = await getTemporaryDirectory();
    return BackupService(
      database: database,
      documentsDirectory: documents.path,
      supportDirectory: support.path,
      cacheDirectory: cache.path,
      library: library,
      appVersion: appVersion,
    );
  }

  String get databasePath =>
      '$documentsDirectory${Platform.pathSeparator}$databaseFileName';

  File get _pendingMarker => File(
    '$documentsDirectory${Platform.pathSeparator}pocket_asr.pending-restore',
  );

  File get _stagedDatabase => File(
    '$documentsDirectory${Platform.pathSeparator}$databaseFileName.restore',
  );

  Directory get _stagingDirectory =>
      Directory('$supportDirectory${Platform.pathSeparator}restore-staging');

  static File restoreErrorFile(String documentsDirectory) => File(
    '$documentsDirectory${Platform.pathSeparator}pocket_asr.restore-error.txt',
  );

  /// Every downloaded bundle plus the live database.
  Future<BackupPlan> plan() async {
    final data = await library.data;
    final bundles = <BackupBundle>[];
    var modelBytes = 0;
    for (final entry in data.entries) {
      if (!data.store.isDownloaded(entry)) continue;
      final bundleDir = File(data.store.pathFor(entry)).parent.path;
      final files = <BackupFileSource>[];
      for (final file in entry.bundleFiles) {
        final path = '$bundleDir${Platform.pathSeparator}${file.fileName}';
        final local = File(path);
        if (!local.existsSync()) continue;
        final bytes = local.lengthSync();
        final sha = (file.sha256 ?? await _sha256(local)).toLowerCase();
        files.add(
          BackupFileSource(
            file: BackupFile(name: file.fileName, bytes: bytes, sha256: sha),
            path: path,
          ),
        );
        modelBytes += bytes;
      }
      if (files.isNotEmpty) {
        bundles.add(BackupBundle(id: entry.id, files: files));
      }
    }
    final databaseBytes = File(databasePath).existsSync()
        ? File(databasePath).lengthSync()
        : 0;
    return BackupPlan(
      bundles: bundles,
      modelBytes: modelBytes,
      databaseBytes: databaseBytes,
    );
  }

  Future<bool> export(BackupPlan plan) async {
    await Directory(cacheDirectory).create(recursive: true);
    final temp = await Directory(cacheDirectory)
        .createTemp('pocketasr-backup-');
    try {
      final snapshot = File(
        '${temp.path}${Platform.pathSeparator}$databaseFileName',
      );
      if (snapshot.existsSync()) await snapshot.delete();
      database.db.execute('VACUUM INTO ?', [snapshot.path]);
      final manifest = BackupManifest(
        schemaVersion: schemaVersion,
        appVersion: appVersion,
        createdAt: DateTime.now(),
        dbBytes: snapshot.lengthSync(),
        dbSha256: await _sha256(snapshot),
        models: [
          for (final bundle in plan.bundles)
            BackupModel(
              id: bundle.id,
              files: [for (final source in bundle.files) source.file],
            ),
        ],
      );
      final manifestFile = File(
        '${temp.path}${Platform.pathSeparator}manifest.json',
      );
      await manifestFile.writeAsString(manifest.encode());
      final entries = <BackupEntry>[
        BackupEntry(archiveName: 'manifest.json', path: manifestFile.path),
        BackupEntry(archiveName: 'db/$databaseFileName', path: snapshot.path),
        for (final bundle in plan.bundles)
          for (final source in bundle.files)
            BackupEntry(
              archiveName: 'models/${bundle.id}/${source.file.name}',
              path: source.path,
            ),
      ];
      final total = entries.fold<int>(
        0,
        (sum, entry) => sum + File(entry.path).lengthSync(),
      );
      return await _saveArchive(_suggestedName(), entries, total);
    } finally {
      if (temp.existsSync()) await temp.delete(recursive: true);
    }
  }

  /// Picks an archive, validates it, and stages it for the next launch.
  /// Returns null when the user cancelled the picker.
  Future<BackupPreview?> pickAndStage() async {
    if (_stagingDirectory.existsSync()) {
      await _stagingDirectory.delete(recursive: true);
    }
    await _stagingDirectory.create(recursive: true);
    String? picked;
    try {
      picked = await _pickArchive(_stagingDirectory.path);
    } catch (_) {
      if (_stagingDirectory.existsSync()) {
        await _stagingDirectory.delete(recursive: true);
      }
      rethrow;
    }
    if (picked == null) {
      await _stagingDirectory.delete(recursive: true);
      return null;
    }
    final staging = Directory(picked);
    try {
      final preview = await _validateStaging(staging);
      await _stagedDatabase.parent.create(recursive: true);
      final source = File(
        '${staging.path}${Platform.pathSeparator}db${Platform.pathSeparator}$databaseFileName',
      );
      await source.copy(_stagedDatabase.path);
      await _pendingMarker.writeAsString(
        jsonEncode({
          'staging': staging.path,
          'models': preview.modelCount,
          'db': _stagedDatabase.path,
        }),
      );
      return BackupPreview(
        manifest: preview.manifest,
        modelBytes: preview.modelBytes,
      );
    } catch (_) {
      if (staging.existsSync()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<BackupPreview> _validateStaging(Directory staging) async {
    final manifestFile = File(
      '${staging.path}${Platform.pathSeparator}manifest.json',
    );
    if (!manifestFile.existsSync()) {
      throw const FormatException('Backup manifest is missing');
    }
    final manifest = BackupManifest.fromJson(
      jsonDecode(await manifestFile.readAsString()),
    );
    final data = await library.data;
    final byId = {for (final entry in data.entries) entry.id: entry};
    var modelBytes = 0;
    for (final model in manifest.models) {
      final entry = byId[model.id];
      if (entry == null) {
        throw FormatException('Unknown model in backup: ${model.id}');
      }
      final catalog = {
        for (final file in entry.bundleFiles) file.fileName: file,
      };
      for (final file in model.files) {
        final known = catalog[file.name];
        if (known == null ||
            known.sizeBytes != file.bytes ||
            known.sha256?.toLowerCase() != file.sha256) {
          throw FormatException(
            'Model file does not match the catalog: ${file.name}',
          );
        }
        final staged = File(
          '${staging.path}${Platform.pathSeparator}models'
          '${Platform.pathSeparator}${model.id}'
          '${Platform.pathSeparator}${file.name}',
        );
        if (!staged.existsSync() || staged.lengthSync() != file.bytes) {
          throw FormatException(
            'Model file is missing or truncated: ${file.name}',
          );
        }
        modelBytes += file.bytes;
      }
    }
    final db = File(
      '${staging.path}${Platform.pathSeparator}db${Platform.pathSeparator}$databaseFileName',
    );
    if (!db.existsSync() || db.lengthSync() != manifest.dbBytes) {
      throw const FormatException('Backup database is missing or truncated');
    }
    if (await _sha256(db) != manifest.dbSha256) {
      throw const FormatException('Backup database checksum does not match');
    }
    _validateDatabase(db);
    return BackupPreview(manifest: manifest, modelBytes: modelBytes);
  }

  static void _validateDatabase(File file) {
    if (!file.existsSync()) {
      throw const FormatException('Backup database is missing');
    }
    final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      final check = db.select('PRAGMA integrity_check');
      if (check.isEmpty || check.first.values.first != 'ok') {
        throw const FormatException('Backup database is corrupt');
      }
      final version =
          db.select('PRAGMA user_version').first.values.first as int;
      if (version > schemaVersion) {
        throw const FormatException('Backup database is newer than this app');
      }
      final tables = {
        for (final row in db.select(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        ))
          row['name'] as String,
      };
      for (final table in const [
        'transcript',
        'segment',
        'embedding',
        'settings',
      ]) {
        if (!tables.contains(table)) {
          throw const FormatException('Backup database is incomplete');
        }
      }
    } finally {
      db.close();
    }
  }

  /// Applies a staged backup before the app opens its database.
  static Future<RestoreStatus> applyPendingRestore({
    required String documentsDirectory,
    required String supportDirectory,
  }) async {
    final marker = File(
      '$documentsDirectory${Platform.pathSeparator}pocket_asr.pending-restore',
    );
    if (!marker.existsSync()) return RestoreStatus.none;
    final staged = File(
      '$documentsDirectory${Platform.pathSeparator}$databaseFileName.restore',
    );
    final database = File(
      '$documentsDirectory${Platform.pathSeparator}$databaseFileName',
    );
    final old = File('${database.path}.old');
    final staging = Directory(
      '$supportDirectory${Platform.pathSeparator}restore-staging',
    );
    try {
      _validateDatabase(staged);
      if (old.existsSync()) old.deleteSync();
      if (database.existsSync()) database.renameSync(old.path);
      for (final suffix in const ['-wal', '-shm']) {
        final side = File('${database.path}$suffix');
        if (side.existsSync()) side.deleteSync();
      }
      staged.renameSync(database.path);
      final models = Directory(
        '${staging.path}${Platform.pathSeparator}models',
      );
      if (models.existsSync()) {
        final targetRoot = Directory(
          '$supportDirectory${Platform.pathSeparator}models',
        )..createSync(recursive: true);
        for (final bundle in models.listSync().whereType<Directory>()) {
          final id = bundle.path.split(Platform.pathSeparator).last;
          final target = Directory(
            '${targetRoot.path}${Platform.pathSeparator}$id',
          );
          if (target.existsSync()) target.deleteSync(recursive: true);
          bundle.renameSync(target.path);
        }
      }
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      if (old.existsSync()) old.deleteSync();
      marker.deleteSync();
      return RestoreStatus.applied;
    } catch (error) {
      if (old.existsSync()) {
        if (database.existsSync()) database.deleteSync();
        old.renameSync(database.path);
      }
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      restoreErrorFile(documentsDirectory).writeAsStringSync('$error');
      marker.deleteSync();
      return RestoreStatus.failed;
    }
  }

  /// Returns the last restore error once, so the settings page can surface it.
  static String? takeRestoreError(String documentsDirectory) {
    final file = restoreErrorFile(documentsDirectory);
    if (!file.existsSync()) return null;
    final message = file.readAsStringSync();
    file.deleteSync();
    return message.isEmpty ? null : message;
  }

  static Future<String> _sha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  static String _suggestedName() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'pocketasr-backup-${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}.zip';
  }
}
