import 'dart:io';
import 'dart:typed_data';

import '../../core/audio/audio_buffer.dart';
import '../../core/audio/audio_preprocessor.dart';
import '../../core/audio/audio_source.dart';
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

  Future<TranscriptionJobResult> transcribe({
    required String audioPath,
    required EngineModelSpec model,
    Backend backend = Backend.cpu,
    String? language,
  }) async {
    final sourceAudio = await _source.read(audioPath);
    final processed = _preprocessor.process(sourceAudio);
    final temp = await _writeTemporaryWav(processed.audio);
    try {
      await engine.load(model, backend);
      TranscribeProgress? last;
      await for (final progress in engine.transcribe(
        TranscribeRequest(audioPath: temp.path, backend: backend, language: language),
      )) {
        last = progress;
      }
      final result = last;
      if (result == null || result.partialText.trim().isEmpty) {
        throw const EngineUnavailableException('ASR returned no transcript');
      }
      return TranscriptionJobResult(
        text: result.partialText.trim(),
        elapsed: result.elapsed,
        audioDuration: processed.audio.duration,
        engine: engine.id,
        model: model,
        backend: backend,
        originalLufs: processed.originalLufs,
        gainDb: processed.gainDb,
        tokens: result.tokens,
      );
    } finally {
      await temp.delete();
    }
  }

  static Future<File> _writeTemporaryWav(AudioBuffer audio) async {
    final dir = await Directory.systemTemp.createTemp('pocket_asr_');
    final file = File('${dir.path}${Platform.pathSeparator}input.wav');
    final bytes = BytesBuilder();
    for (final sample in audio.samples) {
      var value = (sample.clamp(-1.0, 1.0) * 32768).round();
      if (value > 32767) value = 32767;
      final data = ByteData(2)..setInt16(0, value, Endian.little);
      bytes.add(data.buffer.asUint8List());
    }
    final payload = bytes.takeBytes();
    final header = ByteData(44);
    void text(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        header.setUint8(offset + i, value.codeUnitAt(i));
      }
    }
    text(0, 'RIFF');
    header.setUint32(4, 36 + payload.length, Endian.little);
    text(8, 'WAVEfmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, audio.sampleRate, Endian.little);
    header.setUint32(28, audio.sampleRate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    text(36, 'data');
    header.setUint32(40, payload.length, Endian.little);
    await file.writeAsBytes(<int>[...header.buffer.asUint8List(), ...payload]);
    return file;
  }
}
