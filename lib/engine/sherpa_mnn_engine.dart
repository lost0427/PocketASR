/// Android-only sherpa-mnn SenseVoice engine.
///
/// The APK supplies the native engine, while the allowlisted model and tokens
/// remain runtime downloads. This adapter deliberately accepts only the one
/// model release whose bytes were converted and smoke-tested by this project.
library;

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart' as pkg_ffi;

import '../core/audio/wav.dart';
import 'asr_engine.dart';
import 'sherpa_mnn_bindings.dart';

const String sherpaMnnAndroidOnlyReason =
    'Sherpa-MNN is available only on Android in this release.';

const String sherpaMnnLibraryName = 'libsherpa-mnn-c-api.so';
const String sherpaMnnBundleId = 'model-sherpa-mnn-sensevoice-q8-v1';
const String sherpaMnnFamily = 'sensevoice';
const String sherpaMnnQuant = 'int8-weight-block64';
const int sherpaMnnModelSizeBytes = 266565508;
const String sherpaMnnModelSha256 =
    '28b954a62c9f8f8a9ccbe1079b1bb3b1d283fee0c84b311dadc7762cfcbe82bd';
const int sherpaMnnTokensSizeBytes = 315894;
const String sherpaMnnTokensSha256 =
    'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc';

const List<String> _requiredSymbols = [
  'SherpaMnnCreateOfflineRecognizer',
  'SherpaMnnDestroyOfflineRecognizer',
  'SherpaMnnCreateOfflineStream',
  'SherpaMnnDestroyOfflineStream',
  'SherpaMnnAcceptWaveformOffline',
  'SherpaMnnDecodeOfflineStream',
  'SherpaMnnGetOfflineStreamResult',
  'SherpaMnnDestroyOfflineRecognizerResult',
];

/// Immutable native recognizer options, kept narrow enough for deterministic
/// fake-API tests without exposing FFI pointers to the engine itself.
class SherpaMnnRecognizerOptions {
  const SherpaMnnRecognizerOptions({
    required this.modelPath,
    required this.tokensPath,
    required this.threads,
    this.language = 'auto',
    this.decodingMethod = 'greedy_search',
    this.provider = 'cpu',
  });

  final String modelPath;
  final String tokensPath;
  final int threads;
  final String language;
  final String decodingMethod;
  final String provider;
}

/// Narrow boundary around the eight C functions used by [SherpaMnnEngine].
///
/// Handles are opaque on purpose. Production casts them to generated FFI
/// pointer types, while tests use ordinary Dart objects and can verify every
/// lifecycle transition.
abstract interface class SherpaMnnApi {
  Object? createRecognizer(SherpaMnnRecognizerOptions options);

  void destroyRecognizer(Object recognizer);

  Object? createStream(Object recognizer);

  void destroyStream(Object stream);

  void acceptWaveform(Object stream, Float32List samples);

  void decode(Object recognizer, Object stream);

  Object? getResult(Object stream);

  String copyResultText(Object result);

  void destroyResult(Object result);
}

typedef SherpaMnnApiFactory = SherpaMnnApi Function(String libraryPath);
typedef SherpaMnnPlatformProbe = bool Function();
typedef SherpaMnnFileVerifier = Future<void> Function(
  String label,
  String path,
  int expectedSize,
  String expectedSha256,
);

/// Re-reads a file and verifies the exact identity pinned by the engine.
///
/// Size is checked on both sides of hashing so a concurrent replacement does
/// not silently turn a verified catalog claim into different native input.
Future<void> verifySherpaMnnFile(
  String label,
  String path,
  int expectedSize,
  String expectedSha256,
) async {
  if (path.trim().isEmpty) {
    throw EngineUnavailableException('Sherpa-MNN $label path is missing.');
  }
  final file = File(path);
  FileStat before;
  try {
    before = await file.stat();
  } catch (error) {
    throw EngineUnavailableException(
      'Sherpa-MNN $label file cannot be inspected at "$path": $error',
    );
  }
  if (before.type != FileSystemEntityType.file) {
    throw EngineUnavailableException(
      'Sherpa-MNN $label file is missing at "$path".',
    );
  }
  if (before.size != expectedSize) {
    throw EngineUnavailableException(
      'Sherpa-MNN $label size mismatch at "$path": expected '
      '$expectedSize bytes, found ${before.size}.',
    );
  }

  Digest digest;
  try {
    digest = await sha256.bind(file.openRead()).first;
  } catch (error) {
    throw EngineUnavailableException(
      'Sherpa-MNN $label file cannot be hashed at "$path": $error',
    );
  }
  final after = await file.stat();
  if (after.type != FileSystemEntityType.file ||
      after.size != before.size ||
      after.modified != before.modified) {
    throw EngineUnavailableException(
      'Sherpa-MNN $label file changed while it was being verified at "$path".',
    );
  }
  if (digest.toString() != expectedSha256) {
    throw EngineUnavailableException(
      'Sherpa-MNN $label SHA-256 mismatch at "$path": expected '
      '$expectedSha256, found $digest.',
    );
  }
}

