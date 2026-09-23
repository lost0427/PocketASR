import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/audio/chunk_planner.dart';
import '../core/audio/audio_source.dart';
import '../engine/asr_engine.dart';
import '../engine/embedder.dart';
import '../engine/embedding_worker.dart';
import '../engine/engine_registry.dart';
import '../data/db.dart';
import '../data/search_repo.dart';
import '../data/semantic_indexer.dart';
import '../data/transcript_repo.dart';

/// Builds the [Embedder] for a selected embedding model path. Production uses
/// [WorkerEmbedder] (the real CrispEmbed instance lives on its worker isolate,
/// never on the UI thread) and must have [Embedder.load] completed before the
/// instance is handed back; tests inject a fake so no native library is
/// needed. A failure must throw [EmbedderUnavailableException] — never fall
/// back to [DeterministicEmbedder], which would fake semantic meaning.
typedef EmbedderFactory = FutureOr<Embedder> Function(
  String modelPath,
  EmbeddingModelProfile profile,
  int threads,
);

/// The three-way chunking control in Settings: the two [ChunkMode] strategies
/// plus real neural VAD.
///
/// Neural VAD is deliberately *not* a [ChunkMode] value: it is a separate
/// engine path ([NeuralVadSettings], planned by a sherpa-onnx VAD worker)
/// and is mutually exclusive with [ChunkSettings], which is exactly why the
/// pages hand one or the other — never both — to the service.
enum ChunkStrategy { fixed, energy, neural }

/// Why the selected ASR model must not be started.
///
/// Keeping the reason typed lets callers distinguish a genuinely incomplete
/// sherpa-onnx bundle from an MNN file that bypassed the verified model library.
enum ModelSelectionProblem {
  missingWhisperDecoder,
  sherpaMnnCatalogBundleRequired,
  sherpaMnnTokensRequired,
}

/// App-wide settings.
///
/// Theme and language are tri-state: [ThemeMode.system] and a `null` [locale]
/// mean "follow the device". The model/quant, selected model path, thread
/// count, loudness and chunking values round out the Settings tab. Everything
/// except [threads] is stored in the sqlite `settings` table and restored on
/// start; anything unparseable or out of range falls back to the default.
class AppState extends ChangeNotifier {
  AppState({
    AppDatabase? database,
    EmbedderFactory? embedderFactory,
    EngineRegistry? engineRegistry,
  }) : database = database ?? AppDatabase.open(),
       engineRegistry = engineRegistry ?? EngineRegistry(),
       _embedderFactory = embedderFactory ?? _crispEmbedder {
    _loadSettings();
  }

  static Future<Embedder> _crispEmbedder(
    String modelPath,
    EmbeddingModelProfile profile,
    int threads,
  ) async {
    final embedder = WorkerEmbedder.crisp(
      modelPath: modelPath,
      profile: profile,
      threads: threads,
    );
    try {
      await embedder.load(); // spawns the worker; the native load runs there
      return embedder;
    } on Object {
      await embedder.dispose();
      rethrow;
    }
  }

  final AppDatabase database;
  final EmbedderFactory _embedderFactory;
  late final TranscriptRepo transcriptRepo = TranscriptRepo(database);

  SearchRepo? _searchRepo;

  /// Read-side search over stored transcripts. Rebuilt when an embedding model
  /// is selected (or cleared), so its [Embedder] is always the live one.
  SearchRepo get searchRepo =>
      _searchRepo ??= SearchRepo(database, embedder: _embedder);

  void _loadSettings() {
    final mode = database.getSetting('theme_mode');
    _themeMode = ThemeMode.values.any((value) => value.name == mode)
        ? ThemeMode.values.firstWhere((value) => value.name == mode)
        : ThemeMode.system;
    final language = database.getSetting('locale');
    _locale = language == null || language.isEmpty ? null : Locale(language);
    _modelFamily = database.getSetting('model_family') ?? _modelFamily;
    _modelQuant = database.getSetting('model_quant') ?? _modelQuant;
    _engineId = database.getSetting('engine_id') ?? _engineId;
    _restoreSelection();
    _audioDecoderPreference = AudioDecoderPreference.values.firstWhere(
      (value) => value.name == database.getSetting('audio_decoder_preference'),
      orElse: () => AudioDecoderPreference.automatic,
    );
    _chunkStrategy = _chunkStrategyFrom(database.getSetting('chunk_mode'));
    _chunkSeconds = _boundedDouble(
      database.getSetting('chunk_seconds'),
      minChunkSeconds,
      maxChunkSeconds,
      defaultChunkSettings.chunkSeconds,
    );
    _energyThreshold = _boundedDouble(
      database.getSetting('chunk_threshold'),
      minEnergyThreshold,
      maxEnergyThreshold,
      defaultChunkSettings.energyThreshold,
    );
    _speechPadMs = _boundedInt(
      database.getSetting('chunk_pad_ms'),
      0,
      maxSpeechPadMs,
      defaultChunkSettings.speechPadMs,
    );
    _vadThreshold = _boundedDouble(
      database.getSetting('vad_threshold'),
      minVadThreshold,
      maxVadThreshold,
      defaultVadThreshold,
    );
    _vadMinSilenceSeconds = _boundedDouble(
      database.getSetting('vad_min_silence'),
      minVadMinSilence,
      maxVadMinSilence,
      defaultVadMinSilence,
    );
    _vadMinSpeechSeconds = _boundedDouble(
      database.getSetting('vad_min_speech'),
      minVadMinSpeech,
      maxVadMinSpeech,
      defaultVadMinSpeech,
    );
    _vadPadMs = _boundedInt(
      database.getSetting('vad_pad_ms'),
      0,
      maxVadPadMs,
      defaultVadPadMs,
    );
    _vadMaxSeconds = _boundedDouble(
      database.getSetting('vad_max_seconds'),
      minVadMaxSeconds,
      maxVadMaxSeconds,
      defaultVadMaxSeconds,
    );
    _restoreVadSelection();
    _restoreEmbedding();
  }

