/// ASR engine domain layer — engine- and backend-agnostic (plan §2).
///
/// Only [UnavailableAsrEngine] ships today: the native CrispASR library is not
/// in the repo, so the app must surface "unavailable" rather than fake text.
/// A real `CrispAsrEngine` implements [AsrEngine] later without touching the UI
/// or the data layer — the interface is the single swap point (plan §2 / §10).
library;

/// Compute backend a model runs on.
///
/// [vulkan] and [npu] are declared so callers render them by variable instead
/// of hard-coding `cpu`, but the first release plumbs only [cpu] (decision
/// D17); the others stay unreachable until §10.
enum Backend { cpu, vulkan, npu }

/// Model to load into an engine.
///
/// The Phase 7 catalog produces these from `assets/model_allowlist.json` via
/// `LocalModelStore.specFor`; the engine layer only needs on-disk paths plus
/// labels for display. Multi-file engines (sherpa-onnx) read the companion
/// paths; single-file engines (CrispASR GGUF) use [path] alone.
class EngineModelSpec {
  const EngineModelSpec({
    required this.path,
    this.family,
    this.quant,
    this.tokensPath,
    this.encoderPath,
    this.decoderPath,
  }) : trustedBundleId = null,
       modelSizeBytes = null,
       modelSha256 = null,
       tokensSizeBytes = null,
       tokensSha256 = null;

  /// Creates a spec whose file identity came from the shipped model catalog.
  ///
  /// This is deliberately separate from the general-purpose constructor:
  /// hand-picked paths and test/client-created specs must stay untrusted. Only
  /// `LocalModelStore.specFor` maps catalog facts through this constructor.
  /// Native engines must still compare these facts with their own pinned
  /// allowlist expectations and verify the files before crossing FFI.
  factory EngineModelSpec.trustedCatalog({
    required String path,
    required String trustedBundleId,
    required int modelSizeBytes,
    required String modelSha256,
    String? family,
    String? quant,
    String? tokensPath,
    int? tokensSizeBytes,
    String? tokensSha256,
    String? encoderPath,
    String? decoderPath,
  }) {
    if (trustedBundleId.isEmpty) {
      throw ArgumentError.value(
        trustedBundleId,
        'trustedBundleId',
        'must not be empty',
      );
    }
    if (modelSizeBytes <= 0) {
      throw ArgumentError.value(
        modelSizeBytes,
        'modelSizeBytes',
        'must be positive',
      );
    }
    if (!_isSha256(modelSha256)) {
      throw ArgumentError.value(
        modelSha256,
        'modelSha256',
        'must be 64 hexadecimal characters',
      );
    }
    final hasTokensPath = tokensPath != null && tokensPath.isNotEmpty;
    if (hasTokensPath != (tokensSizeBytes != null) ||
        hasTokensPath != (tokensSha256 != null)) {
      throw ArgumentError(
        'tokensPath, tokensSizeBytes and tokensSha256 must be provided '
        'together',
      );
    }
    if (tokensSizeBytes != null && tokensSizeBytes <= 0) {
      throw ArgumentError.value(
        tokensSizeBytes,
        'tokensSizeBytes',
        'must be positive',
      );
    }
    if (tokensSha256 != null && !_isSha256(tokensSha256)) {
      throw ArgumentError.value(
        tokensSha256,
        'tokensSha256',
        'must be 64 hexadecimal characters',
      );
    }
    return EngineModelSpec._trustedCatalog(
      path: path,
      family: family,
      quant: quant,
      tokensPath: tokensPath,
      encoderPath: encoderPath,
      decoderPath: decoderPath,
      trustedBundleId: trustedBundleId,
      modelSizeBytes: modelSizeBytes,
      modelSha256: modelSha256.toLowerCase(),
      tokensSizeBytes: tokensSizeBytes,
      tokensSha256: tokensSha256?.toLowerCase(),
    );
  }

  const EngineModelSpec._trustedCatalog({
    required this.path,
    required this.trustedBundleId,
    required this.modelSizeBytes,
    required this.modelSha256,
    required this.family,
    required this.quant,
    required this.tokensPath,
    required this.tokensSizeBytes,
    required this.tokensSha256,
    required this.encoderPath,
    required this.decoderPath,
  });

  /// Filesystem path to the (primary) model weights.
  final String path;

  /// Served model family (`sensevoice`, `whisper`, ...), for labels/logs.
  final String? family;

  /// Quantization tag (`q8_0`, `q4_k`, ...), for labels/logs.
  final String? quant;

  /// Tokenizer file for engines that need one beside the model.
  final String? tokensPath;

  /// Encoder weights, for encoder/decoder models like whisper.
  final String? encoderPath;

  /// Decoder weights, for encoder/decoder models like whisper.
  final String? decoderPath;

  /// Stable allowlist bundle id, or null for a hand-picked/caller-built spec.
  final String? trustedBundleId;

  /// Exact catalog identity of the primary model file.
  final int? modelSizeBytes;
  final String? modelSha256;

