/// Embedding-only worker isolate (plan §2 execution, embedding lane).
///
/// [WorkerEmbedder] is the production [Embedder] the app wires: the real
/// [CrispEmbedder] — the only embedder whose calls block for a whole native
/// FFI encode — is constructed and used *inside* a private isolate and never
/// in the root isolate. Commands are processed one at a time by the worker's
/// own event loop, so a synchronous native `probe`/`encode` can never race
/// another. Worker failures and exits complete every pending call with an
/// error instead of hanging the caller.
///
/// The shape deliberately mirrors native_worker.dart (handshake, one command
/// enum, one reply event, fail-all on exit) but stays embedding-only: five
/// ops, no progress streams, no cancellation, no generic RPC framework.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'crisp_embedder.dart';
import 'embedder.dart';

/// Builds the embedder instance *inside* the worker isolate.
///
/// Only top-level/static function references may cross the isolate boundary,
/// which is exactly why this is a plain function type and not a closure.
typedef EmbedderWorkerBuilder = Embedder Function(Object? config);

/// An [Embedder] whose real instance lives on a dedicated isolate.
///
/// The root-isolate object holds no native state; it is a mailbox. Lifecycle:
/// constructed cheaply, the isolate spawns lazily on [load], every embed
/// serializes behind it, and [dispose] shuts the worker down.
class WorkerEmbedder implements Embedder {
  /// CrispEmbed on a private worker isolate. [threads]/[libPath] configure
  /// the native session built inside the worker; [id] is computed on the root
  /// from the path + file size (a stat, not FFI) so it is stable even when
  /// the worker fails to load.
  factory WorkerEmbedder.crisp({
    required String modelPath,
    int threads = 0,
    String? libPath,
  }) => WorkerEmbedder._(
    CrispEmbedder.identityFor(modelPath),
    _buildNative,
    _CrispSetup(modelPath: modelPath, threads: threads, libPath: libPath),
  );

  /// Test hook: run an arbitrary embedder factory inside the worker so command
  /// ordering and exit semantics can be verified without a native library.
  /// [builder] must be a top-level function — closures cannot cross an
  /// isolate boundary. Production code must not use this.
  factory WorkerEmbedder.withBuilder(
    String id,
    EmbedderWorkerBuilder builder,
    Object? config,
  ) => WorkerEmbedder._(id, builder, config);

  WorkerEmbedder._(this.id, this._builder, this._config);

  @override
  final String id;

  final EmbedderWorkerBuilder _builder;
  final Object? _config;

  int? _dim;

  /// Vector length, learned from the worker during [load]. Reading it before
  /// the load completed is a wiring bug, not a runtime state.
  @override
  int get dim {
    final dim = _dim;
    if (dim == null) {
      throw StateError('WorkerEmbedder("$id") used before load() completed.');
    }
    return dim;
  }

  ReceivePort? _port;
  Isolate? _isolate;
  RawReceivePort? _exitPort;
  Future<void>? _started;
  final Completer<SendPort> _handshake = Completer<SendPort>();
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  SendPort? _commands;
  int _nextId = 0;
  bool _dead = false;
  bool _disposed = false;

  /// Spawns the worker, constructs the real embedder inside it (that is the
  /// native model load), and learns [dim]. Failures throw
  /// [EmbedderUnavailableException] — never a silent fallback.
  Future<void> load() async {
    _dim = await _call('probe', null) as int;
  }

  @override
  Future<Float32List> embed(String text) async =>
      (await _call('encode', text)) as Float32List;

  @override
  Future<Float32List> embedQuery(String text) async =>
      (await _call('query', text)) as Float32List;

  @override
  Future<Float32List> embedDocument(String text) async =>
      (await _call('document', text)) as Float32List;

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

  Future<Object?> _call(String op, Object? payload) async {
    // 'dispose' is exempt: dispose() sets the flag itself and must still be
    // able to tell the worker to release its native session.
    if (_disposed && op != 'dispose') {
      throw EmbedderUnavailableException('WorkerEmbedder($id) is disposed.');
    }
    await _start();
    final port = _commands;
    if (port == null || _dead) {
      throw EmbedderUnavailableException(
        'Embedding worker isolate is no longer running.',
      );
    }
    final completer = Completer<Object?>();
    final callId = _nextId++;
    _pending[callId] = completer;
    port.send(_EmbedCommand(callId, op, payload));
    try {
      return await completer.future;
    } finally {
      _pending.remove(callId);
    }
  }

