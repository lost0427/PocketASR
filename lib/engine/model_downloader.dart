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

class ModelDownloader {
  ModelDownloader(this.store);
  final LocalModelStore store;

  Future<void> download(
    ModelEntry entry, {
    void Function(ModelDownloadProgress progress)? onProgress,
    Future<void>? cancel,
  }) async {
    final url = entry.url;
    if (url == null || url.isEmpty) throw StateError('Model has no download URL');
    await store.directory.create(recursive: true);
    final destination = File(store.pathFor(entry));
    final partial = File('${destination.path}.part');
    final received = await partial.exists() ? await partial.length() : 0;
    final client = HttpClient();
    var cancelled = false;
    cancel?.then((_) => cancelled = true);
    try {
      final request = await client.getUrl(Uri.parse(url));
      if (received > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
      final response = await request.close();
      if (received > 0 && response.statusCode == HttpStatus.ok) {
        await partial.delete();
        throw StateError('Server does not support resume');
      }
      if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) {
        throw HttpException('Model download failed: HTTP ${response.statusCode}');
      }
      final total = response.contentLength < 0 ? null : received + response.contentLength;
      var count = received;
      final sink = partial.openWrite(mode: received > 0 ? FileMode.append : FileMode.write);
      try {
        await for (final chunk in response) {
          if (cancelled) throw const HttpException('Download cancelled');
          sink.add(chunk);
          count += chunk.length;
          onProgress?.call(ModelDownloadProgress(count, total));
        }
      } finally {
        await sink.close();
      }
      if (entry.sha256 != null) {
        final bytes = await partial.readAsBytes();
        final digest = sha256.convert(bytes).toString();
        if (digest.toLowerCase() != entry.sha256!.toLowerCase()) {
          await partial.delete();
          throw StateError('Model checksum mismatch');
        }
      }
      if (destination.existsSync()) await destination.delete();
      await partial.rename(destination.path);
    } finally {
      client.close(force: true);
    }
  }
}
