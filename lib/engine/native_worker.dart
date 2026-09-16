/// Dedicated worker isolate for one native [AsrEngine] (plan §2 execution).
///
/// [WorkerAsrEngine] is the production adapter the registry hands out for
/// `crispasr`/`sherpa`: the real engine — and every native handle it opens —
/// is constructed *inside* a private isolate and never in the root isolate.
/// Commands are processed strictly one at a time by the worker's own event
/// loop, so a synchronous native `load`/`transcribe`/`dispose` can never race
/// another. Progress events travel back over a [SendPort] as the engine emits
/// them; worker failures and exits complete every pending call with an error
/// instead of hanging the caller.
///
/// Deliberately *not* here:
/// - platform decoding (Android's `pocket_asr/audio_decode` MethodChannel) —
///   MethodChannels belong to the root isolate's binary messenger, so audio is
///   decoded on the root and only file paths cross into the worker;
/// - any generic RPC framework — one command enum, one reply event, done;
/// - a production fake-worker fallback — [WorkerAsrEngine.withBuilder] exists
///   for tests only.
library;

import 'dart:async';
import 'dart:isolate';

import 'asr_engine.dart';
import 'crispasr_engine.dart';
import 'sherpa_engine.dart';

/// Builds the engine instance *inside* the worker isolate.
///
/// Only top-level/static function references may cross the isolate boundary,
/// which is exactly why this is a plain function type and not a closure.
typedef WorkerEngineBuilder = AsrEngine Function(Object? config);

/// A [WorkerAsrEngine] that runs [AsrEngine] commands on a dedicated isolate.
///
/// The instance in the root isolate holds no native state; it is a mailbox.
/// Lifecycle: constructed cheaply, the isolate spawns lazily on the first
/// command, serializes all commands, and [dispose] shuts the worker down.
class WorkerAsrEngine implements CancellableAsrEngine {
  /// CrispASR on a private worker isolate. [threads]/[libPath] configure the
  /// native session built inside the worker.
  factory WorkerAsrEngine.crispAsr({int threads = 4, String? libPath}) =>
      WorkerAsrEngine._(
        'crispasr',
        _buildNative,
        _NativeSetup(engineKind: 'crispasr', threads: threads, libPath: libPath),
      );

  /// sherpa-onnx on a private worker isolate.
  factory WorkerAsrEngine.sherpa({int threads = 4, String? libraryPath}) =>
      WorkerAsrEngine._(
        'sherpa',
        _buildNative,
        _NativeSetup(
          engineKind: 'sherpa',
          threads: threads,
          libPath: libraryPath,
        ),
      );

  /// Test hook: run an arbitrary engine factory inside the worker so command
  /// ordering, cancellation and exit semantics can be verified without a
  /// native library (see `test/native_worker_test.dart`). [builder] must be a
  /// top-level function — closures cannot cross an isolate boundary.
  /// Production code must not use this.
  factory WorkerAsrEngine.withBuilder(
    String id,
    WorkerEngineBuilder builder,
    Object? config,
  ) => WorkerAsrEngine._(id, builder, config);

  WorkerAsrEngine._(this.id, this._builder, this._config);

  @override
  final String id;

  final WorkerEngineBuilder _builder;
  final Object? _config;

  ReceivePort? _port;
  Isolate? _isolate;
  RawReceivePort? _exitPort;
  Future<void>? _started;
  final Completer<SendPort> _handshake = Completer<SendPort>();
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  final Map<int, StreamController<TranscribeProgress>> _streams =
      <int, StreamController<TranscribeProgress>>{};
  SendPort? _commands;
  int _nextId = 0;
  bool _cancelled = false;

  /// Ids of transcribe calls covered by a [cancel] request. Per-call on
  /// purpose: [load] clears the gate flag for the *next* job, and a call from
  /// the *previous* job must still surface the cancellation even if its reply
  /// lands after that reset — a cancelled call may never look like a success.
  final Set<int> _cancelledCalls = <int>{};

  bool _dead = false;
  bool _disposed = false;

  /// Cooperative cancel: an in-flight native call runs to completion and then
  /// surfaces [EngineCancelledException]; calls that have not reached the
  /// worker yet (e.g. the next chunk) fail immediately. [load] clears the gate
  /// flag so a new job can start; already-cancelled calls stay cancelled.
  @override
  Future<void> cancel() async {
    _cancelled = true;
    _cancelledCalls.addAll(_streams.keys);
  }