  /// Spawns the worker once; all commands await this.
  Future<void> _start() {
    // The handshake completer is completed by the worker's 'ready' event or by
    // a fatal/exit, whichever comes first; caching its future here means
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
          debugName: 'embedding-worker:$id',
          errorsAreFatal: true,
          onExit: exitPort.sendPort,
        );
        await _handshake.future;
      } on EmbedderUnavailableException {
        // Load failures answered by the worker keep their own message.
        _dead = true;
        _teardown();
        rethrow;
      } on Object catch (error) {
        _dead = true;
        _teardown();
        throw EmbedderUnavailableException(
          'Failed to start the embedding worker isolate: $error',
        );
      }
    }();
    return started;
  }

  void _handle(Object? message) {
    if (message is! _EmbedEvent) return;
    switch (message.kind) {
      case _eventReady:
        _commands = message.value as SendPort;
        if (!_handshake.isCompleted) _handshake.complete(_commands);
      case _eventReply:
        _pending[message.id]?.complete(message.value);
      case _eventFailure:
        _pending[message.id]?.completeError(_errorFor(message));
      case _eventFatal:
        // Construction failed (the usual case: no native library) or the
        // command loop died. The handshake doubles as "embedder constructed",
        // so an incomplete handshake here carries the real error to load().
        final error = _errorFor(message);
        if (!_handshake.isCompleted) _handshake.completeError(error);
        _failAll(error);
    }
  }

  void _onExit() {
    if (_dead) return;
    _dead = true;
    final error = EmbedderUnavailableException(
      'Embedding worker isolate exited before finishing its calls.',
    );
    if (!_handshake.isCompleted) _handshake.completeError(error);
    _failAll(error);
  }

  /// Nothing may wait forever on an isolate that will not answer: fail every
  /// pending call.
  void _failAll(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  static Object _errorFor(_EmbedEvent message) =>
      message.embedderError
      ? EmbedderUnavailableException(message.value as String)
      : StateError('Embedding worker error: ${message.value}');

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
  final EmbedderWorkerBuilder builder;
  final Object? config;
}

class _CrispSetup {
  const _CrispSetup({
    required this.modelPath,
    required this.threads,
    this.libPath,
  });

  final String modelPath;
  final int threads;
  final String? libPath;
}

class _EmbedCommand {
  const _EmbedCommand(this.id, this.op, this.payload);

  final int id;
  final String op;
  final Object? payload;
}

class _EmbedEvent {
  const _EmbedEvent(this.kind, this.id, this.value, [this.embedderError = false]);

  final String kind;
  final int? id;
  final Object? value;
  final bool embedderError;
}

const _eventReady = 'ready';
const _eventReply = 'reply';
const _eventFailure = 'failure';
const _eventFatal = 'fatal';

/// Constructs the real native adapter — this call site only ever executes
/// inside the worker isolate.
Embedder _buildNative(Object? config) {
  final setup = config as _CrispSetup;
  return CrispEmbedder(
    modelPath: setup.modelPath,
    threads: setup.threads,
    libPath: setup.libPath,
  );
}

Future<void> _entry(_Boot boot) async {
  late final ReceivePort commands;
  final main = boot.main;
  try {
    commands = ReceivePort();
    // Build first, announce ready only after the native model loaded: a
    // construction failure must reach the root through the handshake (as a
    // failed load) instead of racing a command into a dying isolate.
    final embedder = boot.builder(boot.config);
    main.send(_EmbedEvent(_eventReady, null, commands.sendPort));
    // Sequential on purpose: one command's synchronous native work must
    // finish before the next starts, so the session is never touched twice.
    await for (final message in commands) {
      final cmd = message as _EmbedCommand;
      try {
        switch (cmd.op) {
          case 'probe':
            main.send(_EmbedEvent(_eventReply, cmd.id, embedder.dim));
          case 'encode':
            main.send(
              _EmbedEvent(
                _eventReply,
                cmd.id,
                await embedder.embed(cmd.payload! as String),
              ),
            );
          case 'query':
            main.send(
              _EmbedEvent(
                _eventReply,
                cmd.id,
                await embedder.embedQuery(cmd.payload! as String),
              ),
            );
          case 'document':
            main.send(
              _EmbedEvent(
                _eventReply,
                cmd.id,
                await embedder.embedDocument(cmd.payload! as String),
              ),
            );
          case 'dispose':
            await embedder.dispose();
            main.send(_EmbedEvent(_eventReply, cmd.id, null));
            commands.close();
            return;
          default:
            main.send(
              _EmbedEvent(_eventFailure, cmd.id, 'unknown worker op "${cmd.op}"'),
            );
        }
      } on Object catch (error) {
        final unavailable = error is EmbedderUnavailableException;
        main.send(
          _EmbedEvent(
            _eventFailure,
            cmd.id,
            unavailable ? error.message : '$error',
            unavailable,
          ),
        );
      }
    }
    // Port closed without a dispose (defensive; the root does not do this).
    await embedder.dispose();
  } on Object catch (fatal) {
    final unavailable = fatal is EmbedderUnavailableException;
    main.send(
      _EmbedEvent(
        _eventFatal,
        null,
        unavailable ? fatal.message : '$fatal',
        unavailable,
      ),
    );
  }
}