  /// Exact catalog identity of the tokens companion, when the bundle has one.
  final int? tokensSizeBytes;
  final String? tokensSha256;
}

bool _isSha256(String value) =>
    value.length == 64 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);

/// What an engine can actually do right now.
///
/// Hardware probes can fail, so availability is a runtime fact rather than a
/// compile-time constant: when [available] is false, callers must not present
/// transcription as working and must not substitute placeholder text.
class EngineCapabilities {
  const EngineCapabilities({
    required this.available,
    this.backends = const {},
    this.supportsVad = false,
    this.unavailableReason,
  });

  /// Convenience for the "native library missing" case.
  const EngineCapabilities.unavailable(String reason)
    : this(available: false, unavailableReason: reason);

  final bool available;

  /// Backends this engine can actually use on this device.
  final Set<Backend> backends;

  /// True when [AsrEngine.planVad] can return real cut boundaries.
  final bool supportsVad;

  /// Human-readable why-not when [available] is false.
  final String? unavailableReason;
}

/// VAD architecture understood by sherpa-onnx's `VoiceActivityDetector`.
enum VadModelFamily { silero, ten }

/// Minimal config for a *real* neural VAD via sherpa-onnx's
/// `VoiceActivityDetector` — the knobs offline planning actually uses.
///
/// All durations are seconds on the 16 kHz mono timeline the app normalizes
/// to. [modelPath] must point at a supported VAD ONNX the user supplied (see
/// the `type: vad` entry in `assets/model_allowlist.json`); nothing here
/// fabricates a model or substitutes an energy gate.
class NeuralVadSettings {
  const NeuralVadSettings({
    required this.modelPath,
    this.family = VadModelFamily.silero,
    this.threshold = 0.5,
    this.minSilenceDuration = 0.5,
    this.minSpeechDuration = 0.25,
    this.speechPadMs = 30,
    this.maxSpeechSeconds = 30,
  });

  /// Local path of the selected VAD model file.
  final String modelPath;

  /// Model architecture; this controls the native config and input window.
  final VadModelFamily family;

  /// Speech-probability gate (exclusive 0..1) passed to the model.
  final double threshold;

  /// Trailing silence (seconds) required to close a segment.
  final double minSilenceDuration;

  /// Shortest speech the model emits, in seconds.
  final double minSpeechDuration;

  /// Each detected boundary grows outward by this many milliseconds, clamped
  /// to the audio; overlapping pads join into one boundary.
  final int speechPadMs;

  /// Ceiling on the *speech* total of one transcribable window; shorter
  /// segments merge until adding the next would pass it. Oversized spans are
  /// split, never truncated away.
  final double maxSpeechSeconds;

  /// Throws [ArgumentError] on values that could not drive a real detector,
  /// so callers fail before any IO. File existence is the engine's problem.
  void validate() {
    if (modelPath.trim().isEmpty) {
      throw ArgumentError.value(modelPath, 'modelPath', 'must not be empty');
    }
    if (!threshold.isFinite || threshold <= 0 || threshold >= 1) {
      throw ArgumentError.value(
        threshold,
        'threshold',
        'must be finite and inside (0, 1)',
      );
    }
    if (!minSilenceDuration.isFinite || minSilenceDuration < 0) {
      throw ArgumentError.value(
        minSilenceDuration,
        'minSilenceDuration',
        'must be finite and >= 0',
      );
    }
    if (!minSpeechDuration.isFinite || minSpeechDuration < 0) {
      throw ArgumentError.value(
        minSpeechDuration,
        'minSpeechDuration',
        'must be finite and >= 0',
      );
    }
    if (speechPadMs < 0) {
      throw ArgumentError.value(speechPadMs, 'speechPadMs', 'must be >= 0');
    }
    if (!maxSpeechSeconds.isFinite || maxSpeechSeconds <= 0) {
      throw ArgumentError.value(
        maxSpeechSeconds,
        'maxSpeechSeconds',
        'must be finite and > 0',
      );
    }
  }
}

/// One detected speech region, in audio-timeline coordinates.
class VadSegment {
  const VadSegment({required this.start, required this.end});

  final Duration start;
  final Duration end;

  Duration get duration => end - start;
}

/// VAD cut boundaries only.
///
/// [AsrEngine.planVad] produces this *without* running ASR (they are separate
/// engine paths, plan §1.2), which is what makes Phase 5's live preview cheap.
class VadPlan {
  const VadPlan(this.segments);

  const VadPlan.empty() : segments = const [];

  final List<VadSegment> segments;

  bool get isEmpty => segments.isEmpty;

  Duration get speechDuration =>
      segments.fold(Duration.zero, (total, s) => total + s.duration);
}

/// One offline transcription request.
class TranscribeRequest {
  const TranscribeRequest({
    required this.audioPath,
    this.backend = Backend.cpu,
    this.language,
    this.vadPlan,
    this.rawPcm = false,
  });

