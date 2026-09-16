import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'model_catalog.dart';

class ModelDownloadProgress {
  const ModelDownloadProgress(this.receivedBytes, this.totalBytes);
  final int receivedBytes;
  final int? totalBytes;
  double? get ratio => totalBytes == null || totalBytes! <= 0
      ? null
      : receivedBytes / totalBytes!;
}

/// Fetches a [ModelEntry] bundle into a [LocalModelStore].
///
/// Per file: resume with a Range request, restart cleanly when the server
/// ignores Range (a 200 whose body starts at byte 0) or lies about
/// Content-Range, then verify sha256 by streaming the partial file — a
/// 240 MB model never sits in memory. The file is renamed into place only
/// after verification, and the bundle counts as complete (ready) only when
/// every file landed, which is what `LocalModelStore.isDownloaded` reports.
/// Cancellation keeps `.part` files so a retry resumes where it stopped.
/// All paths go through the store, which rejects names that could escape the
/// bundle directory.
class ModelDownloader {
  ModelDownloader(this.store);
  final LocalModelStore store;

  Future<void> download(
    ModelEntry entry, {
    void Function(ModelDownloadProgress progress)? onProgress,
    Future<void>? cancel,
  }) async {
    final files = entry.bundleFiles;
    // Bundle total for progress: only from verified per-file sizes, never
    // from the legacy display estimate.
    final sized = files.every((f) => f.sizeBytes != null);
    final total = sized
        ? files.fold<int>(0, (sum, f) => sum + f.sizeBytes!)
        : null;

    await store.directory.create(recursive: true);
    final client = HttpClient();
    var cancelled = false;
    cancel?.then((_) => cancelled = true);
    var done = 0;
    try {
      for (final file in files) {
        if (cancelled) throw const HttpException('Download cancelled');
        if (store.isFileReady(entry, file)) {
          done += File(store.pathToFile(entry, file)).lengthSync();
          onProgress?.call(ModelDownloadProgress(done, total));
          continue;
        }
        done += await _fetchFile(
          entry,
          file,
          client,
          isCancelled: () => cancelled,
          onBytes: (received) =>
              onProgress?.call(ModelDownloadProgress(done + received, total)),
        );
        onProgress?.call(ModelDownloadProgress(done, total));
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads one bundle file and returns its final size on disk.
  Future<int> _fetchFile(
    ModelEntry entry,
    ModelFile file,
    HttpClient client, {
    required bool Function() isCancelled,
    required void Function(int received) onBytes,
  }) async {
    final url = file.url;
    if (url == null || url.isEmpty) {
      throw StateError('model file "${file.fileName}" has no download URL');
    }
    final destination = File(store.pathToFile(entry, file));
    final partial = File('${destination.path}.part');
    await destination.parent.create(recursive: true);

    // `start` is the byte offset the `.part` file holds so far; the loop
    // re-runs from scratch whenever the resume premise turns out false.
    var start = partial.existsSync() ? await partial.length() : 0;
    while (true) {
      if (isCancelled()) throw const HttpException('Download cancelled');
      final request = await client.getUrl(Uri.parse(url));
      if (start > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
      }
      final response = await request.close();

      if (start > 0 && response.statusCode == HttpStatus.ok) {
        // Range ignored: the body is byte 0 onward, so the stale prefix must
        // go before writing — a full restart, not an append.
        await response.drain<void>();
        await partial.delete();
        start = 0;
        continue;
      }
      if (response.statusCode == HttpStatus.partialContent) {
        final served = _rangeStart(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
        if (served != start) {
          // Missing or wrong Content-Range: the body is not the bytes we
          // asked to continue from. Discard and refetch whole.
          await response.drain<void>();
          await partial.delete();
          start = 0;
          continue;
        }
      } else if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Model download failed: HTTP ${response.statusCode}',
        );
      }

      var written = start;
      final sink = partial.openWrite(
        mode: start > 0 ? FileMode.append : FileMode.write,
      );
      try {
        await for (final chunk in response) {
          if (isCancelled()) throw const HttpException('Download cancelled');
          sink.add(chunk);
          written += chunk.length;
          onBytes(written);
        }
      } finally {
        await sink.close();
      }
      break;
    }

    if (file.sha256 != null) {
      // Streaming hash of the complete `.part` (covers resumed prefix too).
      final digest = (await sha256.bind(partial.openRead()).first).toString();
      if (digest.toLowerCase() != file.sha256!.toLowerCase()) {
        await partial.delete();
        throw StateError('Model checksum mismatch for "${file.fileName}"');
      }
    }
    if (destination.existsSync()) await destination.delete();
    await partial.rename(destination.path);
    return await destination.length();
  }

  /// First byte of a `bytes 100-199/200` Content-Range header, or null when
  /// absent/unparsable — a resume is only trusted when the offset matches.
  static int? _rangeStart(String? contentRange) {
    final match = RegExp(r'^bytes (\d+)-').firstMatch(contentRange ?? '');
    return match == null ? null : int.parse(match.group(1)!);
  }
}
