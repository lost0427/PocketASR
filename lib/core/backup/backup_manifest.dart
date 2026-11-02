import 'dart:convert';

import '../../data/db.dart' as db_schema;

/// Backup container metadata written to `manifest.json`.
class BackupManifest {
  const BackupManifest({
    required this.schemaVersion,
    required this.appVersion,
    required this.createdAt,
    required this.dbBytes,
    required this.dbSha256,
    required this.models,
  });

  static const format = 'pocketasr-backup';
  static const formatVersion = 1;

  final int schemaVersion;
  final String appVersion;
  final DateTime createdAt;
  final int dbBytes;
  final String dbSha256;
  final List<BackupModel> models;

  Map<String, Object?> toJson() => {
    'format': format,
    'formatVersion': formatVersion,
    'schemaVersion': schemaVersion,
    'appVersion': appVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'db': {
      'path': 'db/pocket_asr.sqlite',
      'bytes': dbBytes,
      'sha256': dbSha256,
    },
    'models': [for (final model in models) model.toJson()],
  };

  factory BackupManifest.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Backup manifest is not an object');
    }
    if (value['format'] != format) {
      throw const FormatException('Not a PocketASR backup');
    }
    if (value['formatVersion'] != formatVersion) {
      throw const FormatException('Unsupported backup format');
    }
    final schema = value['schemaVersion'];
    if (schema is! int || schema < 0 || schema > db_schema.schemaVersion) {
      throw const FormatException('Backup schema is newer than this app');
    }
    final db = value['db'];
    if (db is! Map) {
      throw const FormatException('Backup database entry is missing');
    }
    final dbBytes = db['bytes'];
    final dbSha256 = db['sha256'];
    if (dbBytes is! int || dbBytes <= 0) {
      throw const FormatException('Backup database size is invalid');
    }
    if (dbSha256 is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(dbSha256)) {
      throw const FormatException('Backup database checksum is invalid');
    }
    final models = value['models'];
    if (models != null && models is! List) {
      throw const FormatException('Backup model list is invalid');
    }
    return BackupManifest(
      schemaVersion: schema,
      appVersion: value['appVersion'] is String
          ? value['appVersion'] as String
          : '',
      createdAt:
          DateTime.tryParse(value['createdAt'] as String? ?? '') ??
          DateTime.now(),
      dbBytes: dbBytes,
      dbSha256: dbSha256.toLowerCase(),
      models: [
        for (final model in (models as List? ?? const []))
          BackupModel.fromJson(model),
      ],
    );
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

class BackupModel {
  const BackupModel({required this.id, required this.files});

  final String id;
  final List<BackupFile> files;

  Map<String, Object?> toJson() => {
    'id': id,
    'files': [for (final file in files) file.toJson()],
  };

  factory BackupModel.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Backup model is not an object');
    }
    final id = value['id'];
    final files = value['files'];
    if (id is! String || id.isEmpty || files is! List) {
      throw const FormatException('Backup model is invalid');
    }
    return BackupModel(
      id: id,
      files: [for (final file in files) BackupFile.fromJson(file)],
    );
  }
}

class BackupFile {
  const BackupFile({
    required this.name,
    required this.bytes,
    required this.sha256,
  });

  final String name;
  final int bytes;
  final String sha256;

  Map<String, Object?> toJson() => {
    'name': name,
    'bytes': bytes,
    'sha256': sha256,
  };

  factory BackupFile.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Backup file is not an object');
    }
    final name = value['name'];
    final bytes = value['bytes'];
    final sha256 = value['sha256'];
    if (name is! String ||
        name.isEmpty ||
        name.contains('/') ||
        name.contains('\\')) {
      throw const FormatException('Backup file name is invalid');
    }
    if (bytes is! int || bytes < 0) {
      throw const FormatException('Backup file size is invalid');
    }
    if (sha256 is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const FormatException('Backup file checksum is invalid');
    }
    return BackupFile(name: name, bytes: bytes, sha256: sha256.toLowerCase());
  }
}
