import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/audio/wav.dart';
import 'package:pocket_asr/engine/asr_engine.dart';
import 'package:pocket_asr/engine/sherpa_mnn_engine.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pocket-sherpa-mnn-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('platform and native availability', () {
    test('non-Android is exact and never invokes the API factory', () async {
      var factoryCalls = 0;
      final engine = SherpaMnnEngine(
        isAndroid: () => false,
        apiFactory: (_) {
          factoryCalls++;
          throw StateError('must not open');
        },
      );

      expect(engine.id, 'sherpa-mnn');
      expect(await engine.availableBackends(), isEmpty);
      final caps = await engine.capabilities();
      expect(caps.available, isFalse);
      expect(caps.backends, isEmpty);
      expect(caps.supportsVad, isFalse);
      expect(caps.unavailableReason, sherpaMnnAndroidOnlyReason);
      await expectLater(
        engine.load(_spec(), Backend.cpu),
        throwsA(
          isA<EngineUnavailableException>().having(
            (error) => error.message,
            'message',
            sherpaMnnAndroidOnlyReason,
          ),
        ),
      );
      expect(factoryCalls, 0);
    });

    test('missing required native symbol is reported explicitly', () async {
      final engine = SherpaMnnEngine(
        isAndroid: () => true,
        apiFactory: (_) => throw StateError(
          'missing required symbol "SherpaMnnGetOfflineStreamResult"',
        ),
      );

      final caps = await engine.capabilities();
      expect(caps.available, isFalse);
      expect(
        caps.unavailableReason,
        contains('SherpaMnnGetOfflineStreamResult'),
      );
      expect(await engine.availableBackends(), isEmpty);
    });

    test('available Android API reports CPU only and no VAD', () async {
      final api = _FakeApi();
      final engine = _engine(api);

      expect(await engine.availableBackends(), [Backend.cpu]);
      final caps = await engine.capabilities();
      expect(caps.available, isTrue);
      expect(caps.backends, {Backend.cpu});
      expect(caps.supportsVad, isFalse);
      await expectLater(
        engine.planVad(
          const TranscribeRequest(audioPath: 'unused.wav'),
          const NeuralVadSettings(modelPath: 'unused.onnx'),
        ),
        throwsA(
          isA<EngineUnavailableException>().having(
            (error) => error.message,
            'message',
            contains('separate sherpa-onnx VAD'),
          ),
        ),
      );
    });
  });

  group('pinned model preflight', () {
    test('untrusted model is rejected before file or native access', () async {
      final api = _FakeApi();
      var verified = 0;
      var factories = 0;
      final engine = SherpaMnnEngine(
        isAndroid: () => true,
        apiFactory: (_) {
          factories++;
          return api;
        },
        fileVerifier: (_, _, _, _) async => verified++,
      );

      await expectLater(
        engine.load(
          const EngineModelSpec(
            path: 'model.mnn',
            tokensPath: 'tokens.txt',
            family: sherpaMnnFamily,
            quant: sherpaMnnQuant,
          ),
          Backend.cpu,
        ),
        throwsA(isA<EngineUnavailableException>()),
      );
      expect(verified, 0);
      expect(factories, 0);
      expect(api.createRecognizerCalls, 0);
    });

    test('every catalog claim must match the pinned release', () async {
      final specs = <EngineModelSpec>[
        _spec(bundleId: 'other'),
        _spec(family: 'whisper'),
        _spec(quant: 'int8'),
        _spec(modelSize: 1),
        _spec(modelSha: '0' * 64),
        _spec(tokensSize: 1),
        _spec(tokensSha: '1' * 64),
      ];

      for (final spec in specs) {
        final api = _FakeApi();
        var verified = 0;
        final engine = _engine(api, verifier: (_, _, _, _) async => verified++);
        await expectLater(
          engine.load(spec, Backend.cpu),
          throwsA(isA<EngineUnavailableException>()),
        );
        expect(verified, 0);
        expect(api.createRecognizerCalls, 0);
      }
    });

    test(
      'both files verify before fixed recognizer config crosses API',
      () async {
        final api = _FakeApi();
        final events = <String>[];
        final engine = SherpaMnnEngine(
          threads: 99,
          isAndroid: () => true,
          apiFactory: (_) => api..events = events,
          fileVerifier: (label, path, size, hash) async {
            events.add('verify-$label');
            if (label == 'model') {
              expect(path, 'model.mnn');
              expect(size, sherpaMnnModelSizeBytes);
              expect(hash, sherpaMnnModelSha256);
            } else {
              expect(path, 'tokens.txt');
              expect(size, sherpaMnnTokensSizeBytes);
              expect(hash, sherpaMnnTokensSha256);
            }
          },
        );

        await engine.load(_spec(), Backend.cpu);

        expect(events, ['verify-model', 'verify-tokens', 'create-recognizer']);
        final options = api.options.single;
        expect(options.modelPath, 'model.mnn');
        expect(options.tokensPath, 'tokens.txt');
        expect(options.language, 'auto');
        expect(options.decodingMethod, 'greedy_search');
        expect(options.provider, 'cpu');
        expect(options.threads, 8);
      },
    );

    test('production verifier checks current size and SHA-256', () async {
      final file = File('${temp.path}${Platform.pathSeparator}identity.bin');
      await file.writeAsString('abc', flush: true);

      await verifySherpaMnnFile(
        'fixture',
        file.path,
        3,
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      await expectLater(
        verifySherpaMnnFile('fixture', file.path, 4, '0' * 64),
        throwsA(
          isA<EngineUnavailableException>().having(
            (error) => error.message,
            'message',
            contains('size mismatch'),
          ),
        ),
      );
      await expectLater(
        verifySherpaMnnFile('fixture', file.path, 3, '0' * 64),
        throwsA(
          isA<EngineUnavailableException>().having(
            (error) => error.message,
            'message',
            contains('SHA-256 mismatch'),
          ),
        ),
      );
    });
  });

  group('native lifecycle and audio', () {
    test(
      'reload destroys the prior recognizer once; dispose is idempotent',
      () async {
        final api = _FakeApi();
        final engine = _engine(api);

        await engine.load(_spec(), Backend.cpu);
        await engine.load(_spec(), Backend.cpu);
        expect(api.createRecognizerCalls, 2);
        expect(api.destroyedRecognizers, hasLength(1));

        await engine.dispose();
        await engine.dispose();
        expect(api.destroyedRecognizers, hasLength(2));
        expect(api.destroyedRecognizers.toSet(), hasLength(2));
      },
    );

    test(
      'null recognizer fails without replacing or destroying the old one',
      () async {
        final api = _FakeApi();
        final engine = _engine(api);
        await engine.load(_spec(), Backend.cpu);
        api.nullRecognizer = true;

        await expectLater(
          engine.load(_spec(), Backend.cpu),
          throwsA(
            isA<EngineUnavailableException>().having(
              (error) => error.message,
              'message',
              contains('recognizer creation returned null'),
            ),
          ),
        );
        expect(api.destroyedRecognizers, isEmpty);
        await engine.dispose();
        expect(api.destroyedRecognizers, hasLength(1));
      },
    );

    test('canonical PCM16 is normalized exactly and accepted once', () async {
      final api = _FakeApi(resultText: '真实文本');
      final engine = _engine(api);
      await engine.load(_spec(), Backend.cpu);
      final wave = await _wave(
        temp,
        Float32List.fromList([-1, 0, 32767 / 32768]),
      );

      final progress = await engine
          .transcribe(TranscribeRequest(audioPath: wave.path))
          .single;

      expect(progress.ratio, 1);
      expect(progress.partialText, '真实文本');
      expect(api.accepted, hasLength(1));
      expect(api.accepted.single[0], -1);
      expect(api.accepted.single[1], 0);
      expect(api.accepted.single[2], closeTo(32767 / 32768, 1e-7));
      expect(
        api.events,
        containsAllInOrder([
          'create-stream',
          'accept',
          'decode',
          'get-result',
          'copy-result',
          'destroy-result',
          'destroy-stream',
        ]),
      );
      expect(api.destroyedResults, hasLength(1));
      expect(api.destroyedStreams, hasLength(1));
    });

    test('empty and non-canonical audio fail before stream creation', () async {
      final api = _FakeApi();
      final engine = _engine(api);
      await engine.load(_spec(), Backend.cpu);
      final empty = await _wave(temp, Float32List(0), name: 'empty.wav');
      final malformed = File(
        '${temp.path}${Platform.pathSeparator}malformed.wav',
      );
      await malformed.writeAsBytes([1, 2, 3], flush: true);

      for (final path in [empty.path, malformed.path]) {
        await expectLater(
          engine.transcribe(TranscribeRequest(audioPath: path)),
          emitsError(isA<EngineUnavailableException>()),
        );
      }
      expect(api.createStreamCalls, 0);
    });

    test(
      'null stream and null result surface and clean owned handles',
      () async {
        final wave = await _wave(temp, Float32List.fromList([0]));

        final nullStreamApi = _FakeApi()..nullStream = true;
        final nullStreamEngine = _engine(nullStreamApi);
        await nullStreamEngine.load(_spec(), Backend.cpu);
        await expectLater(
          nullStreamEngine.transcribe(TranscribeRequest(audioPath: wave.path)),
          emitsError(
            isA<EngineUnavailableException>().having(
              (error) => error.message,
              'message',
              contains('stream creation returned null'),
            ),
          ),
        );
        expect(nullStreamApi.destroyedStreams, isEmpty);

        final nullResultApi = _FakeApi()..nullResult = true;
        final nullResultEngine = _engine(nullResultApi);
        await nullResultEngine.load(_spec(), Backend.cpu);
        await expectLater(
          nullResultEngine.transcribe(TranscribeRequest(audioPath: wave.path)),
          emitsError(
            isA<EngineUnavailableException>().having(
              (error) => error.message,
              'message',
              contains('result retrieval returned null'),
            ),
          ),
        );
        expect(nullResultApi.destroyedResults, isEmpty);
        expect(nullResultApi.destroyedStreams, hasLength(1));
      },
    );

    test(
      'decode and UTF-8 errors still release every acquired handle',
      () async {
        final wave = await _wave(temp, Float32List.fromList([0]));

        final decodeApi = _FakeApi()..decodeError = StateError('decode failed');
        final decodeEngine = _engine(decodeApi);
        await decodeEngine.load(_spec(), Backend.cpu);
        await expectLater(
          decodeEngine.transcribe(TranscribeRequest(audioPath: wave.path)),
          emitsError(isA<EngineUnavailableException>()),
        );
        expect(decodeApi.destroyedResults, isEmpty);
        expect(decodeApi.destroyedStreams, hasLength(1));

        final utf8Api = _FakeApi()
          ..copyError = const FormatException('bad UTF-8');
        final utf8Engine = _engine(utf8Api);
        await utf8Engine.load(_spec(), Backend.cpu);
        await expectLater(
          utf8Engine.transcribe(TranscribeRequest(audioPath: wave.path)),
          emitsError(isA<EngineUnavailableException>()),
        );
        expect(utf8Api.destroyedResults, hasLength(1));
        expect(utf8Api.destroyedStreams, hasLength(1));
      },
    );
  });
}

