import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/engine/asr_engine.dart';
import 'package:pocket_asr/engine/engine_registry.dart';
import 'package:pocket_asr/engine/native_worker.dart';

/// Worker tests run a fake [AsrEngine] on the real isolate through the
/// `@visibleForTesting` builder — the production fallback path is never
/// taken. The fake lives here (test-only) and records every call by
/// appending to a shared temp file: the worker awaits each append before
/// replying, so file order equals real command order.
class _FakeConfig {
  const _FakeConfig(this.logPath, this.behavior);

  final String logPath;
  final String behavior;
}

class _FakeWorkerEngine implements AsrEngine {
  _FakeWorkerEngine(this._config);

  final _FakeConfig _config;

  Future<void> _record(String op) => File(_config.logPath).writeAsString(
    '$op\n',
    mode: FileMode.append,
    flush: true,
  );

  @override
  String get id => 'fake';

  @override
  Future<List<Backend>> availableBackends() async {
    await _record('backends');
    return const [Backend.cpu];
  }

  @override
  Future<EngineCapabilities> capabilities() async {
    await _record('capabilities');
    return const EngineCapabilities(available: true, backends: {Backend.cpu});
  }

  @override
  Future<void> load(EngineModelSpec spec, Backend backend) async {
    await _record('load:${spec.path}');
    if (_config.behavior == 'fail-load') {
      throw const EngineUnavailableException('load boom');
    }
  }

  @override
  Stream<TranscribeProgress> transcribe(TranscribeRequest request) async* {
    await _record('transcribe');
    switch (_config.behavior) {
      case 'fail-transcribe':
        throw const EngineUnavailableException('transcribe boom');
      case 'exit':
        // Die mid-call without replying: the facade must end pending work
        // through the exit listener, not wait forever.
        Isolate.exit();
      case 'slow':
        await Future<void>.delayed(const Duration(milliseconds: 200));
        yield const TranscribeProgress(
          elapsed: Duration(milliseconds: 200),
          ratio: 1,
          partialText: 'slow done',
        );
      default:
        // Echo what crossed the boundary so serialization is verified.
        yield TranscribeProgress(
          elapsed: const Duration(milliseconds: 5),
          ratio: 1,
          partialText: 'heard:${request.audioPath}',
          tokens: 2,
        );
    }
  }

  @override
  Future<VadPlan> planVad(
    TranscribeRequest request,
    NeuralVadSettings vad,
  ) async {
    // Recording the model path proves the settings record crossed the
    // isolate boundary intact alongside the request.
    await _record('planVad:${vad.modelPath}');
    return const VadPlan([
      VadSegment(start: Duration.zero, end: Duration(seconds: 1)),
    ]);
  }

  @override
  Future<void> dispose() async {
    await _record('dispose-engine');
  }
}

/// Must be top-level: only top-level function references cross SendPorts.
/// The append here happens inside the worker isolate, so a `construct` line
/// in the log proves the native-side instance was built there.
AsrEngine _fakeBuilder(Object? config) {
  final c = config! as _FakeConfig;
  File(c.logPath).writeAsStringSync(
    'construct\n',
    mode: FileMode.append,
    flush: true,
  );
  return _FakeWorkerEngine(c);
}

