/// Native sherpa-onnx [AsrEngine] adapter (plan §2 / §10).
///
/// Wraps `package:sherpa_onnx`'s offline recognizer. Unlike CrispASR, the
/// sherpa-onnx Flutter plugin bundles its own native libraries (Windows `.dll`s
/// and per-ABI Android packages), so this adapter can be genuinely available
/// once the plugin builds. It runs CPU-only here; native init/load/transcribe
/// failures always surface as [EngineUnavailableException].
library;

import '../core/audio/wav.dart';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'asr_engine.dart';

/// [AsrEngine] backed by sherpa-onnx's `OfflineRecognizer`.
///
/// sherpa-onnx models are multi-file (e.g. whisper needs an encoder + decoder,
/// and every family needs a tokens file). A catalog bundle spec carries those
/// companions as [EngineModelSpec.tokensPath]/[encoderPath]/[decoderPath] and
/// this adapter reads them; the constructor params override the spec for
/// callers that stage files by hand. A missing file fails `load` with a clear
/// message rather than guessing.
class SherpaEngine implements AsrEngine {
  SherpaEngine({
    this.tokensPath,
    this.encoderPath,
    this.decoderPath,
    this.threads = 4,
    this.libraryPath,
  });

  /// Path to the tokens file; overrides the bundle spec's `tokensPath`.
  final String? tokensPath;

  /// Whisper encoder ONNX; overrides the bundle spec's `encoderPath`.
  final String? encoderPath;

  /// Whisper decoder ONNX; overrides the bundle spec's `decoderPath`.
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
      // The bindings expose the real Silero VoiceActivityDetector; the model
      // file itself arrives per call in NeuralVadSettings. planVad still
      // fails loudly when that file is missing or unreadable.
      supportsVad: true,
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
    // Precedence: explicit constructor override > bundle spec > sibling file.
    final tokens =
        tokensPath ?? spec.tokensPath ?? _sibling(spec.path, 'tokens.txt');

    switch (family) {
      case 'whisper':
        final decoder = decoderPath ?? spec.decoderPath;
        if (decoder == null || decoder.isEmpty) {
          throw const EngineUnavailableException(
            'sherpa-onnx whisper needs both an encoder and a decoder ONNX; '
            'load a bundle spec with a decoder file, or pass decoderPath.',
          );
        }
        return sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: encoderPath ?? spec.encoderPath ?? spec.path,
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
        );
      } finally {
        stream.free();
      }
    } catch (error) {
      throw EngineUnavailableException('sherpa-onnx transcription failed: $error');
    }
  }

  /// Silero VAD's fixed window at 16 kHz; [acceptWaveform] is fed exactly
  /// this many samples at a time and the buffer drained after each window.
  static const int _vadWindow = 512;

  /// Runs the real Silero `VoiceActivityDetector` over the WAV at
  /// [TranscribeRequest.audioPath]. No ASR model is loaded and none is run:
  /// the detector only needs its own ONNX plus the caller's [NeuralVadSettings].
  /// Segments are drained as they complete, trailing speech is flushed, and
  /// the native detector is always freed.
  @override
  Future<VadPlan> planVad(
    TranscribeRequest request,
    NeuralVadSettings vad,
  ) async {
    vad.validate();
    _ensureInitialized();
    if (_initError != null) throw EngineUnavailableException(_initError!);

    const sampleRate = 16000;

    final sherpa.VoiceActivityDetector detector;
    try {
      detector = sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: vad.modelPath,
            threshold: vad.threshold,
            minSilenceDuration: vad.minSilenceDuration,
            minSpeechDuration: vad.minSpeechDuration,
            windowSize: _vadWindow,
            maxSpeechDuration: vad.maxSpeechSeconds,
          ),
          sampleRate: sampleRate,
          numThreads: 1,
          provider: 'cpu',
          debug: false,
        ),
        // Drained every window, so it only ever holds one speech run plus pad.
        bufferSizeInSeconds:
            vad.maxSpeechSeconds + vad.speechPadMs / 1000 + 1,
      );
    } catch (error) {
      throw EngineUnavailableException(
        'sherpa-onnx failed to load VAD model "${vad.modelPath}": $error',
      );
    }
    final segments = <VadSegment>[];
    void drain() {
      while (!detector.isEmpty()) {
        final speech = detector.front();
        final startSample = speech.start;
        final length = speech.samples.length;
        detector.pop();
        if (length <= 0) continue;
        segments.add(
          VadSegment(
            start: _durationFromSample(startSample, sampleRate),
            end: _durationFromSample(startSample + length, sampleRate),
          ),
        );
      }
    }

    try {
      await for (final samples in readCanonicalWave(request.audioPath, blockSize: _vadWindow)) {
        detector.acceptWaveform(samples);
        drain();
      }
      detector.flush();
      drain();
    } on EngineUnavailableException {
      rethrow;
    } catch (error) {
      throw EngineUnavailableException('sherpa-onnx VAD failed: $error');
    } finally {
      detector.free();
    }
    return VadPlan(segments);
  }

  static Duration _durationFromSample(int sample, int rate) =>
      Duration(microseconds: (sample * 1000000 / rate).round());

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
