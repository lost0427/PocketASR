import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/audio_source.dart';
import 'package:pocket_asr/core/audio/wav.dart';

const _channel = MethodChannel('pocket_asr/audio_decode_test');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late List<MethodCall> calls;

  void mock(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, handler);
  }

  /// Forces the Android native branch on the desktop test host.
  FileAudioSource nativeSource() =>
      FileAudioSource(channel: _channel, usesNativeDecoder: () => true);

  File writeF32(List<double> samples, {String name = 'decode.f32'}) {
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    final data = ByteData(4 * samples.length);
    for (var i = 0; i < samples.length; i++) {
      data.setFloat32(4 * i, samples[i], Endian.little);
    }
    file.writeAsBytesSync(data.buffer.asUint8List());
    return file;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('audio_source_test_');
    calls = [];
  });

  tearDown(() {
    mock(null);
    dir.deleteSync(recursive: true);
  });

  test('non-Android branch still decodes WAV with WavDecoder', () async {
    final wav = File('${dir.path}${Platform.pathSeparator}a.wav')
      ..writeAsBytesSync(
        encodePcm16Wav(Float32List.fromList(List.filled(16000, 0.25)), 16000),
      );
    final audio = await FileAudioSource(
      channel: _channel,
      usesNativeDecoder: () => false,
    ).read(wav.path);
    expect(audio.sampleRate, 16000);
    expect(audio.samples.length, 16000);
    expect(audio.samples.first, closeTo(0.25, 0.001));
  });

  test('non-Android branch reports missing files', () async {
    await expectLater(
      FileAudioSource(
        channel: _channel,
        usesNativeDecoder: () => false,
      ).read('${dir.path}${Platform.pathSeparator}nope.wav'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('native branch sends path + target rate and reads back the f32 temp', () async {
    final temp = writeF32([0.25, -0.5, 0.75]);
    mock((call) async {
      calls.add(call);
      return {'path': temp.path, 'sampleRate': 16000, 'count': 3};
    });

    final audio = await nativeSource().read('content://media/external/audio/1');

    expect(calls.single.method, 'decodeToPcm');
    expect(calls.single.arguments, {
      'path': 'content://media/external/audio/1',
      'targetSampleRate': 16000,
    });
    expect(audio.sampleRate, 16000);
    expect(audio.samples, [0.25, -0.5, 0.75]);
    expect(temp.existsSync(), isFalse, reason: 'native temp must be cleaned up');
  });

  test('native branch handles a zero-length decode', () async {
    final temp = writeF32([]);
    mock((call) async => {
      'path': temp.path,
      'sampleRate': 16000,
      'count': 0,
    });

    final audio = await nativeSource().read('/sdcard/Download/empty.m4a');

    expect(audio.samples, isEmpty);
    expect(audio.duration, Duration.zero);
    expect(temp.existsSync(), isFalse);
  });

  test('size mismatch against reported count fails and cleans up', () async {
    final temp = writeF32([0.1, 0.2]);
    mock((call) async => {
      'path': temp.path,
      'sampleRate': 16000,
      'count': 5, // claims 20 bytes, file has 8
    });

    await expectLater(
      nativeSource().read('/sdcard/Download/bogus.mp3'),
      throwsFormatException,
    );
    expect(temp.existsSync(), isFalse);
  });

  test('malformed results are rejected and any temp file is removed', () async {
    final temp = writeF32([0.5]);
    for (final bad in <Object?>[
      null,
      'not a map',
      {'path': temp.path, 'sampleRate': 44100, 'count': 1}, // wrong rate
      {'path': '', 'sampleRate': 16000, 'count': 1}, // empty path
      {'path': temp.path, 'sampleRate': 16000, 'count': -1}, // negative count
      {'path': temp.path, 'sampleRate': 16000}, // missing count
    ]) {
      mock((call) async => bad);
      await expectLater(
        nativeSource().read('/sdcard/Download/x.flac'),
        throwsFormatException,
      );
    }
    expect(temp.existsSync(), isFalse);
  });

  test('missing temp file reported by native propagates and is swallowed by cleanup', () async {
    mock((call) async => {
      'path': '${dir.path}${Platform.pathSeparator}gone.f32',
      'sampleRate': 16000,
      'count': 1,
    });

    await expectLater(
      nativeSource().read('/sdcard/Download/x.m4a'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('native decode errors propagate as PlatformException', () async {
    mock((call) async => throw PlatformException(
          code: 'decode_failed',
          message: 'No audio track',
        ));

    await expectLater(
      nativeSource().read('/sdcard/Download/silent.bin'),
      throwsA(isA<PlatformException>()),
    );
    expect(calls, isEmpty); // handler never recorded a successful reply
  });
}