  void _save(String key, String value) => database.setSetting(key, value);
  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;
  set themeMode(ThemeMode value) {
    if (value == _themeMode) return;
    _themeMode = value;
    _save('theme_mode', value.name);
    notifyListeners();
  }

  Locale? _locale;

  /// `null` means follow the system language.
  Locale? get locale => _locale;
  set locale(Locale? value) {
    if (value == _locale) return;
    _locale = value;
    _save('locale', value?.languageCode ?? '');
    notifyListeners();
  }

  /// Model family the transcribe flow loads; one of the allowlist families.
  String _modelFamily = 'sensevoice';
  String get modelFamily => _modelFamily;
  set modelFamily(String value) {
    if (value == _modelFamily) return;
    _modelFamily = value;
    _save('model_family', value);
    notifyListeners();
  }

  /// Quantization tag (`q8_0`, `q4_k`, `q6_k`). Registry default is Q8_0.
  String _modelQuant = 'q8_0';
  String get modelQuant => _modelQuant;
  set modelQuant(String value) {
    if (value == _modelQuant) return;
    _modelQuant = value;
    _save('model_quant', value);
    notifyListeners();
  }

  /// Builds engines by id. Held here so the app picks a real adapter without a
  /// DI package; tests can inject one so no native worker is spawned.
  final EngineRegistry engineRegistry;

  /// Real engine preferred by default: sherpa-onnx's Flutter plugin bundles its
  /// own natives, so it is the one adapter that can be genuinely available on a
  /// stock build. CrispASR stays selectable via [engineId] once staged.
  static const String defaultEngineId = 'sherpa';

  String _engineId = defaultEngineId;
  String get engineId => _engineId;
  set engineId(String value) {
    if (value == _engineId) return;
    _engineId = value;
    _invalidateEngine(); // rebuild lazily for the new id
    _save('engine_id', value);
    notifyListeners();
  }

  AsrEngine? _engine;

  /// True when a settings change (thread count) invalidated [_engine] while a
  /// run still owned it; the next access rebuilds once the run has ended.
  bool _engineNeedsRebuild = false;

  /// The selected [AsrEngine], built once per [engineId]/thread count so native
  /// probes are not repeated on every widget rebuild. Whether it can actually
  /// run is a runtime fact the UI reads from `engine.capabilities()`.
  AsrEngine get engine {
    if (_engine != null && _engineNeedsRebuild && !_engineBusy) {
      _engine!.dispose();
      _engine = null;
      _engineNeedsRebuild = false;
    }
    return _engine ??= engineRegistry.createAsr(_engineId, threads: _threads);
  }

  /// Drops the cached engine so [engine] rebuilds with fresh settings. While a
  /// run owns the instance the swap waits for [engineBusy] to clear; the native
  /// session in use is never disposed out from under the worker.
  void _invalidateEngine() {
    if (_engineBusy) {
      _engineNeedsRebuild = true;
    } else {
      _engine?.dispose();
      _engine = null;
      _engineNeedsRebuild = false;
    }
  }

  /// Compute backend. Fixed to CPU for the first release (decision D17); kept
  /// as state so a picker can be added later without touching callers.
  Backend _backend = Backend.cpu;
  Backend get backend => _backend;
  set backend(Backend value) {
    if (value == _backend) return;
    _backend = value;
    notifyListeners();
  }

  /// Worker threads for the CPU path. Defaults to half the cores. Changing it
  /// rebuilds the worker-backed engine with the new count (through the existing
  /// [WorkerAsrEngine] factories) once no run owns the current instance.
  ///
  /// The embedding worker is not touched here — call [applyThreads] for that.
  /// crispembed reads its thread count at load and runs **single-threaded**
  /// when it is not given a positive one, so an embedding session built with
  /// zero stays on one core; a reload therefore re-reads the whole model, which
  /// the settings slider must not trigger on every step.
  int _threads = _defaultThreads();
  int get threads => _threads;
  set threads(int value) {
    final capped = value < 1 ? 1 : (value > maxThreads ? maxThreads : value);
    if (capped == _threads) return;
    _threads = capped;
    _invalidateEngine();
    notifyListeners();
  }

