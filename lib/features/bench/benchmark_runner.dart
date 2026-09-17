import 'dart:convert';

import '../../core/audio/chunk_planner.dart';
import '../../engine/asr_engine.dart';
import '../transcribe/transcription_service.dart';

/// One matrix cell: the model bundle a row benchmarks.
class BenchmarkCase {
  const BenchmarkCase({
    required this.id,
    required this.model,
  });

  /// Stable id (the catalog entry id) so a row can be tracked across runs.
  final String id;

  /// Complete catalog bundle, including tokens and encoder/decoder companions.
  final EngineModelSpec model;

  String get family => model.family ?? '';
  String get quant => model.quant ?? '';
  String get modelPath => model.path;
}

/// The median outcome of [BenchmarkRunner.run]'s repeated runs for one case.
///
/// [elapsed], [tokensPerSecond] and [rtf] are medians over the runs that
/// succeeded; [attempts] and [failures] say how many really ran. A cell with no
/// successful run carries [error] and no numbers — it is never given a made-up
/// value.
class BenchmarkResult {
  const BenchmarkResult({
    required this.caseSpec,
    required this.engine,
    required this.backend,
    this.elapsed,
    this.tokensPerSecond,
    this.rtf,
    this.attempts = 0,
    this.failures = 0,
    this.error,
  });

  final BenchmarkCase caseSpec;
  final String engine;
  final Backend backend;
  final Duration? elapsed;
  final double? tokensPerSecond;
  final double? rtf;

  /// How many runs were attempted and how many threw.
  final int attempts;
  final int failures;

  /// Failure message when no run succeeded, or a partial-failure note.
  final String? error;

  bool get isFailure => elapsed == null && rtf == null && tokensPerSecond == null;

  Map<String, Object?> toJson() => {
    'id': caseSpec.id,
    'family': caseSpec.family,
    'quant': caseSpec.quant,
    'modelPath': caseSpec.modelPath,
    'engine': engine,
    'backend': backend.name,
    'elapsedMs': elapsed?.inMilliseconds,
    'tokensPerSecond': tokensPerSecond,
    'rtf': rtf,
    'attempts': attempts,
    'failures': failures,
    'error': error,
  };
}

/// Runs one [BenchmarkCase] repeatedly on a fixed audio file and reduces the
/// runs to medians.
///
/// Reuses [TranscriptionService] (the same path the transcribe page uses), so a
/// benchmark number and a live-transcription number come from the same
/// code/metrics. Nothing here writes history; a benchmark is not a transcript.
/// [isCancelled] is forwarded to the service, so a cancel aborts like any other
/// run — and [EngineCancelledException] is rethrown rather than turned into an
/// error cell, so the page can stop the whole matrix.
class BenchmarkRunner {
  BenchmarkRunner(
    this.engine,
    this.service, {
    this.chunkSettings,
    this.neuralVad,
  });

  final AsrEngine engine;
  final TranscriptionService service;

  /// Chunking for every run. Null keeps the single whole-file request, which is
  /// what makes the rows comparable — or, in neural mode, is null because
  /// [neuralVad] is the mutually exclusive alternative.
  final ChunkSettings? chunkSettings;

  /// Real neural VAD settings for every run. Null unless the neural strategy is
  /// selected; the service refuses it together with [chunkSettings].
  final NeuralVadSettings? neuralVad;

  Future<BenchmarkResult> run(
    BenchmarkCase caseSpec,
    String audioPath, {
    int repeats = 3,
    bool Function()? isCancelled,
  }) async {
    final elapsed = <Duration>[];
    final tokensPerSecond = <double>[];
    final rtf = <double>[];
    var failures = 0;
    String? lastError;

    for (var i = 0; i < repeats; i++) {
      try {
        final result = await service.transcribe(
          audioPath: audioPath,
          model: caseSpec.model,
          chunkSettings: chunkSettings,
          neuralVad: neuralVad,
          isCancelled: isCancelled,
        );
        elapsed.add(result.elapsed);
        final rate = result.avgTokensPerSec;
        if (rate != null) tokensPerSecond.add(rate);
        final factor = result.rtf;
        if (factor != null) rtf.add(factor);
      } on EngineCancelledException {
        rethrow; // a cancel stops the matrix, it is not a failed cell
      } catch (error) {
        failures++;
        lastError = error.toString();
      }
    }

    if (elapsed.isEmpty) {
      return BenchmarkResult(
        caseSpec: caseSpec,
        engine: engine.id,
        backend: Backend.cpu,
        attempts: repeats,
        failures: failures,
        error: lastError ?? 'No run produced a result.',
      );
    }

    return BenchmarkResult(
      caseSpec: caseSpec,
      engine: engine.id,
      backend: Backend.cpu,
      elapsed: _medianDuration(elapsed),
      tokensPerSecond: _median(tokensPerSecond),
      rtf: _median(rtf),
      attempts: repeats,
      failures: failures,
      error: failures == 0
          ? null
          : '$failures of $repeats run(s) failed: ${lastError ?? ''}'.trim(),
    );
  }

  /// Median of [values], or null when empty. For an even count it averages the
  /// two middle values.
  static double? _median(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  static Duration? _medianDuration(List<Duration> values) {
    final micros = _median([for (final v in values) v.inMicroseconds.toDouble()]);
    return micros == null ? null : Duration(microseconds: micros.round());
  }

  static String toJson(List<BenchmarkResult> results) =>
      const JsonEncoder.withIndent('  ').convert(results.map((r) => r.toJson()).toList());

  static String toCsv(List<BenchmarkResult> results) {
    final lines = <String>[
      'id,family,quant,modelPath,engine,backend,elapsedMs,tokensPerSecond,rtf,'
          'attempts,failures,error',
    ];
    for (final result in results) {
      final values =
          result.toJson().values.map((value) => _csv(value?.toString() ?? '')).join(',');
      lines.add(values);
    }
    return '${lines.join('\n')}\n';
  }

  static String _csv(String value) => '"${value.replaceAll('"', '""')}"';
}
