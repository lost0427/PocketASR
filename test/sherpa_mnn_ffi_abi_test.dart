import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/engine/sherpa_mnn_bindings.dart';

const _pointerSentinel = 0x12345678;
const _int32Sentinel = 0x12345678;
const _floatSentinel = 123.5;

void _clear(Pointer<Uint8> pointer, int size) {
  pointer.asTypedList(size).fillRange(0, size, 0);
}

void _expectPointerOffset(
  Pointer<Uint8> pointer,
  int size,
  int offset,
  void Function(int address) set,
) {
  _clear(pointer, size);
  set(_pointerSentinel);
  expect((pointer + offset).cast<IntPtr>().value, _pointerSentinel);
}

void _expectInt32Offset(
  Pointer<Uint8> pointer,
  int size,
  int offset,
  void Function(int fieldValue) set,
) {
  _clear(pointer, size);
  set(_int32Sentinel);
  expect((pointer + offset).cast<Int32>().value, _int32Sentinel);
}

void _expectFloatOffset(
  Pointer<Uint8> pointer,
  int size,
  int offset,
  void Function(double fieldValue) set,
) {
  _clear(pointer, size);
  set(_floatSentinel);
  expect((pointer + offset).cast<Float>().value, _floatSentinel);
}

Pointer<Char> _charPointer(int address) => Pointer<Char>.fromAddress(address);

void main() {
  setUpAll(() {
    expect(
      sizeOf<IntPtr>(),
      8,
      reason: 'The sherpa-mnn binding targets Android arm64-v8a.',
    );
  });

  test('SherpaMnnFeatureConfig arm64 layout', () {
    const size = 8;
    expect(sizeOf<SherpaMnnFeatureConfig>(), size);
    final pointer = calloc<SherpaMnnFeatureConfig>();
    addTearDown(() => calloc.free(pointer));

    _expectInt32Offset(pointer.cast(), size, 0, (field) {
      pointer.ref.sample_rate = field;
    });
    _expectInt32Offset(pointer.cast(), size, 4, (field) {
      pointer.ref.feature_dim = field;
    });
  });

  test('SherpaMnnOfflineSenseVoiceModelConfig arm64 layout', () {
    const size = 24;
    expect(sizeOf<SherpaMnnOfflineSenseVoiceModelConfig>(), size);
    final pointer = calloc<SherpaMnnOfflineSenseVoiceModelConfig>();
    addTearDown(() => calloc.free(pointer));

    _expectPointerOffset(pointer.cast(), size, 0, (address) {
      pointer.ref.model = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 8, (address) {
      pointer.ref.language = _charPointer(address);
    });
    _expectInt32Offset(pointer.cast(), size, 16, (field) {
      pointer.ref.use_itn = field;
    });
  });

  test('SherpaMnnOfflineModelConfig arm64 top-level layout', () {
    const size = 216;
    expect(sizeOf<SherpaMnnOfflineModelConfig>(), size);
    final pointer = calloc<SherpaMnnOfflineModelConfig>();
    addTearDown(() => calloc.free(pointer));

    _expectPointerOffset(pointer.cast(), size, 0, (address) {
      pointer.ref.transducer.encoder = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 24, (address) {
      pointer.ref.paraformer.model = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 32, (address) {
      pointer.ref.nemo_ctc.model = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 40, (address) {
      pointer.ref.whisper.encoder = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 80, (address) {
      pointer.ref.tdnn.model = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 88, (address) {
      pointer.ref.tokens = _charPointer(address);
    });
    _expectInt32Offset(pointer.cast(), size, 96, (field) {
      pointer.ref.num_threads = field;
    });
    _expectInt32Offset(pointer.cast(), size, 100, (field) {
      pointer.ref.debug = field;
    });
    _expectPointerOffset(pointer.cast(), size, 104, (address) {
      pointer.ref.provider = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 112, (address) {
      pointer.ref.model_type = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 120, (address) {
      pointer.ref.modeling_unit = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 128, (address) {
      pointer.ref.bpe_vocab = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 136, (address) {
      pointer.ref.telespeech_ctc = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 144, (address) {
      pointer.ref.sense_voice.model = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 168, (address) {
      pointer.ref.moonshine.preprocessor = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 200, (address) {
      pointer.ref.fire_red_asr.encoder = _charPointer(address);
    });
  });

  test('SherpaMnnOfflineRecognizerConfig arm64 top-level layout', () {
    const size = 296;
    expect(sizeOf<SherpaMnnOfflineRecognizerConfig>(), size);
    final pointer = calloc<SherpaMnnOfflineRecognizerConfig>();
    addTearDown(() => calloc.free(pointer));

    _expectInt32Offset(pointer.cast(), size, 0, (field) {
      pointer.ref.feat_config.sample_rate = field;
    });
    _expectPointerOffset(pointer.cast(), size, 8, (address) {
      pointer.ref.model_config.transducer.encoder = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 224, (address) {
      pointer.ref.lm_config.model = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 240, (address) {
      pointer.ref.decoding_method = _charPointer(address);
    });
    _expectInt32Offset(pointer.cast(), size, 248, (field) {
      pointer.ref.max_active_paths = field;
    });
    _expectPointerOffset(pointer.cast(), size, 256, (address) {
      pointer.ref.hotwords_file = _charPointer(address);
    });
    _expectFloatOffset(pointer.cast(), size, 264, (field) {
      pointer.ref.hotwords_score = field;
    });
    _expectPointerOffset(pointer.cast(), size, 272, (address) {
      pointer.ref.rule_fsts = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 280, (address) {
      pointer.ref.rule_fars = _charPointer(address);
    });
    _expectFloatOffset(pointer.cast(), size, 288, (field) {
      pointer.ref.blank_penalty = field;
    });
  });

  test('SherpaMnnOfflineRecognizerResult arm64 layout', () {
    const size = 72;
    expect(sizeOf<SherpaMnnOfflineRecognizerResult>(), size);
    final pointer = calloc<SherpaMnnOfflineRecognizerResult>();
    addTearDown(() => calloc.free(pointer));

    _expectPointerOffset(pointer.cast(), size, 0, (address) {
      pointer.ref.text = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 8, (address) {
      pointer.ref.timestamps = Pointer<Float>.fromAddress(address);
    });
    _expectInt32Offset(pointer.cast(), size, 16, (field) {
      pointer.ref.count = field;
    });
    _expectPointerOffset(pointer.cast(), size, 24, (address) {
      pointer.ref.tokens = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 32, (address) {
      pointer.ref.tokens_arr = Pointer<Pointer<Char>>.fromAddress(address);
    });
    _expectPointerOffset(pointer.cast(), size, 40, (address) {
      pointer.ref.json = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 48, (address) {
      pointer.ref.lang = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 56, (address) {
      pointer.ref.emotion = _charPointer(address);
    });
    _expectPointerOffset(pointer.cast(), size, 64, (address) {
      pointer.ref.event = _charPointer(address);
    });
  });
}