EngineModelSpec _spec({
  String bundleId = sherpaMnnBundleId,
  String family = sherpaMnnFamily,
  String quant = sherpaMnnQuant,
  int modelSize = sherpaMnnModelSizeBytes,
  String modelSha = sherpaMnnModelSha256,
  int tokensSize = sherpaMnnTokensSizeBytes,
  String tokensSha = sherpaMnnTokensSha256,
}) => EngineModelSpec.trustedCatalog(
  path: 'model.mnn',
  tokensPath: 'tokens.txt',
  trustedBundleId: bundleId,
  family: family,
  quant: quant,
  modelSizeBytes: modelSize,
  modelSha256: modelSha,
  tokensSizeBytes: tokensSize,
  tokensSha256: tokensSha,
);

SherpaMnnEngine _engine(_FakeApi api, {SherpaMnnFileVerifier? verifier}) =>
    SherpaMnnEngine(
      isAndroid: () => true,
      apiFactory: (_) => api,
      fileVerifier: verifier ?? (_, _, _, _) async {},
    );

Future<File> _wave(
  Directory directory,
  Float32List samples, {
  String name = 'audio.wav',
}) async {
  final file = File('${directory.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(encodePcm16Wav(samples, 16000), flush: true);
  return file;
}

class _FakeApi implements SherpaMnnApi {
  _FakeApi({this.resultText = 'text'});

  final String resultText;
  List<String> events = [];
  final List<SherpaMnnRecognizerOptions> options = [];
  final List<Float32List> accepted = [];
  final List<Object> destroyedRecognizers = [];
  final List<Object> destroyedStreams = [];
  final List<Object> destroyedResults = [];
  int createRecognizerCalls = 0;
  int createStreamCalls = 0;
  bool nullRecognizer = false;
  bool nullStream = false;
  bool nullResult = false;
  Object? decodeError;
  Object? copyError;

  @override
  Object? createRecognizer(SherpaMnnRecognizerOptions value) {
    createRecognizerCalls++;
    options.add(value);
    events.add('create-recognizer');
    return nullRecognizer ? null : Object();
  }

  @override
  void destroyRecognizer(Object recognizer) {
    events.add('destroy-recognizer');
    destroyedRecognizers.add(recognizer);
  }

  @override
  Object? createStream(Object recognizer) {
    createStreamCalls++;
    events.add('create-stream');
    return nullStream ? null : Object();
  }

  @override
  void destroyStream(Object stream) {
    events.add('destroy-stream');
    destroyedStreams.add(stream);
  }

  @override
  void acceptWaveform(Object stream, Float32List samples) {
    events.add('accept');
    accepted.add(Float32List.fromList(samples));
  }

  @override
  void decode(Object recognizer, Object stream) {
    events.add('decode');
    final error = decodeError;
    if (error != null) throw error;
  }

  @override
  Object? getResult(Object stream) {
    events.add('get-result');
    return nullResult ? null : Object();
  }

  @override
  String copyResultText(Object result) {
    events.add('copy-result');
    final error = copyError;
    if (error != null) throw error;
    return resultText;
  }

  @override
  void destroyResult(Object result) {
    events.add('destroy-result');
    destroyedResults.add(result);
  }
}