  @override
  Future<List<Backend>> availableBackends() async {
    final value = await _call('backends', null);
    return (value as List<Backend>);
  }

  @override
  Future<EngineCapabilities> capabilities() async {
    final value = await _call('capabilities', null);
    return (value as EngineCapabilities);
  }

  @override
  Future<void> load(EngineModelSpec spec, Backend backend) async {
    _cancelled = false; // a fresh job supersedes a previous cancel request
    await _call('load', (spec, backend));
  }

  @override
  Future<VadPlan> planVad(TranscribeRequest request) async {
    final value = await _call('planVad', request);
    return (value as VadPlan);
  }

  @override
  Stream<TranscribeProgress> transcribe(TranscribeRequest request) {
    if (_cancelled) {
      return Stream<TranscribeProgress>.error(
        const EngineCancelledException(
          'Cancelled before the request reached the worker.',
        ),
      );
    }
    final controller = StreamController<TranscribeProgress>();
    final id = _nextId++;
    _streams[id] = controller;
    unawaited(() async {
      try {
        await _callWithId(id, 'transcribe', request);
        // If _failAll (exit/fatal) already errored and unregistered this
        // stream, _streams no longer holds the id — do not error it twice.
        if (_streams.containsKey(id) && _cancelledCalls.contains(id)) {
          // The native call finished *after* cancel was requested. Report it
          // as cancelled — never as a success the caller asked to abort.
          controller.addError(
            const EngineCancelledException(
              'Cancelled while the native call was in flight; it ran to '
              'completion because killing native code mid-call is unsafe.',
            ),
          );
        }
      } catch (error, stack) {
        if (_streams.containsKey(id)) {
          controller.addError(error, stack);
        }
      } finally {
        _streams.remove(id);
        _cancelledCalls.remove(id);
        await controller.close();
      }
    }());
    return controller.stream;
  }

  /// Answers the worker, releases its native session and kills the isolate.
  /// Safe to call more than once and before the isolate ever spawned.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_started == null) return; // never spawned anything; nothing to tear down
    try {
      await _call('dispose', null);
    } on Object {
      // Worker already dead (its exit failed this call) — teardown below.
    }
    _teardown();
  }

  Future<Object?> _call(String op, Object? payload) =>
      _callWithId(_nextId++, op, payload);

  Future<Object?> _callWithId(int id, String op, Object? payload) async {
    // 'dispose' is exempt: dispose() sets the flag itself and must still be
    // able to tell the worker to release its native session.
    if (_disposed && op != 'dispose') {
      throw EngineUnavailableException('WorkerAsrEngine($id) is disposed.');
    }
    await _start();
    final port = _commands;
    if (port == null || _dead) {
      throw EngineUnavailableException('ASR worker isolate is no longer running.');
    }
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send(_AsrCommand(id, op, payload));
    try {
      return await completer.future;
    } finally {
      _pending.remove(id);
    }
  }

  /// Spawns the worker once; all commands await this.
  Future<void> _start() {
    // The handshake completer is completed by the worker's 'ready' event or by
    // the exit listener, whichever comes first; caching its future here means
    // concurrent first calls share one spawn.
    final started = _started ??= () async {
      final port = ReceivePort()..listen(_handle);
      _port = port;
      final exitPort = RawReceivePort((_) => _onExit());
      _exitPort = exitPort;
      try {
        _isolate = await Isolate.spawn(
          _entry,
          _Boot(port.sendPort, _builder, _config),
          debugName: 'asr-worker:$id',
          errorsAreFatal: true,
          onExit: exitPort.sendPort,
        );
        await _handshake.future;
      } on Object catch (error) {
        _dead = true;
        _teardown();
        throw EngineUnavailableException(
          'Failed to start the ASR worker isolate: $error',
        );
      }
    }();
    return started;
  }

  void _handle(Object? message) {
    if (message is! _AsrEvent) return;
    switch (message.kind) {
      case _eventReady:
        _commands = message.value as SendPort;
        if (!_handshake.isCompleted) _handshake.complete(_commands);
      case _eventReply:
        _pending[message.id]?.complete(message.value);
      case _eventProgress:
        _streams[message.id]?.add(message.value as TranscribeProgress);
      case _eventFailure:
        final engineError = message.value is String && message.engineError;
        _pending[message.id]?.completeError(
          engineError
              ? EngineUnavailableException(message.value as String)
              : StateError('ASR worker error: ${message.value}'),
        );
      case _eventFatal:
        _failAll('ASR worker failed: ${message.value}');
    }
  }

  void _onExit() {
    if (_dead) return;
    _dead = true;
    if (!_handshake.isCompleted) {
      _handshake.completeError(
        EngineUnavailableException('ASR worker isolate exited before starting.'),
      );
    }
    _failAll('ASR worker isolate exited.');
  }

  /// Nothing may wait forever on an isolate that will not answer: fail every
  /// pending call and close every open transcribe stream.
  void _failAll(String reason) {
    for (final controller in _streams.values) {
      if (!controller.isClosed) {
        controller.addError(EngineUnavailableException(reason));
        unawaited(controller.close());
      }
    }
    _streams.clear();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(EngineUnavailableException(reason));
      }
    }
    _pending.clear();
  }

  void _teardown() {
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _exitPort?.close();
    _exitPort = null;
    _port?.close();
    _port = null;
    _commands = null;
  }
}

