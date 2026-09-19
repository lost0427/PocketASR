import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'pcm_file.dart';

/// Run the bundled executable directly; paths are arguments, never shell text.
///
/// FFmpeg covers every format on desktop. The decode is followed by a bounded
/// AGC (`dynaudnorm`) so Windows output is level-consistent too; Android does
/// the same job in-process with SpeexDSP during decode.
Future<PcmFile> decodeWithFfmpeg(
  String source,
  String destination, {
  String? executable,
  bool Function()? isCancelled,
}) async {
  checkAudioCancellation(isCancelled);
  final program =
      executable ??
      (Platform.isWindows
          ? '${File(Platform.resolvedExecutable).parent.path}/ffmpeg/bin/ffmpeg.exe'
          : 'ffmpeg');
  final process = await Process.start(program, [
    '-nostdin',
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-i',
    source,
    '-map',
    '0:a:0',
    '-vn',
    '-ac',
    '1',
    '-ar',
    '16000',
    '-af',
    'dynaudnorm=f=200:m=10',
    '-c:a',
    'pcm_f32le',
    '-f',
    'f32le',
    destination,
  ]);
  var errorTail = '';
  final errorsDone = Completer<void>();
  final errors = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen((text) {
        errorTail += text;
        if (errorTail.length > 8192) {
          errorTail = errorTail.substring(errorTail.length - 8192);
        }
      }, onDone: errorsDone.complete, onError: errorsDone.completeError);
  final output = process.stdout.drain<void>();
  var cancelled = false;
  final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    if (isCancelled?.call() ?? false) {
      cancelled = true;
      process.kill(ProcessSignal.sigkill);
    }
  });
  try {
    final code = await process.exitCode;
    await output;
    await errorsDone.future;
    if (cancelled) checkAudioCancellation(() => true);
    checkAudioCancellation(isCancelled);
    if (code != 0) throw ProcessException(program, [], errorTail, code);
    final bytes = await File(destination).length();
    if (bytes == 0 || bytes % 4 != 0) {
      throw const FormatException('FFmpeg produced invalid PCM');
    }
    return PcmFile(
      destination,
      bytes ~/ 4,
      decoderInfo: const AudioDecoderInfo(
        name: 'FFmpeg+agc',
        isHardware: false,
      ),
    );
  } finally {
    timer.cancel();
    await errors.cancel();
  }
}
