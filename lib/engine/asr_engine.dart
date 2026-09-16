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
}

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
    this.supportsTokenCount = false,
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

  /// True when progress/result carry real tokenizer token counts. When false,
  /// metrics show `—` instead of inventing a tokens/s figure (plan Phase 6).
  final bool supportsTokenCount;

  /// Human-readable why-not when [available] is false.
  final String? unavailableReason;
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
  });

  /// Decoded, loudness-normalized audio file on disk.
  final String audioPath;

  final Backend backend;

  /// Language tag (`zh`, `en`, ...); null means engine auto-detect.
  final String? language;

  /// Cut boundaries previously produced by [AsrEngine.planVad], if any.
  final VadPlan? vadPlan;
}

/// A progress update emitted while [AsrEngine.transcribe] runs.
class TranscribeProgress {
  const TranscribeProgress({
    required this.elapsed,
    this.ratio = -1,
    this.partialText = '',
    this.tokens,
  });

  /// Wall-clock time since transcription started.
  final Duration elapsed;

  /// 0..1, or -1 when the engine cannot report progress.
  final double ratio;

  /// Text decoded so far; empty until the engine emits partials.
  final String partialText;

  /// Real tokenizer count so far, or null when unsupported/not counted yet.
  final int? tokens;
}

/// The finished output of one transcription.
class TranscriptionResult {
  const TranscriptionResult({
    required this.text,
    required this.elapsed,
    this.audioDuration,
    this.tokens,
  });

  final String text;

  /// Total wall-clock time spent.
  final Duration elapsed;

  /// Input audio length; null when the caller did not measure it.
  final Duration? audioDuration;

  /// Real tokenizer token count, or null when the engine cannot report one.
  final int? tokens;

  bool get isEmpty => text.isEmpty;

  /// Real-time factor = processing time / audio time; null when unknown.
  double? get rtf {
    final audioMs = audioDuration?.inMilliseconds;
    if (audioMs == null || audioMs <= 0) return null;
    return elapsed.inMilliseconds / audioMs;
  }
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

  /// Returns cut boundaries only — does not run ASR.
  Future<VadPlan> planVad(TranscribeRequest request);

  /// Releases native resources.
  Future<void> dispose();
}

/// Raised whenever an operation needs the missing native library.
///
/// Deliberately an error and not an empty [TranscriptionResult]: a caller that
/// forgets to handle it must crash loudly, never persist an empty transcript.
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
  Future<VadPlan> planVad(TranscribeRequest request) =>
      Future.error(EngineUnavailableException(reason));

  @override
  Future<void> dispose() async {}
}