  /// Rebuilds the embedding worker so it picks up [threads]. Idempotent, and a
  /// no-op when no embedding model is selected.
  void applyThreads() => _rebuildEmbedding();

  /// Cores the device reports; the thread slider's upper bound.
  int get maxThreads => Platform.numberOfProcessors;

  AudioDecoderPreference _audioDecoderPreference =
      AudioDecoderPreference.automatic;
  AudioDecoderPreference get audioDecoderPreference => _audioDecoderPreference;
  set audioDecoderPreference(AudioDecoderPreference value) {
    if (value == _audioDecoderPreference) return;
    _audioDecoderPreference = value;
    _save('audio_decoder_preference', value.name);
    notifyListeners();
  }

  /// Filesystem path of the model both the transcribe and queue flows load.
  ///
  /// Shared so a pick in one page is the same model in the other, and persisted
  /// so it survives a restart. `null` (or empty) means no model is selected and
  /// nothing may start — the pages disable Start rather than guess a path.
  ///
  /// This is only the *primary* file. The full selection — companions included
  /// — is [modelSpec], and that is what the pages hand engines.
  String? get modelPath => _selectedSpec?.path;

  /// Sets a hand-picked model file. Replaces any bundle selection with a
  /// path-only spec and points the engine at the format's adapter, so a GGUF is
  /// never silently fed to a sherpa adapter (or vice versa).
  ///
  /// ponytail: retained for persisted-data and test compatibility; production
  /// UI selects complete catalog bundles through [selectModel].
  set modelPath(String? value) {
    final path = _nonEmpty(value);
    if (path == null) {
      clearModelSelection();
      return;
    }
    _selectedSpec = EngineModelSpec(path: path);
    _manualSelection = true;
    _modelSelectionMissing = false;
    _restoredSelectionProblem = null;
    _persistSelection();
    engineId = engineIdForModelFile(path); // releases the previous instance
    notifyListeners();
  }

  EngineModelSpec? _selectedSpec;
  bool _manualSelection = false;
  bool _modelSelectionMissing = false;
  ModelSelectionProblem? _restoredSelectionProblem;

  /// The spec the transcribe and queue flows load, or null when nothing is
  /// selected. A catalog bundle keeps its tokens/encoder/decoder here; a
  /// legacy hand-picked file resolves family/quant from persisted settings.
  EngineModelSpec? get modelSpec {
    final spec = _selectedSpec;
    if (spec == null) return null;
    if (!_manualSelection) return spec;
    return EngineModelSpec(
      path: spec.path,
      family: _modelFamily,
      quant: _modelQuant,
    );
  }

  /// True when the persisted selection could not be restored because a file it
  /// named is gone; the selection is cleared and the UI says so.
  bool get modelSelectionMissing => _modelSelectionMissing;

  /// True when a restored selection predates catalog-only model picking.
  bool get modelSelectionIsManual => _manualSelection && _selectedSpec != null;

  /// Selects a catalog bundle in one step: engine, family, quant and the full
  /// spec (companions included), all persisted. Refused while a run is active
  /// so the loaded instance is not swapped out from under it.
  void selectModel({
    required EngineModelSpec spec,
    required String engineId,
    String? family,
    String? quant,
  }) {
    if (_engineBusy) return;
    _selectedSpec = spec;
    _manualSelection = false;
    _modelSelectionMissing = false;
    _restoredSelectionProblem = null;
    if (family != null && family.isNotEmpty && family != _modelFamily) {
      _modelFamily = family;
      _save('model_family', family);
    }
    if (quant != null && quant.isNotEmpty && quant != _modelQuant) {
      _modelQuant = quant;
      _save('model_quant', quant);
    }
    _persistSelection();
    this.engineId = engineId; // disposes the previous engine instance
    notifyListeners();
  }

  /// Forgets the selection — e.g. its bundle was deleted — and notifies the
  /// pages so they fall back to "no model". Other models are left untouched.
  void clearModelSelection() {
    if (_selectedSpec == null && !_modelSelectionMissing) return;
    _selectedSpec = null;
    _manualSelection = false;
    _modelSelectionMissing = false;
    _restoredSelectionProblem = null;
    _save('model_path', '');
    _save('model_tokens', '');
    _save('model_encoder', '');
    _save('model_decoder', '');
    _save('model_trusted_bundle', '');
    _save('model_size_bytes', '');
    _save('model_sha256', '');
    _save('model_tokens_size_bytes', '');
    _save('model_tokens_sha256', '');
    _save('model_manual', '');
    notifyListeners();
  }

  void _persistSelection() {
    final spec = _selectedSpec!;
    _save('model_path', spec.path);
    _save('model_tokens', spec.tokensPath ?? '');
    _save('model_encoder', spec.encoderPath ?? '');
    _save('model_decoder', spec.decoderPath ?? '');
    _save('model_trusted_bundle', spec.trustedBundleId ?? '');
    _save('model_size_bytes', spec.modelSizeBytes?.toString() ?? '');
    _save('model_sha256', spec.modelSha256 ?? '');
    _save('model_tokens_size_bytes', spec.tokensSizeBytes?.toString() ?? '');
    _save('model_tokens_sha256', spec.tokensSha256 ?? '');
    _save('model_manual', _manualSelection.toString());
  }

