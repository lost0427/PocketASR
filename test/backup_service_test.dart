import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/backup/backup_manifest.dart';
import 'package:pocket_asr/core/backup/backup_service.dart';
import 'package:pocket_asr/data/db.dart';
import 'package:pocket_asr/data/transcript_repo.dart';
import 'package:pocket_asr/engine/model_catalog.dart';
import 'package:pocket_asr/features/models/model_library.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory root;
  late Directory documents;
  late Directory support;
  late Directory cache;
  late Directory modelsDir;
  late Directory savedDir;
  late AppDatabase database;
  late ModelEntry entry;
  late List<int> modelBytes;

  ModelEntry buildEntry(List<int> bytes) {
    return ModelEntry(
      id: 'fake-model',
      displayName: 'Fake',
      fileName: 'model.bin',
      files: [
        ModelFile(
          fileName: 'model.bin',
          role: 'model',
          sizeBytes: bytes.length,
          sha256: sha256.convert(bytes).toString(),
        ),
      ],
    );
  }

  BackupService buildService({Future<String?> Function(String)? pickArchive}) {
    final library = ModelLibrary.fixed(
      entries: [entry],
      store: LocalModelStore(modelsDir),
    );
    return BackupService(
      database: database,
      documentsDirectory: documents.path,
      supportDirectory: support.path,
      cacheDirectory: cache.path,
      library: library,
      appVersion: '1.0.27',
      saveArchive: (name, entries, total) async {
        for (final item in entries) {
          final target = File(
            '${savedDir.path}${Platform.pathSeparator}${item.archiveName}',
          );
          target.parent.createSync(recursive: true);
          File(item.path).copySync(target.path);
        }
        return true;
      },
      pickArchive: pickArchive,
      progress: const Stream.empty(),
    );
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('pocketasr_backup');
    documents = Directory('${root.path}/documents')..createSync();
    support = Directory('${root.path}/support')..createSync();
    cache = Directory('${root.path}/cache')..createSync();
    modelsDir = Directory('${support.path}/models')..createSync();
    savedDir = Directory('${root.path}/saved')..createSync();
    modelBytes = List<int>.generate(32, (index) => index);
    entry = buildEntry(modelBytes);
    final modelDir = Directory('${modelsDir.path}/fake-model')..createSync();
    File('${modelDir.path}/model.bin').writeAsBytesSync(modelBytes);
    database = AppDatabase.open(path: '${documents.path}/$databaseFileName');
    final repo = TranscriptRepo(database);
    repo.insert(title: 'Meeting', text: 'hello backup');
    database.setSetting('theme_mode', 'dark');
  });

  tearDown(() {
    database.close();
    root.deleteSync(recursive: true);
  });

  test('plan includes the database and every downloaded bundle', () async {
    final service = buildService();
    final plan = await service.plan();
    expect(plan.modelCount, 1);
    expect(plan.modelBytes, modelBytes.length);
    expect(plan.databaseBytes, greaterThan(0));
  });

  test('export writes a manifest, database snapshot and model file', () async {
    final service = buildService();
    final plan = await service.plan();
    expect(await service.export(plan), isTrue);

    final manifest = BackupManifest.fromJson(
      jsonDecode(File('${savedDir.path}/manifest.json').readAsStringSync()),
    );
    expect(manifest.models.single.id, 'fake-model');
    expect(manifest.models.single.files.single.name, 'model.bin');
    expect(manifest.dbBytes, greaterThan(0));

    final snapshot = File('${savedDir.path}/db/$databaseFileName');
    final db = sqlite3.open(snapshot.path, mode: OpenMode.readOnly);
    try {
      expect(
        db.select('SELECT title FROM transcript').first['title'],
        'Meeting',
      );
      expect(
        db
            .select("SELECT value FROM settings WHERE key = 'theme_mode'")
            .first['value'],
        'dark',
      );
    } finally {
      db.close();
    }
    expect(
      File('${savedDir.path}/models/fake-model/model.bin').readAsBytesSync(),
      modelBytes,
    );
  });

  test('stage accepts a valid backup and applies it on restart', () async {
    final service = buildService();
    expect(await service.export(await service.plan()), isTrue);

    final staging = Directory('${support.path}/picked')..createSync();
    void copyTree(Directory source, Directory target) {
      for (final entity in source.listSync(recursive: true)) {
        final relative = entity.path.substring(source.path.length + 1);
        final destination = '${target.path}${Platform.pathSeparator}$relative';
        if (entity is Directory) {
          Directory(destination).createSync(recursive: true);
        } else if (entity is File) {
          File(destination)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(entity.readAsBytesSync());
        }
      }
    }

    copyTree(savedDir, staging);
    final importing = buildService(pickArchive: (_) async => staging.path);
    final preview = await importing.pickAndStage();
    expect(preview, isNotNull);
    expect(preview!.modelCount, 1);

    database.close();
    expect(
      await BackupService.applyPendingRestore(
        documentsDirectory: documents.path,
        supportDirectory: support.path,
      ),
      RestoreStatus.applied,
    );
    database = AppDatabase.open(path: '${documents.path}/$databaseFileName');
    final repo = TranscriptRepo(database);
    expect(repo.list().single.text, 'hello backup');
    expect(
      File('${support.path}/models/fake-model/model.bin').readAsBytesSync(),
      modelBytes,
    );
  });

  test(
    'stage rejects a backup whose database checksum does not match',
    () async {
      final service = buildService();
      expect(await service.export(await service.plan()), isTrue);

      final staging = Directory('${support.path}/picked')..createSync();
      for (final entity in savedDir.listSync(recursive: true)) {
        final relative = entity.path.substring(savedDir.path.length + 1);
        final destination = '${staging.path}${Platform.pathSeparator}$relative';
        if (entity is Directory) {
          Directory(destination).createSync(recursive: true);
        } else if (entity is File) {
          File(destination)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(entity.readAsBytesSync());
        }
      }
      final dbFile = File('${staging.path}/db/$databaseFileName');
      final bytes = dbFile.readAsBytesSync();
      bytes[bytes.length - 1] ^= 0xFF;
      dbFile.writeAsBytesSync(bytes);

      final importing = buildService(pickArchive: (_) async => staging.path);
      await expectLater(importing.pickAndStage(), throwsFormatException);
    },
  );
}
