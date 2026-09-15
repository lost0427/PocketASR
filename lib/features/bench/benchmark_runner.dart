import 'dart:convert';

import '../../engine/asr_engine.dart';
import '../../features/transcribe/transcription_service.dart';

class BenchmarkCase {
  const BenchmarkCase({required this.family, required this.quant, required this.modelPath});
  final String family;
  final String quant;
  final String modelPath;
}

class BenchmarkResult {
  const BenchmarkResult({
    required this.caseSpec,
    required this.engine,
    required this.backend,
    this.elapsed,
    this.tokensPerSecond,
    this.rtf,
    this.error,
  });

  final BenchmarkCase caseSpec;
  final String engine;
  final Backend backend;
  final Duration? elapsed;
  final double? tokensPerSecond;
  final double? rtf;
  final String? error;

  Map<String, Object?> toJson() => {
    'family': caseSpec.family,
    'quant': caseSpec.quant,
    'modelPath': caseSpec.modelPath,
    'engine': engine,
    'backend': backend.name,
    'elapsedMs': elapsed?.inMilliseconds,
    'tokensPerSecond': tokensPerSecond,
    'rtf': rtf,
    'error': error,
  };
}

class BenchmarkRunner {
  BenchmarkRunner(this.engine, this.service);

  final AsrEngine engine;
  final TranscriptionService service;

  Future<BenchmarkResult> run(BenchmarkCase caseSpec, String audioPath) async {
    final model = EngineModelSpec(
      path: caseSpec.modelPath,
      family: caseSpec.family,
      quant: caseSpec.quant,
    );
    try {
      final result = await service.transcribe(
        audioPath: audioPath,
        model: model,
      );
      return BenchmarkResult(
        caseSpec: caseSpec,
        engine: result.engine,
        backend: result.backend,
        elapsed: result.elapsed,
        tokensPerSecond: result.avgTokensPerSec,
        rtf: result.rtf,
      );
    } catch (error) {
      return BenchmarkResult(
        caseSpec: caseSpec,
        engine: engine.id,
        backend: Backend.cpu,
        error: error.toString(),
      );
    }
  }

  static String toJson(List<BenchmarkResult> results) =>
      const JsonEncoder.withIndent('  ').convert(results.map((r) => r.toJson()).toList());

  static String toCsv(List<BenchmarkResult> results) {
    final lines = <String>[
      'family,quant,modelPath,engine,backend,elapsedMs,tokensPerSecond,rtf,error',
    ];
    for (final result in results) {
      final values = result.toJson().values.map((value) => _csv(value?.toString() ?? '')).join(',');
      lines.add(values);
    }
    return '${lines.join('\n')}\n';
  }

  static String _csv(String value) => '"${value.replaceAll('"', '""')}"';
}