  void _restoreSelection() {
    final primary = _nonEmpty(database.getSetting('model_path'));
    if (primary == null) return;
    // Migrate records written before the MNN adapter existed. A `.mnn` file
    // must never be offered to sherpa-onnx merely because its stored engine id
    // predates this routing rule.
    final inferredEngineId = engineIdForModelFile(primary);
    if (inferredEngineId == 'sherpa-mnn' && _engineId != inferredEngineId) {
      _engineId = inferredEngineId;
      _save('engine_id', inferredEngineId);
    }
    final manual = database.getSetting('model_manual') == 'true';
    final tokensPath = _nonEmpty(database.getSetting('model_tokens'));
    final encoderPath = _nonEmpty(database.getSetting('model_encoder'));
    final decoderPath = _nonEmpty(database.getSetting('model_decoder'));
    late final EngineModelSpec spec;
    if (manual) {
      spec = EngineModelSpec(path: primary);
    } else {
      final bundleId = _nonEmpty(database.getSetting('model_trusted_bundle'));
      final modelSizeBytes = _positiveInt(
        database.getSetting('model_size_bytes'),
      );
      final modelSha256 = _storedSha256(database.getSetting('model_sha256'));
      final storedTokensSize = _nonEmpty(
        database.getSetting('model_tokens_size_bytes'),
      );
      final storedTokensSha256 = _nonEmpty(
        database.getSetting('model_tokens_sha256'),
      );
      final tokensSizeBytes = _positiveInt(storedTokensSize);
      final tokensSha256 = _storedSha256(storedTokensSha256);
      final hasCompleteTokensIdentity = tokensPath == null
          ? storedTokensSize == null && storedTokensSha256 == null
          : tokensSizeBytes != null && tokensSha256 != null;
      if (bundleId == null ||
          modelSizeBytes == null ||
          modelSha256 == null ||
          !hasCompleteTokensIdentity) {
        // Pre-trust catalog records and partial/tampered metadata must not be
        // silently upgraded into a native-loadable selection.
        _modelSelectionMissing = true;
        if (primary.toLowerCase().endsWith('.mnn')) {
          _restoredSelectionProblem =
              ModelSelectionProblem.sherpaMnnCatalogBundleRequired;
        }
        return;
      }
      spec = EngineModelSpec.trustedCatalog(
        path: primary,
        family: _modelFamily,
        quant: _modelQuant,
        tokensPath: tokensPath,
        encoderPath: encoderPath,
        decoderPath: decoderPath,
        trustedBundleId: bundleId,
        modelSizeBytes: modelSizeBytes,
        modelSha256: modelSha256,
        tokensSizeBytes: tokensSizeBytes,
        tokensSha256: tokensSha256,
      );
    }
    if (_specFilesExist(spec)) {
      _selectedSpec = spec;
      _manualSelection = manual;
    } else {
      // A file (or companion) vanished: clear the selection and let the UI
      // say so instead of handing an engine a path that no longer exists.
      _modelSelectionMissing = true;
    }
  }

