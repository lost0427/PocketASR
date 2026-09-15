/// Native sherpa-onnx [AsrEngine] adapter (plan §2 / §10).
///
/// Wraps `package:sherpa_onnx`'s offline recognizer. Unlike CrispASR, the
/// sherpa-onnx Flutter plugin bundles its own native libraries (Windows `.dll`s
/// and per-ABI Android packages), so this adapter can be genuinely available
/// once the plugin builds. It runs CPU-only here; native init/load/transcribe
/// failures always surface as [EngineUnavailableException].
library;

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'asr_engine.dart';

/// [AsrEngine] backed by sherpa-onnx's `OfflineRecognizer`.
///
/// sherpa-onnx models are multi-file (e.g. whisper needs an encoder + decoder,
/// and every family needs a `tokens.txt`). [EngineModelSpec] only carries one
/// path, so the adapter derives [tokensPath] as `tokens.txt` next to the model
/// and accepts explicit [encoderPath]/[decoderPath] overrides. A missing file
/// fails `load` with a clear message rather than guessing.
class SherpaEngine implements AsrEngine {
  SherpaEngine({
    this.tokensPath,
    this.encoderPath,
    this.decoderPath,
    this.threads = 4,
    this.libraryPath,
  });

  /// Path to `tokens.txt`; defaults to `tokens.txt` beside the model file.
  final String? tokensPath;

  /// Whisper encoder ONNX; defaults to the [EngineModelSpec.path].
  final String? encoderPath;

  /// Whisper decoder ONNX; required for the `whisper` family.
  final String? decoderPath;

  final int threads;

  /// Optional explicit path to `sherpa-onnx-c-api` for callers that stage it.
  final String? libraryPath;

  sherpa.OfflineRecognizer? _recognizer;

  bool _initialized = false;
  String? _initError;

  @override
  String get id => 'sherpa';

  /// Loads the native bindings once. Each isolate has its own FFI state, so the
  /// caller must construct one engine per isolate.
  void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    try {
      sherpa.initBindings(libraryPath);
    } catch (error) {
      _initError = 'sherpa-onnx native library is not available: $error';
    }
  }

  @override
  Future<List<Backend>> availableBackends() async {
    _ensureInitialized();
    return _initError == null ? const [Backend.cpu] : const [];
  }

  @override
  Future<EngineCapabilities> capabilities() async {
    _ensureInitialized();
    if (_initError != null) return EngineCapabilities.unavailable(_initError!);
    return const EngineCapabilities(
      available: true,
      backends: {Backend.cpu},
      // OfflineRecognizerResult.tokens is a real tokenizer count; VAD needs a
      // separate Silero model this build does not ship.
      supportsVad: false,
      supportsTokenCount: true,
    );
  }

  @override
  Future<void> load(EngineModelSpec spec, Backend backend) async {
    _ensureInitialized();
    if (_initError != null) throw EngineUnavailableException(_initError!);
    if (backend != Backend.cpu) {
      throw EngineUnavailableException(
        'sherpa-onnx runs CPU-only in this release; requested ${backend.name}.',
      );
    }

    // Built before the try so its precise "missing file" message is not
    // rewrapped by the generic load-failure handler below.
    final model = _modelConfig(spec);

    _recognizer?.free();
    _recognizer = null;
    try {
      _recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(model: model),
      );
    } catch (error) {
      throw EngineUnavailableException(
        'sherpa-onnx failed to load model "${spec.path}": $error',
      );
    }
  }

  sherpa.OfflineModelConfig _modelConfig(EngineModelSpec spec) {
    final family = (spec.family ?? '').toLowerCase();
    final tokens = tokensPath ?? _sibling(spec.path, 'tokens.txt');

    switch (family) {
      case 'whisper':
        final decoder = decoderPath;
        if (decoder == null || decoder.isEmpty) {
          throw const EngineUnavailableException(
            'sherpa-onnx whisper needs both an encoder and a decoder ONNX; '
            'pass decoderPath (and optionally encoderPath).',
          );
        }
        return sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: encoderPath ?? spec.path,
            decoder: decoder,
          ),
          tokens: tokens,
          numThreads: threads,
          modelType: 'whisper',
        );
      case 'sensevoice':
      case 'sense_voice':
        return sherpa.OfflineModelConfig(
          senseVoice: sherpa.OfflineSenseVoiceModelConfig(model: spec.path),
          tokens: tokens,
          numThreads: threads,
        );
      case 'paraformer':
        return sherpa.OfflineModelConfig(
          paraformer: sherpa.OfflineParaformerModelConfig(model: spec.path),
          tokens: tokens,
          numThreads: threads,
        );
      default:
        throw EngineUnavailableException(
          'sherpa-onnx adapter does not map model family "$family" yet; '
          'supported: sensevoice, whisper, paraformer.',
        );
    }
  }

  @override
  Stream<TranscribeProgress> transcribe(TranscribeRequest request) async* {
    final recognizer = _recognizer;
    if (recognizer == null) {
      throw const EngineUnavailableException(
        'sherpa-onnx: no model loaded; call load() before transcribe().',
      );
    }

    final elapsed = Stopwatch()..start();
    try {
      final wave = sherpa.readWave(request.audioPath);
      if (wave.samples.isEmpty || wave.sampleRate <= 0) {
        throw StateError('could not read WAV audio "${request.audioPath}"');
      }

      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(
          samples: wave.samples,
          sampleRate: wave.sampleRate,
        );
        recognizer.decode(stream);
        final result = recognizer.getResult(stream);
        elapsed.stop();
        yield TranscribeProgress(
          elapsed: elapsed.elapsed,
          ratio: 1,
          partialText: result.text,
          tokens: result.tokens.isEmpty ? null : result.tokens.length,
        );
      } finally {
        stream.free();
      }
    } catch (error) {
      throw EngineUnavailableException('sherpa-onnx transcription failed: $error');
    }
  }

  @override
  Future<VadPlan> planVad(TranscribeRequest request) => Future.error(
    const EngineUnavailableException(
      'sherpa-onnx VAD needs a separate Silero/ten-vad model file that this '
      'build does not ship; VAD is unavailable.',
    ),
  );

  @override
  Future<void> dispose() async {
    _recognizer?.free();
    _recognizer = null;
  }

  static String _sibling(String path, String name) {
    final index = path.lastIndexOf(RegExp(r'[\\/]'));
    return index < 0 ? name : '${path.substring(0, index + 1)}$name';
  }
}
