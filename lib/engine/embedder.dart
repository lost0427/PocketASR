/// Local text-embedding abstraction — engine- and model-agnostic.
///
/// Only [DeterministicEmbedder] ships today: the native CrispEmbed library is
/// not in the repo, so semantic search must stay honest instead of faking
/// meaning. A real `CrispEmbedder` implements [Embedder] later without touching
/// the UI or the data layer — the interface is the single swap point
/// (plan §2 / Phase 8).
library;

import 'dart:typed_data';

/// Turns text into a fixed-length embedding vector.
///
/// [embed] is synchronous because the reference CrispEmbed Dart API exposes a
/// synchronous `encode`; loading the model is a separate, asynchronous concern
/// owned by the implementation.
abstract class Embedder {
  /// Stable model id, e.g. `crispembed-gemma-300m`. Stored in the
  /// `embedding.model` column so a query is only compared against vectors
  /// produced by the same model.
  String get id;

  /// Length of the vectors this embedder produces.
  int get dim;

  /// Embeds [text]. The result may be unnormalized; the index normalizes it.
  Float32List embed(String text);

  /// Releases native resources.
  Future<void> dispose();
}

/// Deterministic, dependency-free [Embedder] for tests and as a fallback when
/// no native embedding library is bundled.
///
/// **Not a semantic model.** It hashes character bigrams into [dim] buckets, so
/// cosine similarity reflects shared surface n-grams, not meaning. It is a pure
/// function of the input (same text → same vector, every run), which is exactly
/// what makes it useful in tests. Swap in `CrispEmbedder` for real semantics.
class DeterministicEmbedder implements Embedder {
  DeterministicEmbedder({this.dim = 128});

  @override
  final int dim;

  @override
  String get id => 'deterministic-test';

  @override
  Float32List embed(String text) {
    final vector = Float32List(dim);
    final runes = text.toLowerCase().runes.toList();
    if (runes.length == 1) {
      vector[_hash(runes[0], runes[0]) % dim] += 1;
      return vector;
    }
    for (var i = 0; i + 1 < runes.length; i++) {
      vector[_hash(runes[i], runes[i + 1]) % dim] += 1;
    }
    return vector;
  }

  @override
  Future<void> dispose() async {}

  /// FNV-1a-style hash of a bigram, masked to 31 bits so it is a valid,
  /// platform-independent list index.
  static int _hash(int a, int b) {
    var hash = 0x811c9dc5;
    hash = ((hash ^ a) * 0x01000193) & 0xffffffff;
    hash = ((hash ^ b) * 0x01000193) & 0xffffffff;
    return hash & 0x7fffffff;
  }
}