  static int? _positiveInt(String? value) {
    final parsed = int.tryParse(value ?? '');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  static String? _storedSha256(String? value) {
    final sha256 = _nonEmpty(value);
    if (sha256 == null ||
        sha256.length != 64 ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
      return null;
    }
    return sha256.toLowerCase();
  }

  /// True when every file the spec names is still on disk.
  static bool _specFilesExist(EngineModelSpec spec) {
    for (final path in [
      spec.path,
      spec.tokensPath,
      spec.encoderPath,
      spec.decoderPath,
    ]) {
      if (path != null && path.isNotEmpty && !File(path).existsSync()) {
        return false;
      }
    }
    return true;
  }

  /// Best-effort engine for a hand-picked file. The mapping does not make the
  /// file trusted: in particular, a `.mnn` selection is blocked until it came
  /// from a verified catalog bundle with its exact tokens companion.
  static String engineIdForModelFile(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.gguf')) return 'crispasr';
    if (lower.endsWith('.mnn')) return 'sherpa-mnn';
    return 'sherpa';
  }

  /// True while a transcription owns the loaded engine. The Models page reads
  /// this to refuse swapping the in-use model mid-run.
  bool _engineBusy = false;
  bool get engineBusy => _engineBusy;
  set engineBusy(bool value) {
    if (value == _engineBusy) return;
    _engineBusy = value;
    notifyListeners();
  }

  /// Chunking defaults and the bounds the Settings sliders offer. The energy
  /// mode is a loudness gate, **not** a neural VAD (see [ChunkPlanner]); the
  /// neural strategy is the model path described by [NeuralVadSettings].
  static const ChunkSettings defaultChunkSettings = ChunkSettings();
  static const double minChunkSeconds = 5;
  static const double maxChunkSeconds = 120;
  static const double minEnergyThreshold = 0.001;
  static const double maxEnergyThreshold = 0.1;
  static const int maxSpeechPadMs = 500;

  /// Defaults and bounds for the neural VAD knobs. The threshold bounds stay
  /// strictly inside (0, 1) because [NeuralVadSettings.validate] rejects the
  /// endpoints, so a slider value can never produce invalid settings.
  static const double defaultVadThreshold = 0.5;
  static const double minVadThreshold = 0.05;
  static const double maxVadThreshold = 0.95;
  static const double defaultVadMinSilence = 0.5;
  static const double minVadMinSilence = 0.1;
  static const double maxVadMinSilence = 5;
  static const double defaultVadMinSpeech = 0.25;
  static const double minVadMinSpeech = 0.05;
  static const double maxVadMinSpeech = 5;
  static const int defaultVadPadMs = 30;
  static const int maxVadPadMs = 500;
  static const double defaultVadMaxSeconds = 30;
  static const double minVadMaxSeconds = 5;
  static const double maxVadMaxSeconds = 120;

  ChunkStrategy _chunkStrategy = ChunkStrategy.fixed;
  ChunkStrategy get chunkStrategy => _chunkStrategy;
  set chunkStrategy(ChunkStrategy value) {
    if (value == _chunkStrategy) return;
    _chunkStrategy = value;
    _save('chunk_mode', value.name);
    notifyListeners();
  }

  double _chunkSeconds = defaultChunkSettings.chunkSeconds;
  double get chunkSeconds => _chunkSeconds;
  set chunkSeconds(double value) {
    final capped = value.clamp(minChunkSeconds, maxChunkSeconds).toDouble();
    if (capped == _chunkSeconds) return;
    _chunkSeconds = capped;
    _save('chunk_seconds', '$capped');
    notifyListeners();
  }

  double _energyThreshold = defaultChunkSettings.energyThreshold;
  double get energyThreshold => _energyThreshold;
  set energyThreshold(double value) {
    final capped = value
        .clamp(minEnergyThreshold, maxEnergyThreshold)
        .toDouble();
    if (capped == _energyThreshold) return;
    _energyThreshold = capped;
    _save('chunk_threshold', '$capped');
    notifyListeners();
  }

  int _speechPadMs = defaultChunkSettings.speechPadMs;
  int get speechPadMs => _speechPadMs;
  set speechPadMs(int value) {
    final capped = value < 0
        ? 0
        : (value > maxSpeechPadMs ? maxSpeechPadMs : value);
    if (capped == _speechPadMs) return;
    _speechPadMs = capped;
    _save('chunk_pad_ms', '$capped');
    notifyListeners();
  }

  /// The chunking the pages hand to [TranscriptionService.transcribe]. Null in
  /// neural mode, which uses [neuralVadSettings] instead — the service refuses
  /// both at once. Overlap stays at its default of 0: this build does no
  /// deduplication.
  ChunkSettings? get chunkSettings => _chunkStrategy == ChunkStrategy.neural
      ? null
      : ChunkSettings(
          mode: _chunkStrategy == ChunkStrategy.energy
              ? ChunkMode.energy
              : ChunkMode.fixed,
          chunkSeconds: _chunkSeconds,
          energyThreshold: _energyThreshold,
          speechPadMs: _speechPadMs,
        );

  double _vadThreshold = defaultVadThreshold;
  double get vadThreshold => _vadThreshold;
  set vadThreshold(double value) {
    final capped = value.clamp(minVadThreshold, maxVadThreshold).toDouble();
    if (capped == _vadThreshold) return;
    _vadThreshold = capped;
    _save('vad_threshold', '$capped');
    notifyListeners();
  }

  double _vadMinSilenceSeconds = defaultVadMinSilence;
  double get vadMinSilenceSeconds => _vadMinSilenceSeconds;
  set vadMinSilenceSeconds(double value) {
    final capped = value.clamp(minVadMinSilence, maxVadMinSilence).toDouble();
    if (capped == _vadMinSilenceSeconds) return;
    _vadMinSilenceSeconds = capped;
    _save('vad_min_silence', '$capped');
    notifyListeners();
  }

  double _vadMinSpeechSeconds = defaultVadMinSpeech;
  double get vadMinSpeechSeconds => _vadMinSpeechSeconds;
  set vadMinSpeechSeconds(double value) {
    final capped = value.clamp(minVadMinSpeech, maxVadMinSpeech).toDouble();
    if (capped == _vadMinSpeechSeconds) return;
    _vadMinSpeechSeconds = capped;
    _save('vad_min_speech', '$capped');
    notifyListeners();
  }

  int _vadPadMs = defaultVadPadMs;
  int get vadPadMs => _vadPadMs;
  set vadPadMs(int value) {
    final capped = value < 0 ? 0 : (value > maxVadPadMs ? maxVadPadMs : value);
    if (capped == _vadPadMs) return;
    _vadPadMs = capped;
    _save('vad_pad_ms', '$capped');
    notifyListeners();
  }

  double _vadMaxSeconds = defaultVadMaxSeconds;
  double get vadMaxSeconds => _vadMaxSeconds;
  set vadMaxSeconds(double value) {
    final capped = value.clamp(minVadMaxSeconds, maxVadMaxSeconds).toDouble();
    if (capped == _vadMaxSeconds) return;
    _vadMaxSeconds = capped;
    _save('vad_max_seconds', '$capped');
    notifyListeners();
  }

  String? _vadModelPath;
  VadModelFamily _vadModelFamily = VadModelFamily.silero;
  bool _vadSelectionMissing = false;

  /// Local path of the VAD model the neural strategy runs, or null when
  /// none is selected. A *separate* selection from [modelPath]: choosing a VAD
  /// bundle never changes what transcribes, and vice versa.
  String? get vadModelPath => _vadModelPath;
  VadModelFamily get vadModelFamily => _vadModelFamily;

  /// True when the persisted VAD selection could not be restored because the
  /// file it named is gone; neural mode refuses to start until one is picked.
  bool get vadSelectionMissing => _vadSelectionMissing;

  /// True when a real neural VAD model is selected and usable. Missing model =
  /// neural mode disabled, not a silent fall back to the energy gate.
  bool get neuralVadReady => _vadModelPath != null;

  /// Adopts a downloaded VAD bundle for the neural strategy. Refused while a
  /// run owns the engines, like [selectModel].
  void selectVad({
    required String path,
    VadModelFamily family = VadModelFamily.silero,
  }) {
    if (_engineBusy) return;
    _vadModelPath = path;
    _vadModelFamily = family;
    _vadSelectionMissing = false;
    _save('vad_model_path', path);
    _save('vad_model_family', family.name);
    notifyListeners();
  }

  /// Forgets the VAD selection (its bundle was deleted, or the user cleared
  /// it). The ASR and embedding selections are untouched.
  void clearVadSelection() {
    if (_vadModelPath == null && !_vadSelectionMissing) return;
    _vadModelPath = null;
    _vadModelFamily = VadModelFamily.silero;
    _vadSelectionMissing = false;
    _save('vad_model_path', '');
    _save('vad_model_family', '');
    notifyListeners();
  }

  /// The real VAD config the pages hand to [TranscriptionService.transcribe],
  /// or null unless the neural strategy is selected *and* a model exists. Null
  /// here means the caller must not start a neural job.
  NeuralVadSettings? get neuralVadSettings {
    final path = _vadModelPath;
    if (_chunkStrategy != ChunkStrategy.neural || path == null) return null;
    return NeuralVadSettings(
      modelPath: path,
      family: _vadModelFamily,
      threshold: _vadThreshold,
      minSilenceDuration: _vadMinSilenceSeconds,
      minSpeechDuration: _vadMinSpeechSeconds,
      speechPadMs: _vadPadMs,
      maxSpeechSeconds: _vadMaxSeconds,
    );
  }

  /// Identifies the current VAD knobs so a preview can tell when it has gone
  /// stale after a Settings change (plain value equality, no framework).
  String get neuralVadSignature => [
    _vadModelPath ?? '',
    _vadModelFamily.name,
    _vadThreshold,
    _vadMinSilenceSeconds,
    _vadMinSpeechSeconds,
    _vadPadMs,
    _vadMaxSeconds,
  ].join('|');

  void _restoreVadSelection() {
    final path = _nonEmpty(database.getSetting('vad_model_path'));
    if (path == null) return;
    final family = database.getSetting('vad_model_family');
    _vadModelFamily = VadModelFamily.values.firstWhere(
      (value) => value.name == family,
      orElse: () => VadModelFamily.silero,
    );
    if (File(path).existsSync()) {
      _vadModelPath = path;
    } else {
      // The file vanished: neural mode stays disabled rather than handing the
      // worker a path that no longer exists.
      _vadSelectionMissing = true;
    }
  }

  // ---------------------------------------------------------------------------
  // Neural VAD engine (independent of the ASR engine)
  // ---------------------------------------------------------------------------

  /// sherpa-onnx is the adapter that runs the supported neural VAD models, so
  /// worker is always a sherpa worker even when CrispASR (or anything else)
  /// transcribes. That separation is the point: neural VAD is not bound to one
  /// ASR engine.
  static const String vadEngineId = 'sherpa';

  AsrEngine? _vadEngine;
  bool _vadCancelled = false;

  /// The worker that runs [AsrEngine.planVad]/[TranscriptionService.previewVad].
  /// Built lazily and owned by this [AppState]; [dispose] releases it. Kept
  /// distinct from [engine] so a CrispASR ASR never has to carry a VAD.
  AsrEngine get vadEngine =>
      _vadEngine ??= engineRegistry.createAsr(vadEngineId, threads: _threads);

  /// The VAD worker, but only while neural mode can actually use it. Null for
  /// fixed/energy or a missing model, so those never spawn a worker isolate.
  AsrEngine? get activeVadEngine =>
      _chunkStrategy == ChunkStrategy.neural && neuralVadReady
      ? vadEngine
      : null;

  /// Cooperative cancel for an in-flight neural VAD plan. Safe to call when no
  /// VAD worker exists (nothing to abort).
  Future<void> cancelVad() async {
    final engine = _vadEngine;
    if (engine is CancellableAsrEngine) {
      _vadCancelled = true;
      await engine.cancel();
    }
  }

  /// Replaces a cancelled VAD worker with a fresh one. A [WorkerAsrEngine] keeps
  /// its cancel flag until a `load` resets it, and `planVad` never loads, so a
  /// retry after a cancel needs a new worker rather than a cleared flag.
  /// No-op when nothing was cancelled.
  void resetVadEngine() {
    if (!_vadCancelled) return;
    _vadCancelled = false;
    final engine = _vadEngine;
    _vadEngine = null;
    unawaited(engine?.dispose() ?? Future<void>.value());
  }

  /// Restores every chunking value (both strategies) to its default and
  /// persists it.
  void resetChunkSettings() {
    _chunkStrategy = ChunkStrategy.fixed;
    _chunkSeconds = defaultChunkSettings.chunkSeconds;
    _energyThreshold = defaultChunkSettings.energyThreshold;
    _speechPadMs = defaultChunkSettings.speechPadMs;
    _vadThreshold = defaultVadThreshold;
    _vadMinSilenceSeconds = defaultVadMinSilence;
    _vadMinSpeechSeconds = defaultVadMinSpeech;
    _vadPadMs = defaultVadPadMs;
    _vadMaxSeconds = defaultVadMaxSeconds;
    _save('chunk_mode', _chunkStrategy.name);
    _save('chunk_seconds', '$_chunkSeconds');
    _save('chunk_threshold', '$_energyThreshold');
    _save('chunk_pad_ms', '$_speechPadMs');
    _save('vad_threshold', '$_vadThreshold');
    _save('vad_min_silence', '$_vadMinSilenceSeconds');
    _save('vad_min_speech', '$_vadMinSpeechSeconds');
    _save('vad_pad_ms', '$_vadPadMs');
    _save('vad_max_seconds', '$_vadMaxSeconds');
    notifyListeners();
  }

  /// The exact fail-closed reason for a selection that may not be started.
  ///
  /// sherpa-mnn deliberately accepts only a catalog-trusted model plus tokens;
  /// a hand-picked `.mnn` never searches its directory for a guessed companion.
  ModelSelectionProblem? get modelSelectionProblem {
    final restoredProblem = _restoredSelectionProblem;
    if (restoredProblem != null) return restoredProblem;
    final spec = modelSpec;
    return spec == null
        ? null
        : selectionProblemFor(engineId: engineId, spec: spec);
  }

  /// Applies the same preflight rules to an arbitrary model/engine pair.
  /// Benchmark rows use this before invoking a per-entry native engine.
  static ModelSelectionProblem? selectionProblemFor({
    required String engineId,
    required EngineModelSpec spec,
  }) {
    if (engineId == 'sherpa-mnn') {
      if (spec.trustedBundleId == null ||
          spec.modelSizeBytes == null ||
          spec.modelSha256 == null) {
        return ModelSelectionProblem.sherpaMnnCatalogBundleRequired;
      }
      if (spec.tokensPath == null ||
          spec.tokensPath!.isEmpty ||
          spec.tokensSizeBytes == null ||
          spec.tokensSha256 == null) {
        return ModelSelectionProblem.sherpaMnnTokensRequired;
      }
    }
    if (engineId == 'sherpa' &&
        (spec.family ?? '') == 'whisper' &&
        (spec.decoderPath == null || spec.decoderPath!.isEmpty)) {
      return ModelSelectionProblem.missingWhisperDecoder;
    }
    return null;
  }

  /// Compatibility gate used by the existing pages. Despite the historical
  /// name, every typed [modelSelectionProblem] blocks startup.
  bool get selectionNeedsMissingCompanion => modelSelectionProblem != null;

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;

  // ---------------------------------------------------------------------------
  // Semantic search (embedding model + indexer)
  // ---------------------------------------------------------------------------

  Embedder? _embedder;
  SemanticIndexer? _indexer;
  String? _embeddingPath;
  EmbeddingModelProfile _embeddingProfile = EmbeddingModelProfile.metadata;
  String? _embeddingError;

  /// The live embedding model, or null when none is selected/loaded.
  Embedder? get embedder => _embedder;

  /// The persisted embedding model path, even when the model could not be
  /// loaded on this build (the Models page shows it and explains why).
  String? get embeddingPath => _embeddingPath;

  /// Input convention paired with [embeddingPath]. Persisted so a restored
  /// Qwen3 model keeps its required query instruction after an app restart.
  EmbeddingModelProfile get embeddingProfile => _embeddingProfile;

  /// True when a selected embedding model is really loaded and searchable.
  bool get embeddingReady => _embedder != null;

  /// Why the selected embedding model could not be loaded, or null.
  String? get embeddingError => _embeddingError;

  /// The write-side semantic indexer, or null until a model is loaded. History
  /// binds to its phase for status/retry/rebuild.
  SemanticIndexer? get indexer => _indexer;

  /// Selects a downloaded embedding bundle as the semantic model and persists
  /// the choice. The model loads asynchronously on its worker isolate; a
  /// construction/load failure (missing native library/model) is kept as
  /// [embeddingError] and never replaced with the deterministic test embedder.
  void selectEmbedding({
    required String path,
    EmbeddingModelProfile profile = EmbeddingModelProfile.metadata,
  }) {
    if (!_disposed) {
      _embeddingPath = path;
      _embeddingProfile = profile;
      _save('embedding_path', path);
      _save('embedding_profile', profile.name);
      _rebuildEmbedding();
      notifyListeners();
    }
  }

  /// Forgets the embedding model: search falls back to literal only.
  void clearEmbedding() {
    if (_disposed) return;
    _embeddingPath = null;
    _embeddingProfile = EmbeddingModelProfile.metadata;
    _save('embedding_path', '');
    _save('embedding_profile', '');
    _rebuildEmbedding();
    notifyListeners();
  }

  /// Backfills vectors for every live transcript this model has no vector for.
  Future<void> indexPending() async => _indexer?.indexPending();

  /// Re-indexes this model from scratch.
  Future<void> rebuildIndex() async => _indexer?.rebuild();

  void _restoreEmbedding() {
    final path = _nonEmpty(database.getSetting('embedding_path'));
    if (path == null) return;
    _embeddingPath = path;
    _embeddingProfile = EmbeddingModelProfile.parse(
      database.getSetting('embedding_profile'),
    );
    _rebuildEmbedding();
  }

  /// Drops the current embedder/indexer and starts an async rebuild from
  /// [_embeddingPath]. Any construction failure is state, not a fallback.
  void _rebuildEmbedding() {
    transcriptRepo.removeListener(_onTranscriptChanged);
    _indexer?.dispose();
    _indexer = null;
    _embedder?.dispose(); // the worker releases its native session and dies
    _embedder = null;
    _searchRepo = null; // rebuilt with the new embedder once it loads
    _embeddingError = null;

    final path = _embeddingPath;
    if (path == null || path.isEmpty) return;
    unawaited(_initEmbedding(path, _embeddingProfile));
  }

  /// Awaits the embedder factory (worker spawn + native load), and wires the
  /// indexer/search repo only on success — the UI thread never touches the
  /// native encode. A completion that is no longer current (model switched or
  /// AppState disposed while loading) releases its embedder instead of wiring
  /// a stale model into the new index.
  Future<void> _initEmbedding(
    String path,
    EmbeddingModelProfile profile,
  ) async {
    Embedder embedder;
    try {
      embedder = await _embedderFactory(path, profile, _threads);
    } on Object catch (error) {
      if (!_disposed &&
          _embeddingPath == path &&
          _embeddingProfile == profile) {
        _embeddingError = error.toString();
        notifyListeners();
      }
      return;
    }
    if (_disposed || _embeddingPath != path || _embeddingProfile != profile) {
      embedder.dispose();
      return;
    }
    _embedder = embedder;
    final indexer = SemanticIndexer(database, embedder: embedder);
    _indexer = indexer;
    // Every repo mutation (a new transcript, a restore) triggers a pending
    // pass; indexPending is idempotent, so a spurious run costs one SELECT.
    transcriptRepo.addListener(_onTranscriptChanged);
    _searchRepo = SearchRepo(database, embedder: embedder);
    // Backfill rows that were stored before the model was chosen.
    unawaited(indexer.indexPending());
    notifyListeners();
  }

  /// Bridges [TranscriptRepo]'s notification to a pending indexing pass,
  /// ignoring anything after [dispose].
  void _onTranscriptChanged() {
    if (_disposed) return;
    final indexer = _indexer;
    if (indexer != null) unawaited(indexer.indexPending());
  }

  bool _disposed = false;

  static ChunkStrategy _chunkStrategyFrom(String? raw) =>
      ChunkStrategy.values.any((strategy) => strategy.name == raw)
      ? ChunkStrategy.values.firstWhere((strategy) => strategy.name == raw)
      : ChunkStrategy.fixed;

  static double _boundedDouble(
    String? raw,
    double min,
    double max,
    double fallback,
  ) {
    final value = double.tryParse(raw ?? '');
    if (value == null || !value.isFinite || value < min || value > max) {
      return fallback;
    }
    return value;
  }

  static int _boundedInt(String? raw, int min, int max, int fallback) {
    final value = int.tryParse(raw ?? '');
    if (value == null || value < min || value > max) return fallback;
    return value;
  }

  static int _defaultThreads() {
    final half = Platform.numberOfProcessors ~/ 2;
    return half < 1 ? 1 : half;
  }

  @override
  void dispose() {
    _disposed = true;
    transcriptRepo.removeListener(_onTranscriptChanged);
    // The indexer drops queued jobs after dispose, and an in-flight embed
    // stops before its write, so a mid-teardown run cannot touch the closed
    // database or the disposed phase notifier. The embedder's worker gets the
    // same answer early: its pending calls fail on exit and the job swallows
    // the error as state.
    _indexer?.dispose();
    _embedder?.dispose();
    _engine?.dispose();
    _vadEngine?.dispose();
    database.close();
    super.dispose();
  }
}

/// Hands [AppState] to the widget tree without a state-management package.
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required AppState super.notifier,
    required super.child,
  });

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'No AppStateScope above this widget');
    return scope!.notifier!;
  }
}
