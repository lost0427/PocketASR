import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/engine/embedder.dart';
import 'package:pocket_asr/engine/embedding_worker.dart';

/// Test-only [Embedder] that runs *inside the worker isolate* through the
/// `withBuilder` hook. Every call appends to a shared log file (the same
/// trick native_worker_test uses: file order equals real command order), so
/// the test can prove construction happened on the worker and that query and
/// document routed separately. [behavior] selects the failure modes.
class _FakeConfig {
  const _FakeConfig(this.logPath, this.behavior);

  final String logPath;
  final String behavior;
}

class _FakeWorkerEmbedder implements Embedder {
  _FakeWorkerEmbedder(this._config);

  final _FakeConfig _config;

  Future<void> _record(String op) => File(_config.logPath).writeAsString(
    '$op\n',
    mode: FileMode.append,
    flush: true,
  );

  @override
  final String id = 'fake';

  @override
  final int dim = 2;

  Float32List _vector(String tagged) =>
      Float32List.fromList([tagged.length.toDouble(), 0]);

  @override
  FutureOr<Float32List> embed(String text) async {
    if (_config.behavior == 'slow') {
      // Blocks the *worker* for a while; the root must stay responsive.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await _record('encode:$text');
    if (_config.behavior == 'exit-mid-embed') Isolate.exit();
    return _vector(text);
  }

  @override
  FutureOr<Float32List> embedQuery(String text) async {
    // A query-side prompt applied inside the worker — what the root receives
    // must be the *prefixed* encode, never the bare text.
    if (_config.behavior == 'fail-embed') {
      throw const EmbedderUnavailableException('encode boom');
    }
    await _record('query:$text');
    return _vector('query: $text');
  }

  @override
  FutureOr<Float32List> embedDocument(String text) async {
    await _record('document:$text');
    if (_config.behavior == 'bad-dim') return Float32List(3);
    return _vector('document: $text');
  }

  @override
  Future<void> dispose() async => _record('dispose-embedder');
}

/// Must be top-level: only top-level function references cross SendPorts.
/// The append happens inside the worker isolate, so a `construct` line in the
/// log proves the instance was built there.
Embedder _fakeBuilder(Object? config) {
  final c = config! as _FakeConfig;
  File(c.logPath).writeAsStringSync('construct\n', mode: FileMode.append);
  return _FakeWorkerEmbedder(c);
}

void main() {
  late Directory logDir;

  setUp(() {
    logDir = Directory.systemTemp.createTempSync('embedding_worker_test');
  });
  tearDown(() {
    logDir.deleteSync(recursive: true);
  });

  WorkerEmbedder embedder(String behavior) {
    final logPath = '${logDir.path}${Platform.pathSeparator}$behavior.log';
    File(logPath).writeAsStringSync('');
    return WorkerEmbedder.withBuilder(
      'fake:$behavior',
      _fakeBuilder,
      _FakeConfig(logPath, behavior),
    );
  }

  List<String> log(String behavior) => File(
    '${logDir.path}${Platform.pathSeparator}$behavior.log',
  ).readAsLinesSync();

  test('worker-side construction, load probe, serialized role routing', () async {
    final e = embedder('normal');
    addTearDown(e.dispose);

    await e.load();
    expect(e.dim, 2); // probed across the boundary, not assumed

    final plain = await e.embed('hello');
    final query = await e.embedQuery('hello');
    final document = await e.embedDocument('hello');

    // The reply is the real vector produced inside the worker: the query got
    // its prefix there, the document its passage prefix, plain encode neither.
    expect(plain, Float32List.fromList([5, 0]));
    expect(query, Float32List.fromList(['query: hello'.length.toDouble(), 0]));
    expect(document, Float32List.fromList(['document: hello'.length.toDouble(), 0]));

    // One instance (construct once), ops in call order, in the worker.
    expect(log('normal'), [
      'construct',
      'encode:hello',
      'query:hello',
      'document:hello',
    ]);
  });

  test('a slow embed does not block the root isolate', () async {
    final e = embedder('slow');
    addTearDown(e.dispose);
    await e.load();

    final ticks = <int>[];
    final timer = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => ticks.add(ticks.length),
    );
    final vector = await e.embed('tick tick');
    timer.cancel();

    // The worker took ~200ms of its own time; the root kept ticking, which is
    // the whole point of moving synchronous FFI off the UI thread.
    expect(ticks.length, greaterThan(3));
    expect(vector, Float32List.fromList([9, 0]));
  });

  test('embed errors reach the caller and leave the worker usable', () async {
    final failing = embedder('fail-embed');
    addTearDown(failing.dispose);
    await failing.load();
    await expectLater(
      failing.embedQuery('x'),
      throwsA(
        isA<EmbedderUnavailableException>().having(
          (x) => x.message, 'message', contains('encode boom'),
        ),
      ),
    );
    // No permanent poisoning: documents still round-trip.
    expect(await failing.embedDocument('y'), isA<Float32List>());
  });

  test('worker exit mid-call ends pending calls instead of hanging', () async {
    final e = embedder('exit-mid-embed');
    await e.load();
    await expectLater(
      e.embed('gone'),
      throwsA(
        isA<EmbedderUnavailableException>().having(
          (x) => x.message, 'message', contains('exited'),
        ),
      ),
    ).timeout(const Duration(seconds: 10));
    // dispose must also finish (dead path), not await a reply that never comes.
    await e.dispose().timeout(const Duration(seconds: 10));
  });

  test('load failure is an EmbedderUnavailableException, not a hang', () async {
    // A builder that throws on construction inside the worker: the fatal
    // event must fail the handshake with the native error preserved.
    final e = WorkerEmbedder.withBuilder('fake:throw', _throwingBuilder, null);
    await expectLater(
      e.load(),
      throwsA(
        isA<EmbedderUnavailableException>().having(
          (x) => x.message, 'message', contains('native library missing'),
        ),
      ),
    ).timeout(const Duration(seconds: 10));
    await e.dispose().timeout(const Duration(seconds: 10));
  });

  test('dispose before spawn tears down nothing and later calls fail', () async {
    final e = embedder('never');
    await e.dispose();
    expect(log('never'), isEmpty); // no isolate was created for nothing
    await expectLater(e.embed('x'), throwsA(isA<EmbedderUnavailableException>()));
  });

  test('calls after dispose fail fast', () async {
    final e = embedder('disposed');
    await e.load();
    await e.dispose();
    expect(log('disposed'), contains('dispose-embedder'));
    await expectLater(e.embedDocument('x'), throwsA(isA<EmbedderUnavailableException>()));
  });
}

Embedder _throwingBuilder(Object? config) =>
    throw const EmbedderUnavailableException('native library missing');
