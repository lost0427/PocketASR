import 'dart:io';
import 'dart:math' as math;

import '../../core/audio/audio_preprocessor.dart';
import '../../core/audio/audio_source.dart';
import '../../core/audio/chunk_planner.dart';
import '../../core/audio/pcm_file.dart';
import '../../core/audio/loudness.dart';
import '../../engine/asr_engine.dart';
import 'transcription_stage.dart';

export 'transcription_stage.dart';

class TranscriptionJobResult {
  const TranscriptionJobResult({
    required this.text,
    required this.elapsed,
    required this.audioDuration,
    required this.engine,
    required this.model,
    required this.backend,
    required this.originalLufs,
    required this.gainDb,
  });

  final String text;
  final Duration elapsed;
  final Duration audioDuration;
  final String engine;
  final EngineModelSpec model;
  final Backend backend;
  final double originalLufs;
  final double gainDb;

  double? get rtf => audioDuration.inMicroseconds == 0
      ? null
      : elapsed.inMicroseconds / audioDuration.inMicroseconds;
}

/// What [TranscriptionService.previewVad] returns: the real neural-VAD
/// windows a `neuralVad` job would transcribe for the same audio, *before*
/// any ASR model is loaded.
class VadPreview {
  const VadPreview({required this.windows, required this.sampleRate});

  /// Transcribable windows in ascending order; each window is one or more
  /// padded real speech boundaries on the audio timeline. The engine PCM for
  /// a window is the concatenation of its spans — gaps between spans are
  /// silence and are never transcribed.
  final List<List<AudioChunk>> windows;

  /// Sample rate of the decoded + normalized audio the times refer to.
  final int sampleRate;

  bool get isEmpty => windows.isEmpty;

  /// Total speech the job would send: summed span durations, not spans-to-EOF.
  Duration get speechDuration => windows
      .expand((window) => window)
      .fold(Duration.zero, (total, span) => total + span.duration);
}

class TranscriptionService {
  TranscriptionService({
    required this.engine,
    this.vadEngine,
    this._source = const FileAudioSource(),
    this._preprocessor = const AudioPreprocessor(),
  });

  final AsrEngine engine;

  /// Engine that runs [AsrEngine.planVad] for `neuralVad` jobs and
  /// [previewVad]; defaults to [engine]. Pass a separate sherpa-onnx worker
  /// (e.g. `WorkerAsrEngine.sherpa()`) when [engine] is CrispASR, so neural
  /// VAD is not bound to one ASR engine. The caller owns its disposal.
  final AsrEngine? vadEngine;
  final AudioSource _source;
  final AudioPreprocessor _preprocessor;

  Future<PcmFile> _decode(String path, Directory dir, bool Function()? cancelled) async {
    final source = _source;
    if (source is FileAudioSource) {
      return source.decodeToDisk(path, dir, isCancelled: cancelled);
    }
    // Injected sources used by tests already own their small in-memory input.
    return PcmFile.fromBuffer(await source.read(path), '${dir.path}/decoded.f32');
  }

  Future<({double lufs, double gainDb})> _measure(PcmFile audio, bool Function()? cancelled) =>
      _preprocessor.enabled
          ? LoudnessNormalizer(targetLufs: _preprocessor.targetLufs).measureFile(audio, isCancelled: cancelled)
          : Future.value((lufs: double.nan, gainDb: 0.0));

