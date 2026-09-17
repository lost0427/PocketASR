/// Local text-embedding abstraction — engine- and model-agnostic.
///
/// Production embedding runs on a worker isolate (see embedding_worker.dart):
/// the native CrispEmbed FFI is synchronous, so keeping it off the UI thread is
/// a hard requirement, not an optimization. [DeterministicEmbedder] is
/// test-only; a build without the native library stays honest by failing with
/// [EmbedderUnavailableException] instead of faking meaning (plan §2 / Phase 8).
library;

import 'dart:async';
import 'dart:typed_data';

/// Input convention used by an embedding model.
///
/// [metadata] keeps using prefixes declared by the loaded GGUF. Qwen3's
/// official GGUF does not carry its SentenceTransformers query prompt, so its
/// canonical retrieval instruction is supplied explicitly here while indexed
/// documents remain unchanged.
enum EmbeddingModelProfile {
  metadata,
  qwen3;

  static EmbeddingModelProfile parse(String? value) => values.firstWhere(
    (profile) => profile.name == value,
    orElse: () => metadata,
  );

  static const _qwen3QueryPrefix =
      'Instruct: Given a web search query, retrieve relevant passages that '
      'answer the query\nQuery:';

  String queryInput(String text, {String metadataPrefix = ''}) =>
      '${this == qwen3 ? _qwen3QueryPrefix : metadataPrefix}$text';

  String documentInput(String text, {String metadataPrefix = ''}) =>
      '${this == qwen3 ? '' : metadataPrefix}$text';
}

/// Turns text into a fixed-length embedding vector.
///
/// The embed methods return [FutureOr] so both a synchronous test embedder and
/// the production worker-backed embedder ([WorkerEmbedder] in
/// embedding_worker.dart) satisfy the interface without ceremony. Callers that
/// need the vector `await` it — awaiting a plain [Float32List] is legal, so
/// synchronous implementations cost nothing at the call site. The native
/// CrispEmbed FFI is synchronous *by nature*, which is exactly why the real
/// instance lives on a worker isolate and never on the UI thread.
abstract class Embedder {
  /// Stable model id, e.g. `crispembed-gemma-300m`. Stored in the
  /// `embedding.model` column so a query is only compared against vectors
  /// produced by the same model.
  String get id;

  /// Length of the vectors this embedder produces. For worker-backed
  /// embedders it is only readable after the asynchronous load has completed.
  int get dim;

  /// Embeds [text]. The result may be unnormalized; the index normalizes it.
  FutureOr<Float32List> embed(String text);

  /// Embeds [text] as a search *query*. Identical to [embed] except for models
  /// trained with a query-side prompt (e.g. E5's `query: ` prefix); those
  /// overrides add the prompt only — never a different vector space.
  FutureOr<Float32List> embedQuery(String text) => embed(text);

  /// Embeds [text] as an indexed *document* (e.g. E5's `passage: ` prefix).
  /// Indexer writers must call this, not [embedQuery].
  FutureOr<Float32List> embedDocument(String text) => embed(text);

  /// Releases native resources.
  Future<void> dispose();
}

/// Raised when a native embedder library or model cannot be loaded.
///
/// Deliberately an error, with no fallback to [DeterministicEmbedder]: a silent
/// fallback would let semantic search return plausible-but-meaningless hits.
class EmbedderUnavailableException implements Exception {
  const EmbedderUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'EmbedderUnavailableException: $message';
}

/// Deterministic, dependency-free, *synchronous* [Embedder] for tests only.
///
/// Production must use the worker-backed embedder; this one runs on the calling
/// isolate, which for the UI thread is exactly what the worker exists to avoid.
///
/// **Not a semantic model.** It hashes character bigrams into [dim] buckets, so
/// cosine similarity reflects shared surface n-grams, not meaning. It is a pure
/// function of the input (same text → same vector, every run), which is exactly
/// what makes it useful in tests.
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

  // No prompt concept: the hash treats query and document identically.
  @override
  Float32List embedQuery(String text) => embed(text);

  @override
  Float32List embedDocument(String text) => embed(text);

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
