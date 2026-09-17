import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/audio_picker.dart';

const _channel = MethodChannel('pocket_asr/audio_picker_test');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void mock(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, handler);
  }

  const picker = AudioPicker(channel: _channel, usesUriPicker: _yes);

  tearDown(() => mock(null));

  test(
    'Android single selection crosses the channel as metadata only',
    () async {
      late MethodCall seen;
      mock((call) async {
        seen = call;
        return {
          'uri': 'content://media/external/audio/49',
          'name': 'meeting.mp3',
          'size': 210269432,
        };
      });

      final selected = await picker.pickOne();

      expect(seen.method, 'pickAudio');
      expect(seen.arguments, isNull);
      expect(selected?.source, 'content://media/external/audio/49');
      expect(selected?.name, 'meeting.mp3');
      expect(selected?.size, 210269432);
    },
  );

  test('Android multiple selection preserves URI and display name', () async {
    mock(
      (call) async => [
        {'uri': 'content://local/a', 'name': 'a.wav', 'size': 12},
        {'uri': 'content://local/b', 'name': 'b.flac'},
      ],
    );

    final selected = await picker.pickMany();

    expect(selected.map((file) => file.source), [
      'content://local/a',
      'content://local/b',
    ]);
    expect(selected.map((file) => file.name), ['a.wav', 'b.flac']);
  });

  test('Android cancellation returns no selection', () async {
    mock((call) async => call.method == 'pickAudio' ? null : <Object?>[]);

    expect(await picker.pickOne(), isNull);
    expect(await picker.pickMany(), isEmpty);
  });

  test('malformed Android metadata is rejected', () async {
    mock(
      (call) async => {
        'uri': '/sdcard/meeting.mp3',
        'name': 'meeting.mp3',
        'bytes': List<int>.filled(16, 0),
      },
    );

    await expectLater(picker.pickOne(), throwsFormatException);
  });
}

bool _yes() => true;