// ---------------------------------------------------------------------------
// Worker side: everything below runs on the spawned isolate.
// ---------------------------------------------------------------------------

class _Boot {
  const _Boot(this.main, this.builder, this.config);

  final SendPort main;
  final WorkerEngineBuilder builder;
  final Object? config;
}

class _NativeSetup {
  const _NativeSetup({
    required this.engineKind,
    required this.threads,
    this.libPath,
  });

  final String engineKind;
  final int threads;
  final String? libPath;
}

class _AsrCommand {
  const _AsrCommand(this.id, this.op, this.payload);

  final int id;
  final String op;
  final Object? payload;
}

class _AsrEvent {
  const _AsrEvent(this.kind, this.id, this.value, [this.engineError = false]);

  final String kind;
  final int? id;
  final Object? value;
  final bool engineError;
}

const _eventReady = 'ready';
const _eventReply = 'reply';
const _eventProgress = 'progress';
const _eventFailure = 'failure';
const _eventFatal = 'fatal';

/// Constructs the real native adapter — this call site only ever executes
/// inside the worker isolate.
AsrEngine _buildNative(Object? config) {
  final setup = config as _NativeSetup;
  return switch (setup.engineKind) {
    'crispasr' => CrispAsrEngine(libPath: setup.libPath, threads: setup.threads),
    'sherpa' => SherpaEngine(
      threads: setup.threads,
      libraryPath: setup.libPath,
    ),
    final other => throw EngineUnavailableException(
      'No native engine registered for kind "$other".',
    ),
  };
}

Future<void> _entry(_Boot boot) async {
  late final ReceivePort commands;
  final main = boot.main;
  try {
    commands = ReceivePort();
    main.send(_AsrEvent(_eventReady, null, commands.sendPort));
    final engine = boot.builder(boot.config);
    // Sequential on purpose: one command's synchronous native work must
    // finish before the next starts, so sessions are never touched concurrently.
    await for (final message in commands) {
      final cmd = message as _AsrCommand;
      try {
        switch (cmd.op) {
          case 'capabilities':
            main.send(_AsrEvent(_eventReply, cmd.id, await engine.capabilities()));
          case 'backends':
            main.send(
              _AsrEvent(_eventReply, cmd.id, await engine.availableBackends()),
            );
          case 'load':
            final (spec, backend) = cmd.payload! as
                (EngineModelSpec, Backend);
            await engine.load(spec, backend);
            main.send(_AsrEvent(_eventReply, cmd.id, null));
          case 'transcribe':
            await for (final progress
                in engine.transcribe(cmd.payload! as TranscribeRequest)) {
              main.send(_AsrEvent(_eventProgress, cmd.id, progress));
            }
            main.send(_AsrEvent(_eventReply, cmd.id, null));
          case 'planVad':
            main.send(
              _AsrEvent(
                _eventReply,
                cmd.id,
                await engine.planVad(cmd.payload! as TranscribeRequest),
              ),
            );
          case 'dispose':
            await engine.dispose();
            main.send(_AsrEvent(_eventReply, cmd.id, null));
            commands.close();
            return;
          default:
            main.send(
              _AsrEvent(_eventFailure, cmd.id, 'unknown worker op "${cmd.op}"'),
            );
        }
      } on Object catch (error) {
        main.send(
          _AsrEvent(
            _eventFailure,
            cmd.id,
            error is EngineUnavailableException ? error.message : '$error',
            error is EngineUnavailableException,
          ),
        );
      }
    }
    // Port closed without a dispose (defensive; the root does not do this).
    await engine.dispose();
  } on Object catch (fatal) {
    main.send(_AsrEvent(_eventFatal, null, '$fatal'));
  }
}