  /// Runs one file through [engine].
  ///
  /// When [chunkSettings] is given, the normalized PCM is sliced per
  /// [ChunkPlanner] plan and each block is sent as its own engine request:
  /// the model is loaded once, blocks run sequentially, and text, engine-
  /// reported elapsed time is aggregated, while [onProgress]
  /// receives the running aggregate (global ratio over planned audio).
  /// Chunk overlap ([ChunkSettings.overlapSeconds] > 0) duplicates boundary
  /// text on purpose or not at all: no deduplication is implemented here, so
  /// the default is 0.
  ///
  /// Leaving [chunkSettings] null uses default 30-second windows.
  /// [onProgress] is optional and never changes
  /// the returned result. A failing or silent engine throws
  /// [EngineUnavailableException]; no placeholder text is ever returned.
  ///
  /// [neuralVad] (mutually exclusive with [chunkSettings]) cuts on *real*
  /// neural VAD instead: the (possibly separate) `vadEngine` detects speech
  /// on the same normalized audio via [AsrEngine.planVad] — without an ASR
  /// load — and short segments are merged into ≤ max-speech windows whose
  /// span PCM is concatenated per request (silence between spans is never
  /// transcribed). A VAD plan with no speech throws like the energy gate
  /// does; nothing is faked.
  ///
  /// [isCancelled] is polled before each chunk and re-polled after every
  /// awaited native call completes (VAD planning, the final chunk result):
  /// when it turns true, the job throws
  /// [EngineCancelledException] at the next boundary instead of returning a
  /// partial success. In-flight native work cannot be hard-killed,
  /// so cancellation is cooperative and takes effect between chunks — pair it
  /// with [CancellableAsrEngine.cancel] so the engine refuses later chunks
  /// even without this poll. The temp directory is cleaned in `finally` on
  /// every exit path, cancellation included.
  Future<TranscriptionJobResult> transcribe({
    required String audioPath,
    required EngineModelSpec model,
    Backend backend = Backend.cpu,
    String? language,
    ChunkSettings? chunkSettings,
    NeuralVadSettings? neuralVad,
    void Function(TranscriptionStage stage)? onStage,
    void Function(TranscribeProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (neuralVad != null && chunkSettings != null) {
      throw ArgumentError(
        'chunkSettings (fixed/energy) and neuralVad (real VAD) are '
        'alternatives; pass one, not both.',
      );
    }
    neuralVad?.validate(); // fail before any IO, like planner validation
    chunkSettings?.validate();
    final dir = await Directory.systemTemp.createTemp('pocket_asr_');
    try {
    onStage?.call(TranscriptionStage.decoding);
    final audio = await _decode(audioPath, dir, isCancelled);
    onStage?.call(TranscriptionStage.analyzing);
    final measured = await _measure(audio, isCancelled);
    final gain = math.pow(10, measured.gainDb / 20).toDouble();
    List<List<AudioChunk>> windows = const [];
    onStage?.call(TranscriptionStage.segmenting);
    if (neuralVad == null) {
      // Fixed/energy windows are planned before the temp dir exists, so an
      // invalid or speechless plan leaves no debris.
      final chunks = chunkSettings == null
          ? await const ChunkPlanner().planFile(audio, gain: gain, isCancelled: isCancelled)
          : await ChunkPlanner(settings: chunkSettings).planFile(audio, gain: gain, isCancelled: isCancelled);
      if (chunks.isEmpty) {
        throw const EngineUnavailableException(
          'Chunk planner found no speech to transcribe (energy gate, not a '
          'neural VAD); nothing was sent to the engine.',
        );
      }
      windows = [for (final chunk in chunks) <AudioChunk>[chunk]];
    }
    // One directory for the whole job; every chunk WAV lives in it and the
    // directory itself (not just the files) is removed in `finally`, on
    // success and on failure alike.
      if (neuralVad != null) {
        // Real VAD needs a file for the (worker) engine; plan first, so the
        // ASR model is only loaded once there is known speech to send.
        windows = await _planNeuralWindows(
          audio: audio,
          gain: gain,
          vad: neuralVad,
          dir: dir,
          isCancelled: isCancelled,
        );
        if (windows.isEmpty) {
          throw const EngineUnavailableException(
            'Neural VAD found no speech to transcribe; nothing was sent to '
            'the engine.',
          );
        }
      }
      if (isCancelled?.call() ?? false) {
        throw const EngineCancelledException('Cancelled before loading the ASR model.');
      }
      onStage?.call(TranscriptionStage.loadingModel);
      await engine.load(model, backend);
      final totalUs = windows.fold<int>(
        0,
        (sum, window) => sum + _windowSpeechUs(window),
      );
      final parts = <String>[];
      var doneUs = 0;
      var elapsed = Duration.zero;
      onStage?.call(TranscriptionStage.transcribing);
      for (var i = 0; i < windows.length; i++) {
        if (isCancelled?.call() ?? false) {
          throw EngineCancelledException(
            'Cancelled before chunk ${i + 1} of ${windows.length}; '
            '${parts.length} chunk(s) were transcribed but discarded — '
            'a cancelled job returns no text.',
          );
        }
        final window = windows[i];
        final chunkUs = math.max(1, _windowSpeechUs(window));
        final file = File('${dir.path}${Platform.pathSeparator}chunk$i.wav');
        await audio.writeWave(file, spans: window, gain: gain, isCancelled: isCancelled);
        TranscribeProgress? last;
        await for (final progress in engine.transcribe(
          TranscribeRequest(
            audioPath: file.path,
            backend: backend,
            language: language,
          ),
        )) {
          last = progress;
          if (onProgress != null) {
            final aggregated = TranscribeProgress(
              elapsed: elapsed + progress.elapsed,
              ratio: progress.ratio < 0
                  ? -1
                  : (doneUs + progress.ratio * chunkUs) / math.max(1, totalUs),
              partialText: <String>[...parts, progress.partialText]
                  .join(' ')
                  .trim(),
              completedChunkText: progress.ratio >= 1
                  ? progress.partialText.trim()
                  : null,
              completedChunkElapsed: progress.ratio >= 1
                  ? progress.elapsed
                  : null,
            );
            onProgress.call(aggregated);
          }
        }
        final result = last;
        if (result == null || result.partialText.trim().isEmpty) {
          throw const EngineUnavailableException('ASR returned no transcript');
        }
        parts.add(result.partialText.trim());
        elapsed += result.elapsed;
        doneUs += chunkUs;
        await file.delete();
      }
      if (isCancelled?.call() ?? false) {
        // Cancel can land while the *final* native call drains — the loop
        // top never runs again, so this is the last gate before "success".
        throw EngineCancelledException(
          'Cancelled during the final chunk; ${parts.length} chunk(s) were '
          'transcribed but discarded — a cancelled job returns no text.',
        );
      }
      onStage?.call(TranscriptionStage.finalizing);
      return TranscriptionJobResult(
        text: parts.join(' ').trim(),
        elapsed: elapsed,
        audioDuration: audio.duration,
        engine: engine.id,
        model: model,
        backend: backend,
        originalLufs: measured.lufs,
        gainDb: measured.gainDb,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  }

  /// Runs real neural VAD ([AsrEngine.planVad], no ASR load) over [audio] and
  /// returns grouped windows; throws [EngineCancelledException] before the
  /// single planning call if the job was already cancelled. The VAD input WAV
  /// is removed as soon as planning returns, whatever the outcome.
  Future<List<List<AudioChunk>>> _planNeuralWindows({
    required PcmFile audio,
    required double gain,
    required NeuralVadSettings vad,
    required Directory dir,
    required bool Function()? isCancelled,
  }) async {
    if (isCancelled?.call() ?? false) {
      throw const EngineCancelledException(
        'Cancelled before neural VAD planning; nothing was sent to any '
        'engine.',
      );
    }
    final file = File('${dir.path}${Platform.pathSeparator}vad_input.wav');
    await audio.writeWave(file, gain: gain, isCancelled: isCancelled);
    final VadPlan plan;
    try {
      plan = await (vadEngine ?? engine).planVad(
        TranscribeRequest(audioPath: file.path),
        vad,
      );
    } finally {
      await file.delete();
    }
    return ChunkPlanner.groupVad(
      segments: [
        for (final segment in plan.segments)
          AudioChunk(start: segment.start, end: segment.end),
      ],
      sampleRate: audio.sampleRate,
      sampleCount: audio.count,
      speechPadMs: vad.speechPadMs,
      maxSpeechSeconds: vad.maxSpeechSeconds,
    );
  }

  /// Speech (not span) length of a window in microseconds.
  static int _windowSpeechUs(List<AudioChunk> window) => window.fold(
    0,
    (sum, span) => sum + span.duration.inMicroseconds,
  );

  /// Real neural-VAD boundaries for [audioPath] without touching the ASR
  /// engine at all — no [AsrEngine.load], no transcribe call.
  ///
  /// Same decode + loudness normalization + VAD + grouping as the
  /// [transcribe] `neuralVad` path, so the returned windows are exactly the
  /// ones a job would use. Silent audio throws [EngineUnavailableException]
  /// rather than previewing an empty success. The VAD engine is not disposed
  /// here; the caller owns it.
  Future<VadPreview> previewVad({
    required String audioPath,
    required NeuralVadSettings neuralVad,
    bool Function()? isCancelled,
  }) async {
    neuralVad.validate();
    final dir = await Directory.systemTemp.createTemp('pocket_asr_vad_');
    try {
      final audio = await _decode(audioPath, dir, isCancelled);
      final measured = await _measure(audio, isCancelled);
      final windows = await _planNeuralWindows(
        audio: audio,
        gain: math.pow(10, measured.gainDb / 20).toDouble(),
        vad: neuralVad,
        dir: dir,
        isCancelled: isCancelled,
      );
      if (isCancelled?.call() ?? false) {
        // Cancelled mid-planning: the preview must not come back as a
        // success the user asked to abort; the `finally` still cleans the dir.
        throw const EngineCancelledException(
          'Cancelled during neural VAD planning; the preview was discarded.',
        );
      }
      if (windows.isEmpty) {
        throw const EngineUnavailableException(
          'Neural VAD found no speech in this audio; nothing to preview.',
        );
      }
      return VadPreview(windows: windows, sampleRate: audio.sampleRate);
    } finally {
      await dir.delete(recursive: true);
    }
  }
}