/// [AsrEngine] backed by the pinned sherpa-mnn SenseVoice C API on Android.
class SherpaMnnEngine implements AsrEngine {
  SherpaMnnEngine({
    int threads = 4,
    String? libraryPath,
    SherpaMnnPlatformProbe? isAndroid,
    SherpaMnnApiFactory? apiFactory,
    SherpaMnnFileVerifier? fileVerifier,
  }) : threads = threads.clamp(1, 8),
       libraryPath = libraryPath ?? sherpaMnnLibraryName,
       _isAndroid = isAndroid ?? _defaultIsAndroid,
       _apiFactory = apiFactory ?? SherpaMnnNativeApi.open,
       _fileVerifier = fileVerifier ?? verifySherpaMnnFile;

  /// MNN's CPU worker count. It is kept positive and capped to avoid severe
  /// oversubscription on high-core-count mobile SoCs.
  final int threads;
  final String libraryPath;
  final SherpaMnnPlatformProbe _isAndroid;
  final SherpaMnnApiFactory _apiFactory;
  final SherpaMnnFileVerifier _fileVerifier;

  SherpaMnnApi? _api;
  String? _apiError;
  bool _apiInitialized = false;
  Object? _recognizer;
  bool _disposed = false;

  static bool _defaultIsAndroid() => Platform.isAndroid;

  @override
  String get id => 'sherpa-mnn';

  SherpaMnnApi? _ensureApi() {
    if (!_isAndroid()) {
      _apiError = sherpaMnnAndroidOnlyReason;
      return null;
    }
    if (_apiInitialized) return _api;
    _apiInitialized = true;
    try {
      _api = _apiFactory(libraryPath);
    } catch (error) {
      _apiError =
          'Sherpa-MNN native library "$libraryPath" is unavailable: $error';
    }
    return _api;
  }

  void _checkUsable() {
    if (_disposed) {
      throw const EngineUnavailableException(
        'Sherpa-MNN engine has been disposed.',
      );
    }
    if (!_isAndroid()) {
      throw const EngineUnavailableException(sherpaMnnAndroidOnlyReason);
    }
  }

  @override
  Future<List<Backend>> availableBackends() async {
    if (!_isAndroid()) return const [];
    return _ensureApi() == null ? const [] : const [Backend.cpu];
  }

  @override
  Future<EngineCapabilities> capabilities() async {
    if (!_isAndroid()) {
      return const EngineCapabilities.unavailable(sherpaMnnAndroidOnlyReason);
    }
    if (_ensureApi() == null) {
      return EngineCapabilities.unavailable(
        _apiError ?? 'Sherpa-MNN native library is unavailable.',
      );
    }
    return const EngineCapabilities(
      available: true,
      backends: {Backend.cpu},
      supportsVad: false,
    );
  }

  @override
  Future<void> load(EngineModelSpec spec, Backend backend) async {
    _checkUsable();
    if (backend != Backend.cpu) {
      throw EngineUnavailableException(
        'Sherpa-MNN runs CPU-only in this release; requested ${backend.name}.',
      );
    }

    _checkPinnedClaims(spec);
    await _fileVerifier(
      'model',
      spec.path,
      sherpaMnnModelSizeBytes,
      sherpaMnnModelSha256,
    );
    await _fileVerifier(
      'tokens',
      spec.tokensPath!,
      sherpaMnnTokensSizeBytes,
      sherpaMnnTokensSha256,
    );

    // Opening/resolving the library happens only after every model preflight.
    // The first actual C call is createRecognizer below.
    final api = _ensureApi();
    if (api == null) {
      throw EngineUnavailableException(
        _apiError ?? 'Sherpa-MNN native library is unavailable.',
      );
    }

    Object? replacement;
    try {
      replacement = api.createRecognizer(
        SherpaMnnRecognizerOptions(
          modelPath: spec.path,
          tokensPath: spec.tokensPath!,
          threads: threads,
        ),
      );
    } catch (error) {
      throw EngineUnavailableException(
        'Sherpa-MNN failed to load the pinned SenseVoice model: $error',
      );
    }
    if (replacement == null) {
      throw const EngineUnavailableException(
        'Sherpa-MNN native recognizer creation returned null.',
      );
    }

    final previous = _recognizer;
    _recognizer = replacement;
    if (previous != null) api.destroyRecognizer(previous);
  }

