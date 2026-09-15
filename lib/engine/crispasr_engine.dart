/// Native CrispASR [AsrEngine] adapter (plan §2 / Phase 4).
///
/// Wraps `package:crispasr`, which is pure Dart FFI over `libcrispasr`. The
/// library is **not** bundled in this repo, so on a build without one the
/// adapter reports [EngineCapabilities.unavailable] and every operation fails
/// with [EngineUnavailableException] — it never emits placeholder text.
///
/// The unified `CrispasrSession` API is used (backend auto-detected from the
/// GGUF metadata), not the legacy whisper-only `CrispASR` class, because the
/// allowlist ships non-whisper families too.
library;

import 'dart:ffi';

import 'package:crispasr/crispasr.dart' as crisp;

import 'asr_engine.dart';

/// [AsrEngine] backed by the native CrispASR shared library.
class CrispAsrEngine implements AsrEngine {
  /// [libPath] overrides the platform default library lookup (useful when the
  /// `.so`/`.dll` is staged outside the loader path). [threads] is passed to the
  /// native session.
  CrispAsrEngine({this.libPath, this.threads = 4});

  final String? libPath;
  final int threads;

  crisp.CrispasrSession? _session;

  bool? _libraryPresent;
  String? _libraryError;

  @override
  String get id => 'crispasr';

  /// Probes once whether the native library can actually be opened. Cached
  /// because the probe loads the library, which is not free.
  bool _libraryAvailable() {
    final cached = _libraryPresent;
    if (cached != null) return cached;

    try {
      DynamicLibrary.open(libPath ?? crisp.CrispASR.defaultLibName());
      _libraryPresent = true;
    } catch (error) {
      _libraryPresent = false;
      _libraryError =
          'CrispASR native library (libcrispasr.so / libcrispasr.dylib / '
          'crispasr.dll) is not bundled; transcription is unavailable. ($error)';
    }
    return _libraryPresent!;
  }

  @override
  Future<List<Backend>> availableBackends() async =>
      _libraryAvailable() ? const [Backend.cpu] : const [];

  @override
  Future<EngineCapabilities> capabilities() async {
    if (!_libraryAvailable()) {
      return EngineCapabilities.unavailable(_libraryError!);
    }
    return const EngineCapabilities(
      available: true,
      backends: {Backend.cpu},
      // CrispASR's VAD path needs a separate VAD model file this build does not
      // ship, and it reports segments/words rather than tokenizer tokens.
      supportsVad: false,
      supportsTokenCount: false,
    );
  }

  @override
  Future<void> load(EngineModelSpec spec, Backend backend) async {
    if (!_libraryAvailable()) {
      throw EngineUnavailableException(_libraryError!);
    }
    if (backend != Backend.cpu) {
      throw EngineUnavailableException(
        'CrispASR runs CPU-only in this release; requested ${backend.name}.',
      );
    }

    _session?.close();
    _session = null;
    try {
      _session = crisp.CrispasrSession.open(
        spec.path,
        nThreads: threads,
        libPath: libPath,
      );
    } catch (error) {
      throw EngineUnavailableException(
        'CrispASR failed to load model "${spec.path}": $error',
      );
    }
  }

  @override
  Stream<TranscribeProgress> transcribe(TranscribeRequest request) async* {
    final session = _session;
    if (session == null) {
      throw const EngineUnavailableException(
        'CrispASR: no model loaded; call load() before transcribe().',
      );
    }

    final elapsed = Stopwatch()..start();
    try {
      final audio = crisp.decodeAudioFile(request.audioPath, libPath: libPath);
      final segments = session.transcribe(
        audio.samples,
        language: request.language,
      );
      final text = segments.map((segment) => segment.text).join().trim();
      elapsed.stop();
      yield TranscribeProgress(elapsed: elapsed.elapsed, ratio: 1, partialText: text);
    } catch (error) {
      throw EngineUnavailableException('CrispASR transcription failed: $error');
    }
  }

  @override
  Future<VadPlan> planVad(TranscribeRequest request) => Future.error(
    const EngineUnavailableException(
      'CrispASR VAD needs a separate Silero/VAD model file that this build '
      'does not ship; VAD is unavailable.',
    ),
  );

  @override
  Future<void> dispose() async {
    _session?.close();
    _session = null;
  }
}