void main() {
  late Directory logDir;

  setUp(() {
    logDir = Directory.systemTemp.createTempSync('native_worker_test');
  });
  tearDown(() {
    logDir.deleteSync(recursive: true);
  });

  WorkerAsrEngine engine(String behavior) {
    final logPath = '${logDir.path}${Platform.pathSeparator}$behavior.log';
    final e = WorkerAsrEngine.withBuilder(
      'fake',
      _fakeBuilder,
      _FakeConfig(logPath, behavior),
    );
    // The builder records construction into the log, so `construct` doubles as
    // "the native instance was made inside the worker".
    File(logPath).writeAsStringSync('');
    return e;
  }

  List<String> log(String behavior) => File(
    '${logDir.path}${Platform.pathSeparator}$behavior.log',
  ).readAsLinesSync();

  test('serial command order, worker-side construction, session reuse', () async {
    final e = engine('normal');
    // 'construct' is recorded by the builder on the worker's first command.
    expect(await e.capabilities(), isA<EngineCapabilities>().having(
      (c) => c.available, 'available', isTrue,
    ));
    await e.load(const EngineModelSpec(path: 'model.gguf'), Backend.cpu);
    final first = await e.transcribe(
      const TranscribeRequest(audioPath: 'a.wav'),
    ).toList();
    final second = await e.transcribe(
      const TranscribeRequest(audioPath: 'b.wav'),
    ).toList();
    final plan = await e.planVad(
      const TranscribeRequest(audioPath: 'a.wav'),
      const NeuralVadSettings(modelPath: 'vad.onnx'),
    );
    await e.dispose();

    // One engine instance (construct once) served both transcribes after a
    // single load: the model session is reused, and ops arrive in call order.
    expect(log('normal'), [
      'construct',
      'capabilities',
      'load:model.gguf',
      'transcribe',
      'transcribe',
      'planVad:vad.onnx',
      'dispose-engine',
    ]);
    expect(first.single.partialText, 'heard:a.wav');
    expect(second.single.partialText, 'heard:b.wav');
    expect(second.single.tokens, 2);
    expect(plan.segments, hasLength(1));
  });

  test('engine errors end the pending call and leave the worker usable', () async {
    final failing = engine('fail-load');
    await expectLater(
      failing.load(const EngineModelSpec(path: 'x'), Backend.cpu),
      throwsA(
        isA<EngineUnavailableException>().having(
          (x) => x.message, 'message', contains('load boom'),
        ),
      ),
    );
    // No permanent poisoning: the next command still round-trips.
    expect(await failing.availableBackends(), [Backend.cpu]);
    await failing.dispose();

    final alsoFailing = engine('fail-transcribe');
    await expectLater(
      alsoFailing.transcribe(const TranscribeRequest(audioPath: 'x.wav')),
      emitsError(
        isA<EngineUnavailableException>().having(
          (x) => x.message, 'message', contains('transcribe boom'),
        ),
      ),
    );
    await alsoFailing.dispose();
  });

  test('worker exit mid-call ends pending calls instead of hanging', () async {
    final e = engine('exit');
    await e.load(const EngineModelSpec(path: 'x'), Backend.cpu);
    await expectLater(
      e.transcribe(const TranscribeRequest(audioPath: 'x.wav')).drain(),
      throwsA(
        isA<EngineUnavailableException>().having(
          (x) => x.message, 'message', contains('exited'),
        ),
      ),
    ).timeout(const Duration(seconds: 10));
    // dispose must also finish (dead path), not await a reply that never comes.
    await e.dispose().timeout(const Duration(seconds: 10));
  });

  test(
    'cancel errors the in-flight call once it lands, refuses later ones, '
    'and load clears the flag',
    () async {
      final e = engine('slow');
      await e.load(const EngineModelSpec(path: 'x'), Backend.cpu);

      final events = <Object>[];
      final done = Completer<void>();
      e.transcribe(const TranscribeRequest(audioPath: 'x.wav')).listen(
        events.add,
        onError: (Object error) => events.add(error),
        onDone: done.complete,
      );
      // Cancel while the fake native call is still running: it must finish
      // (its real progress still arrives), then surface the cancellation —
      // never a silent success.
      await e.cancel();
      await done.future.timeout(const Duration(seconds: 10));
      expect(events, [isA<TranscribeProgress>(), isA<EngineCancelledException>()]);

      // Later chunks fail immediately without reaching the worker.
      await expectLater(
        e.transcribe(const TranscribeRequest(audioPath: 'x.wav')),
        emitsError(isA<EngineCancelledException>()),
      );

      // A new job (load) supersedes the previous cancellation.
      await e.load(const EngineModelSpec(path: 'x'), Backend.cpu);
      final fresh = await e
          .transcribe(const TranscribeRequest(audioPath: 'x.wav'))
          .toList();
      expect(fresh.single.partialText, 'slow done');
      await e.dispose();
    },
  );

  test(
    'a new job load does not resurrect a cancelled in-flight call',
    () async {
      final e = engine('slow');
      await e.load(const EngineModelSpec(path: 'x'), Backend.cpu);

      final events = <Object>[];
      final done = Completer<void>();
      e.transcribe(const TranscribeRequest(audioPath: 'x.wav')).listen(
        events.add,
        onError: (Object error) => events.add(error),
        onDone: done.complete,
      );
      await e.cancel();
      // The next job's load resets the gate flag while the cancelled call is
      // still in flight; its reply must error, not close as a success.
      await e.load(const EngineModelSpec(path: 'x'), Backend.cpu);
      await done.future.timeout(const Duration(seconds: 10));
      expect(events.last, isA<EngineCancelledException>());

      // The new job itself is uncancelled and works.
      final fresh = await e
          .transcribe(const TranscribeRequest(audioPath: 'x.wav'))
          .toList();
      expect(fresh.single.partialText, 'slow done');
      await e.dispose();
    },
  );

  test(
    'planVad is not gated by a prior cancel, but transcribe is',
    () async {
      // The VAD worker never loads an ASR model, so `cancel` does not block a
      // later planVad: the app replaces a cancelled VAD worker on retry rather
      // than relying on this call to reset the flag.
      final e = engine('slow');
      await e.cancel();
      final plan = await e.planVad(
        const TranscribeRequest(audioPath: 'x.wav'),
        const NeuralVadSettings(modelPath: 'vad.onnx'),
      );
      expect(plan.segments, hasLength(1));

      // transcribe, by contrast, refuses until a load clears the flag.
      await expectLater(
        e.transcribe(const TranscribeRequest(audioPath: 'x.wav')),
        emitsError(isA<EngineCancelledException>()),
      );
      await e.dispose();
    },
  );

  test('dispose before spawn completes without ever starting a worker', () async {
    final e = engine('never');
    await e.dispose();
    expect(log('never'), isEmpty); // no isolate was created for nothing
    await expectLater(
      e.capabilities(),
      throwsA(isA<EngineUnavailableException>()),
    );
  });

  test('registry-backed sherpa worker probes honestly on this host', () async {
    // The real adapter runs inside the worker isolate: availability must
    // mirror the host (no fake successes) and load must fail loudly when the
    // native library or model files are absent.
    final e = EngineRegistry().createAsr('sherpa');
    addTearDown(e.dispose);

    final caps = await e.capabilities().timeout(const Duration(seconds: 30));
    if (caps.available) {
      expect(caps.unavailableReason, isNull);
      expect(caps.backends, isNotEmpty);
    } else {
      expect(caps.unavailableReason, isNotEmpty);
      expect(caps.backends, isEmpty);
      await expectLater(
        e.load(
          const EngineModelSpec(path: 'missing.onnx', family: 'sensevoice'),
          Backend.cpu,
        ),
        throwsA(isA<EngineUnavailableException>()),
      );
    }
  });
}