  void _checkPinnedClaims(EngineModelSpec spec) {
    void mismatch(String claim, Object? actual, Object expected) {
      if (actual != expected) {
        throw EngineUnavailableException(
          'Sherpa-MNN rejected model spec: $claim must be "$expected", '
          'found "${actual ?? 'null'}".',
        );
      }
    }

    mismatch('trusted bundle id', spec.trustedBundleId, sherpaMnnBundleId);
    mismatch('family', spec.family?.toLowerCase(), sherpaMnnFamily);
    mismatch('quantization', spec.quant?.toLowerCase(), sherpaMnnQuant);
    mismatch('model size', spec.modelSizeBytes, sherpaMnnModelSizeBytes);
    mismatch('model SHA-256', spec.modelSha256, sherpaMnnModelSha256);
    mismatch('tokens size', spec.tokensSizeBytes, sherpaMnnTokensSizeBytes);
    mismatch('tokens SHA-256', spec.tokensSha256, sherpaMnnTokensSha256);
    if (spec.path.trim().isEmpty) {
      throw const EngineUnavailableException(
        'Sherpa-MNN rejected model spec: model path is missing.',
      );
    }
    if (spec.tokensPath == null || spec.tokensPath!.trim().isEmpty) {
      throw const EngineUnavailableException(
        'Sherpa-MNN rejected model spec: tokens path is missing.',
      );
    }
  }

  @override
  Stream<TranscribeProgress> transcribe(TranscribeRequest request) async* {
    _checkUsable();
    final recognizer = _recognizer;
    final api = _api;
    if (recognizer == null || api == null) {
      throw const EngineUnavailableException(
        'Sherpa-MNN: no model loaded; call load() before transcribe().',
      );
    }
    if (request.backend != Backend.cpu) {
      throw EngineUnavailableException(
        'Sherpa-MNN runs CPU-only in this release; requested '
        '${request.backend.name}.',
      );
    }
    if (request.rawPcm) {
      throw const EngineUnavailableException(
        'Sherpa-MNN requires canonical mono 16000 Hz PCM16 WAV input.',
      );
    }

    // Parse and validate the complete canonical WAV before creating a native
    // stream. An offline stream must receive AcceptWaveform exactly once.
    final blocks = <Float32List>[];
    var sampleCount = 0;
    try {
      await for (final block in readCanonicalWave(request.audioPath)) {
        if (sampleCount > 0x7fffffff - block.length) {
          throw const FormatException(
            'WAV sample count exceeds sherpa-mnn int32 capacity',
          );
        }
        sampleCount += block.length;
        blocks.add(block);
      }
    } catch (error) {
      throw EngineUnavailableException(
        'Sherpa-MNN rejected audio "${request.audioPath}": $error',
      );
    }
    if (sampleCount == 0) {
      throw EngineUnavailableException(
        'Sherpa-MNN rejected empty audio "${request.audioPath}".',
      );
    }
    final samples = Float32List(sampleCount);
    var offset = 0;
    for (final block in blocks) {
      samples.setRange(offset, offset + block.length, block);
      offset += block.length;
    }

    final elapsed = Stopwatch()..start();
    Object? stream;
    Object? result;
    try {
      stream = api.createStream(recognizer);
      if (stream == null) {
        throw StateError('native stream creation returned null');
      }
      api.acceptWaveform(stream, samples);
      api.decode(recognizer, stream);
      result = api.getResult(stream);
      if (result == null) {
        throw StateError('native result retrieval returned null');
      }
      // Copy while result-owned UTF-8 memory is alive; the finally below can
      // then destroy native storage even if decoding the UTF-8 throws.
      final text = api.copyResultText(result);
      elapsed.stop();
      yield TranscribeProgress(
        elapsed: elapsed.elapsed,
        ratio: 1,
        partialText: text,
      );
    } catch (error) {
      throw EngineUnavailableException(
        'Sherpa-MNN transcription failed: $error',
      );
    } finally {
      if (result != null) api.destroyResult(result);
      if (stream != null) api.destroyStream(stream);
    }
  }

  @override
  Future<VadPlan> planVad(
    TranscribeRequest request,
    NeuralVadSettings vad,
  ) => Future.error(
    const EngineUnavailableException(
      'Sherpa-MNN has no neural VAD; supply a separate sherpa-onnx VAD engine.',
    ),
  );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final recognizer = _recognizer;
    _recognizer = null;
    if (recognizer != null) _api?.destroyRecognizer(recognizer);
  }
}

