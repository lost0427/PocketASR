import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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

class TranscriptionService {
  TranscriptionService({
    required this.engine,
    this._source = const FileAudioSource(),
    this._preprocessor = const AudioPreprocessor(),
  });

  final AsrEngine engine;
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
  /// [isCancelled] is polled before each chunk (and before the single request
  /// when unchunked): when it turns true, the job throws
  /// [EngineCancelledException] at the next boundary instead of returning a
  /// partial success. In-flight native work cannot be hard-killed, so
  /// cancellation is cooperative and takes effect between chunks — pair it
  /// with [CancellableAsrEngine.cancel] so the engine refuses later chunks
  /// even without this poll. The temp directory is cleaned in `finally` on
  /// every exit path, cancellation included.
  Future<TranscriptionJobResult> transcribe({
    required String audioPath,
    required EngineModelSpec model,
    Backend backend = Backend.cpu,
    String? language,
    ChunkSettings? chunkSettings,
    void Function(TranscribeProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final sourceAudio = await _source.read(audioPath);
    final processed = _preprocessor.process(sourceAudio);
    final audio = processed.audio;
    final chunks = chunkSettings == null
        ? [AudioChunk(start: Duration.zero, end: audio.duration)]
        : ChunkPlanner(settings: chunkSettings).plan(audio);
    if (chunks.isEmpty) {
      throw const EngineUnavailableException(
        'Chunk planner found no speech to transcribe (energy gate, not a '
        'neural VAD); nothing was sent to the engine.',
      );
    }
    // One directory for the whole job; every chunk WAV lives in it and the
    // directory itself (not just the files) is removed in `finally`, on
    // success and on failure alike.
    final dir = await Directory.systemTemp.createTemp('pocket_asr_');
    try {
      await engine.load(model, backend);
      final totalUs = chunks.fold<int>(
        0,
        (sum, chunk) => sum + chunk.duration.inMicroseconds,
      );
      final parts = <String>[];
      var doneUs = 0;
      var elapsed = Duration.zero;
      int? tokensSoFar = 0;
      for (var i = 0; i < chunks.length; i++) {
        if (isCancelled?.call() ?? false) {
          throw EngineCancelledException(
            'Cancelled before chunk ${i + 1} of ${chunks.length}; '
            '${parts.length} chunk(s) were transcribed but discarded — '
            'a cancelled job returns no text.',
          );
        }
        final chunk = chunks[i];
        final chunkUs = math.max(1, chunk.duration.inMicroseconds);
        final slice = Float32List.sublistView(
          audio.samples,
          chunk.startSampleAt(audio.sampleRate),
          chunk.endSampleAt(audio.sampleRate),
        );
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
}