  /// Decoded, loudness-normalized audio file on disk.
  final String audioPath;

  final Backend backend;

  /// Language tag (`zh`, `en`, ...); null means engine auto-detect.
  final String? language;

  /// Cut boundaries previously produced by [AsrEngine.planVad], if any.
  final VadPlan? vadPlan;

  /// True when [audioPath] is raw mono 16 kHz little-endian float32 PCM rather
  /// than a WAV. [AsrEngine.planVad] reads it directly, so a neural-VAD job
  /// does not have to materialize a second whole-file WAV copy.
  final bool rawPcm;
}

/// A progress update emitted while [AsrEngine.transcribe] runs.
class TranscribeProgress {
  const TranscribeProgress({
    required this.elapsed,
    this.ratio = -1,
    this.partialText = '',
    this.completedChunkText,
    this.completedChunkElapsed,
  });

  /// Wall-clock time since transcription started.
  final Duration elapsed;

  /// 0..1, or -1 when the engine cannot report progress.
  final double ratio;

  /// Text decoded so far; empty until the engine emits partials.
  final String partialText;

  /// Text and inference time for the most recently completed chunk.
  ///
  /// Engines leave these null. The transcription service fills them only on
  /// the final progress event for a chunk so the UI can show that chunk's
  /// character rate while the next chunk is running.
  final String? completedChunkText;
  final Duration? completedChunkElapsed;
}

/// The single swap point for ASR engines (plan §2).
///
/// One implementation (`CrispAsrEngine`) is planned; keeping the interface
/// lets §10 add sherpa-onnx as a new implementation rather than a rewrite.
abstract class AsrEngine {
  /// Stable engine id, e.g. `crispasr`.
  String get id;

  /// Backends usable on this device. Empty when the engine cannot run.
  Future<List<Backend>> availableBackends();

  /// Runtime capabilities, including availability and reason.
  Future<EngineCapabilities> capabilities();

  /// Loads [spec] onto [backend], reusing the loaded session across requests.
  Future<void> load(EngineModelSpec spec, Backend backend);

  /// Runs transcription, emitting progress until the stream completes.
  Stream<TranscribeProgress> transcribe(TranscribeRequest request);

  /// Returns cut boundaries only — does not run ASR and needs no model
  /// [load]: the neural VAD is a separate model ([NeuralVadSettings.modelPath])
  /// and code path, which is what makes the live preview cheap (§1.2).
  Future<VadPlan> planVad(
    TranscribeRequest request,
    NeuralVadSettings vad,
  );

  /// Releases native resources.
  Future<void> dispose();
}

/// Raised when a running job was cancelled by request.
///
/// Cancellation is an error, never an empty success: a cancelled job produced
/// no trustworthy result and callers must not persist one.
class EngineCancelledException implements Exception {
  const EngineCancelledException(this.message);

  final String message;

  @override
  String toString() => 'EngineCancelledException: $message';
}

/// Optional [AsrEngine] capability: abort the current job cooperatively.
///
/// Engines that run native code cannot safely hard-kill a call in flight, so
/// [cancel] stops *subsequent* work immediately and makes the in-flight call
/// surface [EngineCancelledException] once the native operation returns.
/// Callers must treat that window ("cancelled" is not "stopped instantly") as
/// expected latency, not a bug.
abstract interface class CancellableAsrEngine implements AsrEngine {
  /// Requests cancellation of the current job. Idempotent.
  Future<void> cancel();
}

/// Raised whenever an operation needs the missing native library.
///
/// Deliberately an error rather than an empty result: a caller that forgets to
/// handle it must crash loudly, never persist an empty transcript.
class EngineUnavailableException implements Exception {
  const EngineUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'EngineUnavailableException: $message';
}

/// Stand-in [AsrEngine] for builds without the native CrispASR library.
///
/// Reports [EngineCapabilities.unavailable] and fails every operation with a
/// clear [EngineUnavailableException]. It never emits partial text or a fake
/// result. Replace with `CrispAsrEngine` once the `.so` is bundled.
class UnavailableAsrEngine implements AsrEngine {
  const UnavailableAsrEngine({
    this.reason =
        'Native CrispASR library is not bundled; transcription is unavailable.',
  });

  final String reason;

  @override
  String get id => 'unavailable';

  @override
  Future<List<Backend>> availableBackends() async => const [];

  @override
  Future<EngineCapabilities> capabilities() async =>
      EngineCapabilities.unavailable(reason);

  @override
  Future<void> load(EngineModelSpec spec, Backend backend) =>
      Future.error(EngineUnavailableException(reason));

  @override
  Stream<TranscribeProgress> transcribe(TranscribeRequest request) =>
      Stream.error(EngineUnavailableException(reason));

  @override
  Future<VadPlan> planVad(
    TranscribeRequest request,
    NeuralVadSettings vad,
  ) => Future.error(EngineUnavailableException(reason));

  @override
  Future<void> dispose() async {}
}