/// Production implementation of the narrow API using generated bindings.
class SherpaMnnNativeApi implements SherpaMnnApi {
  SherpaMnnNativeApi._(this._bindings);

  final SherpaMnnBindings _bindings;

  static SherpaMnnNativeApi open(String libraryPath) {
    final library = ffi.DynamicLibrary.open(libraryPath);
    for (final symbol in _requiredSymbols) {
      try {
        // Resolution only. The generated binding below retains the real ABI.
        library.lookup<ffi.NativeFunction<ffi.Void Function()>>(symbol);
      } catch (error) {
        throw StateError('missing required symbol "$symbol": $error');
      }
    }
    return SherpaMnnNativeApi._(SherpaMnnBindings(library));
  }

  @override
  Object? createRecognizer(SherpaMnnRecognizerOptions options) {
    final config = pkg_ffi.calloc<SherpaMnnOfflineRecognizerConfig>();
    final strings = <ffi.Pointer<pkg_ffi.Utf8>>[];
    ffi.Pointer<ffi.Char> nativeString(String value) {
      final pointer = value.toNativeUtf8();
      strings.add(pointer);
      return pointer.cast<ffi.Char>();
    }

    try {
      config.ref.feat_config.sample_rate = 16000;
      config.ref.feat_config.feature_dim = 80;
      config.ref.model_config.tokens = nativeString(options.tokensPath);
      config.ref.model_config.num_threads = options.threads;
      config.ref.model_config.debug = 0;
      config.ref.model_config.provider = nativeString(options.provider);
      config.ref.model_config.sense_voice.model = nativeString(
        options.modelPath,
      );
      config.ref.model_config.sense_voice.language = nativeString(
        options.language,
      );
      config.ref.model_config.sense_voice.use_itn = 1;
      config.ref.decoding_method = nativeString(options.decodingMethod);
      config.ref.max_active_paths = 4;

      final pointer = _bindings.SherpaMnnCreateOfflineRecognizer(config);
      return pointer == ffi.nullptr ? null : pointer;
    } finally {
      for (final pointer in strings.reversed) {
        pkg_ffi.calloc.free(pointer);
      }
      pkg_ffi.calloc.free(config);
    }
  }

  ffi.Pointer<SherpaMnnOfflineRecognizer> _recognizer(Object handle) =>
      handle as ffi.Pointer<SherpaMnnOfflineRecognizer>;

  ffi.Pointer<SherpaMnnOfflineStream> _stream(Object handle) =>
      handle as ffi.Pointer<SherpaMnnOfflineStream>;

  ffi.Pointer<SherpaMnnOfflineRecognizerResult> _result(Object handle) =>
      handle as ffi.Pointer<SherpaMnnOfflineRecognizerResult>;

  @override
  void destroyRecognizer(Object recognizer) =>
      _bindings.SherpaMnnDestroyOfflineRecognizer(_recognizer(recognizer));

  @override
  Object? createStream(Object recognizer) {
    final pointer = _bindings.SherpaMnnCreateOfflineStream(
      _recognizer(recognizer),
    );
    return pointer == ffi.nullptr ? null : pointer;
  }

  @override
  void destroyStream(Object stream) =>
      _bindings.SherpaMnnDestroyOfflineStream(_stream(stream));

  @override
  void acceptWaveform(Object stream, Float32List samples) {
    final pointer = pkg_ffi.calloc<ffi.Float>(samples.length);
    try {
      pointer.asTypedList(samples.length).setAll(0, samples);
      _bindings.SherpaMnnAcceptWaveformOffline(
        _stream(stream),
        16000,
        pointer,
        samples.length,
      );
    } finally {
      pkg_ffi.calloc.free(pointer);
    }
  }

  @override
  void decode(Object recognizer, Object stream) =>
      _bindings.SherpaMnnDecodeOfflineStream(
        _recognizer(recognizer),
        _stream(stream),
      );

  @override
  Object? getResult(Object stream) {
    final pointer = _bindings.SherpaMnnGetOfflineStreamResult(_stream(stream));
    return pointer == ffi.nullptr ? null : pointer;
  }

  @override
  String copyResultText(Object result) {
    final text = _result(result).ref.text;
    if (text == ffi.nullptr) {
      throw const FormatException('sherpa-mnn result text is null');
    }
    return text.cast<pkg_ffi.Utf8>().toDartString();
  }

  @override
  void destroyResult(Object result) =>
      _bindings.SherpaMnnDestroyOfflineRecognizerResult(_result(result));
}
