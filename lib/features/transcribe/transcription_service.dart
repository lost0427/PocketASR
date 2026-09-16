import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/audio/audio_buffer.dart';
import '../../core/audio/audio_preprocessor.dart';
import '../../core/audio/audio_source.dart';
import '../../core/audio/chunk_planner.dart';
import '../../core/audio/wav.dart';
import '../../engine/asr_engine.dart';

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
    this.tokens,
  });

  final String text;
  final Duration elapsed;
  final Duration audioDuration;
  final String engine;
  final EngineModelSpec model;
  final Backend backend;
  final double originalLufs;
  final double gainDb;
  final int? tokens;

  double? get rtf => audioDuration.inMicroseconds == 0
      ? null
      : elapsed.inMicroseconds / audioDuration.inMicroseconds;

  double? get avgTokensPerSec => tokens == null || elapsed.inMicroseconds == 0
      ? null
      : tokens! * 1000000 / elapsed.inMicroseconds;
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

  /// Runs one file through [engine].
  ///
  /// When [chunkSettings] is given, the normalized PCM is sliced per
  /// [ChunkPlanner] plan and each block is sent as its own engine request:
  /// the model is loaded once, blocks run sequentially, and text, engine-
  /// reported elapsed time and tokens are aggregated, while [onProgress]
  /// receives the running aggregate (global ratio over planned audio).
  /// Unknown token counts stay null — nothing is estimated. Chunk overlap
  /// ([ChunkSettings.overlapSeconds] > 0) duplicates boundary text on purpose
  /// or not at all: no deduplication is implemented here, so the default is 0.
  ///
  /// Leaving [chunkSettings] null keeps the historic behavior: exactly one
  /// request with the whole file. [onProgress] is optional and never changes
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
    final sourceAudio = await _source.read(audioPath);
    final processed = await _preprocessor.processAsync(sourceAudio);
    final audio = processed.audio;
    List<List<AudioChunk>> windows = const [];
    if (neuralVad == null) {
      // Fixed/energy windows are planned before the temp dir exists, so an
      // invalid or speechless plan leaves no debris.
      final chunks = chunkSettings == null
          ? [AudioChunk(start: Duration.zero, end: audio.duration)]
          : ChunkPlanner(settings: chunkSettings).plan(audio);
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
    final dir = await Directory.systemTemp.createTemp('pocket_asr_');
    try {
      if (neuralVad != null) {
        // Real VAD needs a file for the (worker) engine; plan first, so the
        // ASR model is only loaded once there is known speech to send.
        windows = await _planNeuralWindows(
          audio: audio,
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
      await engine.load(model, backend);
      final totalUs = windows.fold<int>(
        0,
        (sum, window) => sum + _windowSpeechUs(window),
      );
      final parts = <String>[];
      var doneUs = 0;
      var elapsed = Duration.zero;
      int? tokensSoFar = 0;
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
        final slice = _windowPcm(window, audio);
        final file = File('${dir.path}${Platform.pathSeparator}chunk$i.wav');
        await file.writeAsBytes(encodePcm16Wav(slice, audio.sampleRate));
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
              tokens: tokensSoFar == null || progress.tokens == null
                  ? null
                  : tokensSoFar + progress.tokens!,
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
        if (result.tokens == null) {
          tokensSoFar = null;
        } else if (tokensSoFar != null) {
          // result.tokens is the engine's cumulative count *within* this
          // chunk, so add it once, at chunk end.
          tokensSoFar += result.tokens!;
        }
        doneUs += chunkUs;
      }
      if (isCancelled?.call() ?? false) {
        // Cancel can land while the *final* native call drains — the loop
        // top never runs again, so this is the last gate before "success".
        throw EngineCancelledException(
          'Cancelled during the final chunk; ${parts.length} chunk(s) were '
          'transcribed but discarded — a cancelled job returns no text.',
        );
      }
      return TranscriptionJobResult(
        text: parts.join(' ').trim(),
        elapsed: elapsed,
        audioDuration: audio.duration,
        engine: engine.id,
        model: model,
        backend: backend,
        originalLufs: processed.originalLufs,
        gainDb: processed.gainDb,
        tokens: tokensSoFar,
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
    required AudioBuffer audio,
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
    await file.writeAsBytes(encodePcm16Wav(audio.samples, audio.sampleRate));
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
      audio: audio,
      speechPadMs: vad.speechPadMs,
      maxSpeechSeconds: vad.maxSpeechSeconds,
    );
  }

  /// Speech (not span) length of a window in microseconds.
  static int _windowSpeechUs(List<AudioChunk> window) => window.fold(
    0,
    (sum, span) => sum + span.duration.inMicroseconds,
  );

  /// The window's PCM: span slices concatenated, so the silence between
  /// spans is never sent — a first-to-last slice would smuggle it back in.
  static Float32List _windowPcm(List<AudioChunk> window, AudioBuffer audio) {
    final rate = audio.sampleRate;
    if (window.length == 1) {
      final span = window.single;
      return Float32List.sublistView(
        audio.samples,
        span.startSampleAt(rate),
        span.endSampleAt(rate),
      );
    }
    // Allocate by the summed sample counts themselves: converting speech
    // microseconds through the sample rate floors per-span rounding errors
    // and under-allocates (RangeError) for odd boundaries.
    final bounds = [
      for (final span in window)
        (span.startSampleAt(rate), span.endSampleAt(rate)),
    ];
    final out = Float32List(
      bounds.fold(0, (int total, (int, int) b) => total + b.$2 - b.$1),
    );
    var at = 0;
    for (final (start, end) in bounds) {
      out.setRange(at, at + end - start, audio.samples, start);
      at += end - start;
    }
    return out;
  }

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
    final sourceAudio = await _source.read(audioPath);
    final processed = await _preprocessor.processAsync(sourceAudio);
    final audio = processed.audio;
    final dir = await Directory.systemTemp.createTemp('pocket_asr_vad_');
    try {
      final windows = await _planNeuralWindows(
        audio: audio,
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
