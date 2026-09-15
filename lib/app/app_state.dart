import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../engine/asr_engine.dart' show AsrEngine, Backend;
import '../engine/engine_registry.dart';
import '../data/db.dart';
import '../data/search_repo.dart';
import '../data/transcript_repo.dart';

/// App-wide settings.
///
/// Theme and language are tri-state: [ThemeMode.system] and a `null` [locale]
/// mean "follow the device". The model/quant, thread count and loudness values
/// round out the Settings tab. Persistence lands in Phase 5 (settings table),
/// so for now every value lives in memory only.
class AppState extends ChangeNotifier {
  final AppDatabase database = AppDatabase.open();
  late final TranscriptRepo transcriptRepo = TranscriptRepo(database);
  late final SearchRepo searchRepo = SearchRepo(database);
  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;
  set themeMode(ThemeMode value) {
    if (value == _themeMode) return;
    _themeMode = value;
    notifyListeners();
  }

  Locale? _locale;
  /// `null` means follow the system language.
  Locale? get locale => _locale;
  set locale(Locale? value) {
    if (value == _locale) return;
    _locale = value;
    notifyListeners();
  }

  /// Model family the transcribe flow loads; one of the allowlist families.
  String _modelFamily = 'sensevoice';
  String get modelFamily => _modelFamily;
  set modelFamily(String value) {
    if (value == _modelFamily) return;
    _modelFamily = value;
    notifyListeners();
  }

  /// Quantization tag (`q8_0`, `q4_k`, `q6_k`). Registry default is Q4_K.
  String _modelQuant = 'q4_k';
  String get modelQuant => _modelQuant;
  set modelQuant(String value) {
    if (value == _modelQuant) return;
    _modelQuant = value;
    notifyListeners();
  }

  /// Builds engines by id. Held here so the app picks a real adapter without a
  /// DI package; tests can override [engineRegistry] before touching [engine].
  final EngineRegistry engineRegistry = EngineRegistry();

  /// Real engine preferred by default: sherpa-onnx's Flutter plugin bundles its
  /// own natives, so it is the one adapter that can be genuinely available on a
  /// stock build. CrispASR stays selectable via [engineId] once staged.
  static const String defaultEngineId = 'sherpa';

  String _engineId = defaultEngineId;
  String get engineId => _engineId;
  set engineId(String value) {
    if (value == _engineId) return;
    _engineId = value;
    _engine = null; // rebuild lazily for the new id
    notifyListeners();
  }

  AsrEngine? _engine;

  /// The selected [AsrEngine], built once per [engineId] so native probes are
  /// not repeated on every widget rebuild. Whether it can actually run is a
  /// runtime fact the UI reads from `engine.capabilities()`.
  AsrEngine get engine => _engine ??= engineRegistry.createAsr(_engineId);

  /// Compute backend. Fixed to CPU for the first release (decision D17); kept
  /// as state so a picker can be added later without touching callers.
  Backend _backend = Backend.cpu;
  Backend get backend => _backend;
  set backend(Backend value) {
    if (value == _backend) return;
    _backend = value;
    notifyListeners();
  }

  /// Worker threads for the CPU path. Defaults to half the cores.
  int _threads = _defaultThreads();
  int get threads => _threads;
  set threads(int value) {
    final capped = value < 1 ? 1 : (value > maxThreads ? maxThreads : value);
    if (capped == _threads) return;
    _threads = capped;
    notifyListeners();
  }

  /// Cores the device reports; the thread slider's upper bound.
  int get maxThreads => Platform.numberOfProcessors;

  /// Whether loudness normalization runs before transcription.
  bool _loudnessEnabled = true;
  bool get loudnessEnabled => _loudnessEnabled;
  set loudnessEnabled(bool value) {
    if (value == _loudnessEnabled) return;
    _loudnessEnabled = value;
    notifyListeners();
  }

  /// Target integrated loudness in LUFS for loudness normalization.
  double _loudnessTargetLufs = -16.0;
  double get loudnessTargetLufs => _loudnessTargetLufs;
  set loudnessTargetLufs(double value) {
    if (value == _loudnessTargetLufs) return;
    _loudnessTargetLufs = value;
    notifyListeners();
  }

  static int _defaultThreads() {
    final half = Platform.numberOfProcessors ~/ 2;
    return half < 1 ? 1 : half;
  }

  @override
  void dispose() {
    _engine?.dispose();
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
