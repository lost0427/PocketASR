/// Minimal engine/embedder registry — the plan §2 swap point, no DI package.
///
/// Builds concrete [AsrEngine]s and [Embedder]s by stable id so callers (and
/// tests) can select an implementation without importing every adapter. The app
/// still defaults to [UnavailableAsrEngine]; real engines are opt-in via
/// [createAsr].
library;

import 'asr_engine.dart';
import 'crispasr_engine.dart';
import 'embedder.dart';
import 'sherpa_engine.dart';

/// Builds one [AsrEngine] instance.
typedef AsrEngineBuilder = AsrEngine Function();

/// Builds one [Embedder] instance.
typedef EmbedderBuilder = Embedder Function();

/// Registry of built-in and caller-supplied engine builders.
///
/// Overrides are merged over the built-ins, so a caller can swap `sherpa` for a
/// preconfigured instance without touching this file.
class EngineRegistry {
  EngineRegistry({
    Map<String, AsrEngineBuilder>? asrBuilders,
    Map<String, EmbedderBuilder>? embedderBuilders,
  }) : _asrBuilders = {..._builtinAsr, ...?asrBuilders},
       _embedderBuilders = {..._builtinEmbedders, ...?embedderBuilders};

  static final Map<String, AsrEngineBuilder> _builtinAsr = {
    'unavailable': () => const UnavailableAsrEngine(),
    'crispasr': () => CrispAsrEngine(),
    'sherpa': () => SherpaEngine(),
  };

  static final Map<String, EmbedderBuilder> _builtinEmbedders = {
    'deterministic': () => DeterministicEmbedder(),
    // 'crispembed' is intentionally absent: it needs a model path, so callers
    // register it via `embedderBuilders` once they know which model to load.
  };

  final Map<String, AsrEngineBuilder> _asrBuilders;
  final Map<String, EmbedderBuilder> _embedderBuilders;

  /// Ids that [createAsr] accepts.
  List<String> get asrEngineIds => _asrBuilders.keys.toList(growable: false);

  /// Ids that [createEmbedder] accepts.
  List<String> get embedderIds => _embedderBuilders.keys.toList(growable: false);

  /// Builds the ASR engine registered as [id]; throws [ArgumentError] on a miss.
  AsrEngine createAsr(String id) =>
      _build(_asrBuilders, id, 'ASR engine');

  /// Builds the embedder registered as [id]; throws [ArgumentError] on a miss.
  Embedder createEmbedder(String id) =>
      _build(_embedderBuilders, id, 'embedder');

  static T _build<T>(
    Map<String, T Function()> builders,
    String id,
    String kind,
  ) {
    final builder = builders[id];
    if (builder == null) {
      throw ArgumentError.value(
        id,
        'id',
        'unknown $kind (have: ${builders.keys.join(', ')})',
      );
    }
    return builder();
  }
}
