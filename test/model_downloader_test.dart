import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/engine/model_catalog.dart';
import 'package:pocket_asr/engine/model_downloader.dart';

/// Local HTTP tests for the bundle downloader: resume/Range handling,
/// verification, cancellation, and traversal protection — all against a
/// loopback server, never the network or a real model.
void main() {
  late Directory dir;
  late LocalModelStore store;
  late HttpServer server;

  // Server behaviour knobs, reset per test.
  final served = <String, Uint8List>{};
  var supportRange = true;
  var lieAboutContentRange = false;
  String? seenRangeHeader;

  String url(String name) => 'http://127.0.0.1:${server.port}/$name';

  ModelFile fileOf(String name, List<int> bytes, {String role = 'model'}) =>
      ModelFile(
        fileName: name,
        role: role,
        url: url(name),
        sizeBytes: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      );

  ModelEntry entryOf(String id, List<ModelFile> files) => ModelEntry(
    id: id,
    displayName: id,
    fileName: 'unused',
    family: 'sensevoice',
    files: files,
  );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('pocket_asr_dl');
    store = LocalModelStore(dir);
    served.clear();
    supportRange = true;
    lieAboutContentRange = false;
    seenRangeHeader = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final name = request.uri.pathSegments.last;
      final bytes = served[name];
      if (bytes == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      seenRangeHeader = range;
      if (range != null && supportRange) {
        final start = int.parse(range.substring('bytes='.length).split('-').first);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          lieAboutContentRange
              ? 'bytes ${start + 7}-${bytes.length - 1}/${bytes.length}'
              : 'bytes $start-${bytes.length - 1}/${bytes.length}',
        );
        request.response.add(Uint8List.sublistView(bytes, start));
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.add(bytes);
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  test('downloads every bundle file and marks the bundle ready', () async {
    final model = [1, 2, 3, 4, 5, 6, 7, 8];
    final tokens = [10, 20, 30];
    final entry = entryOf('b1', [
      fileOf('m.onnx', model),
      fileOf('tokens.txt', tokens, role: 'tokens'),
    ]);
    served['m.onnx'] = Uint8List.fromList(model);
    served['tokens.txt'] = Uint8List.fromList(tokens);

    final progress = <ModelDownloadProgress>[];
    await ModelDownloader(store).download(
      entry,
      onProgress: progress.add,
    );

    expect(store.isDownloaded(entry), isTrue);
    expect(
      File(store.pathToFile(entry, entry.files.first)).readAsBytesSync(),
      model,
    );
    expect(
      File(store.pathToFile(entry, entry.files.last)).readAsBytesSync(),
      tokens,
    );
    // Aggregate progress ends at the verified bundle total.
    expect(progress.last.receivedBytes, model.length + tokens.length);
    expect(progress.last.totalBytes, model.length + tokens.length);
    // No `.part` debris after a successful rename.
    expect(
      File('${store.pathToFile(entry, entry.files.first)}.part').existsSync(),
      isFalse,
    );
  });

  test('resumes from a .part using Range and completes the file', () async {
    final model = List.generate(64, (i) => i);
    final entry = entryOf('b2', [fileOf('m.onnx', model)]);
    served['m.onnx'] = Uint8List.fromList(model);

    // Simulate an interrupted run: first 10 bytes already on disk.
    final path = store.pathToFile(entry, entry.files.first);
    File(path).parent.createSync(recursive: true);
    File('$path.part').writeAsBytesSync(model.sublist(0, 10));

    await ModelDownloader(store).download(entry);

    expect(seenRangeHeader, 'bytes=10-');
    expect(File(path).readAsBytesSync(), model);
    expect(store.isDownloaded(entry), isTrue);
  });

  test('a Range-ignoring 200 restarts the file instead of corrupting it',
      () async {
    final model = List.generate(40, (i) => i);
    final entry = entryOf('b3', [fileOf('m.onnx', model)]);
    served['m.onnx'] = Uint8List.fromList(model);
    supportRange = false; // server answers every request with a full 200

    final path = store.pathToFile(entry, entry.files.first);
    File(path).parent.createSync(recursive: true);
    File('$path.part').writeAsBytesSync([999 % 256, 999 % 256]); // stale junk

    await ModelDownloader(store).download(entry);

    // The stale prefix was discarded: bytes are exactly the served content.
    expect(File(path).readAsBytesSync(), model);
  });

  test('a lying Content-Range offset restarts the file', () async {
    final model = List.generate(40, (i) => i);
    final entry = entryOf('b4', [fileOf('m.onnx', model)]);
    served['m.onnx'] = Uint8List.fromList(model);
    lieAboutContentRange = true; // 206 claims a different start than asked

    final path = store.pathToFile(entry, entry.files.first);
    File(path).parent.createSync(recursive: true);
    File('$path.part').writeAsBytesSync(model.sublist(0, 8));

    await ModelDownloader(store).download(entry);

    expect(File(path).readAsBytesSync(), model);
  });

  test('checksum mismatch deletes the partial and throws', () async {
    final served10 = List.generate(10, (i) => i);
    final entry = ModelEntry(
      id: 'b5',
      displayName: 'b5',
      fileName: 'unused',
      files: [
        ModelFile(
          fileName: 'm.onnx',
          role: 'model',
          url: url('m.onnx'),
          sizeBytes: served10.length,
          sha256: sha256.convert([42]).toString(), // the file is not [42]
        ),
      ],
    );
    served['m.onnx'] = Uint8List.fromList(served10);

    await expectLater(
      ModelDownloader(store).download(entry),
      throwsA(isA<StateError>()),
    );
    expect(store.isDownloaded(entry), isFalse);
    expect(File('${store.pathToFile(entry, entry.files.first)}.part')
        .existsSync(), isFalse);
  });

  test('cancelling keeps the .part so a retry can resume', () async {
    // 1 MB body: the client consumes it as ~16 stream events, so a cancel
    // raised at the first event is seen before the last bytes are written.
    final model = List.generate(1048576, (i) => i % 251);
    final entry = entryOf('b6', [fileOf('m.onnx', model)]);
    served['m.onnx'] = Uint8List.fromList(model);

    final cancel = Completer<void>();
    final downloader = ModelDownloader(store);
    await expectLater(
      downloader.download(
        entry,
        onProgress: (p) {
          if (!cancel.isCompleted) cancel.complete(); // stop at first chunk
        },
        cancel: cancel.future,
      ),
      throwsA(isA<HttpException>()),
    );

    final path = store.pathToFile(entry, entry.files.first);
    final partial = File('$path.part');
    expect(partial.existsSync(), isTrue); // resumable debris, kept
    expect(File(path).existsSync(), isFalse);
    expect(partial.lengthSync(), lessThan(model.length));

    // Retry finishes from the kept prefix.
    await downloader.download(entry);
    expect(File(path).readAsBytesSync(), model);
  });

  test('one failing file leaves the bundle not ready', () async {
    final entry = entryOf('b7', [
      fileOf('m.onnx', [1, 2, 3]),
      fileOf('tokens.txt', [4, 5], role: 'tokens'),
    ]);
    served['m.onnx'] = Uint8List.fromList([1, 2, 3]); // tokens.txt 404s

    await expectLater(
      ModelDownloader(store).download(entry),
      throwsA(isA<HttpException>()),
    );
    expect(store.isDownloaded(entry), isFalse);
    expect(File(store.pathToFile(entry, entry.files.first)).existsSync(), isTrue);
  });

  test('file names that escape the bundle dir are refused', () async {
    final entry = entryOf('b8', [
      ModelFile(fileName: '../evil.onnx', role: 'model', url: url('m.onnx')),
    ]);
    served['m.onnx'] = Uint8List.fromList([1]);

    await expectLater(
      ModelDownloader(store).download(entry),
      throwsA(isA<StateError>()),
    );
    expect(File('${dir.parent.path}${Platform.pathSeparator}evil.onnx')
        .existsSync(), isFalse);
  });
}
