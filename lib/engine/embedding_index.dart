import 'dart:math' as math;
import 'dart:typed_data';

/// One scored row from [EmbeddingIndex.search].
class EmbeddingHit {
  const EmbeddingHit(this.id, this.score);

  /// Caller-defined row id (the transcript id).
  final int id;

  /// Cosine similarity in [-1, 1]; higher is closer.
  final double score;
}

/// Brute-force cosine index over the `embedding` table.
///
/// Vectors are L2-normalized on [put], so [search] only needs a dot product.
/// The database stays the source of truth: rebuild the index from stored rows
/// per query (plan Phase 8).
///
/// ponytail: O(n) scan, ~10 ms at n=10k. Add IVF/quantization only when the
/// index exceeds ~20k rows or queries become visibly janky — no vector DB now.
class EmbeddingIndex {
  EmbeddingIndex(this.dim);

  /// Expected vector length; [put]/[search] reject anything else.
  final int dim;

  final Map<int, Float32List> _vectors = {};

  int get length => _vectors.length;

  /// Stores [vector] under [id], normalized, replacing any previous value.
  void put(int id, Float32List vector) {
    _checkLength(vector);
    _vectors[id] = normalize(vector);
  }

  /// Top [topK] rows by cosine similarity to [query], best first.
  List<EmbeddingHit> search(Float32List query, {int topK = 20}) {
    if (topK <= 0 || _vectors.isEmpty) return const [];
    _checkLength(query);
    final unit = normalize(query);
    final hits = [
      for (final entry in _vectors.entries)
        EmbeddingHit(entry.key, dot(unit, entry.value)),
    ];
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.length <= topK ? hits : hits.sublist(0, topK);
  }

  /// Returns a new L2-normalized copy of [vector]. A zero vector stays zero,
  /// so a bad/empty embedding scores 0 against everything instead of NaN.
  static Float32List normalize(Float32List vector) {
    var sum = 0.0;
    for (final value in vector) {
      sum += value * value;
    }
    final norm = math.sqrt(sum);
    if (norm == 0) return Float32List(vector.length);
    final out = Float32List(vector.length);
    for (var i = 0; i < vector.length; i++) {
      out[i] = vector[i] / norm;
    }
    return out;
  }

  /// Dot product. Equals cosine similarity when both inputs are unit vectors.
  static double dot(Float32List a, Float32List b) {
    final length = a.length < b.length ? a.length : b.length;
    var sum = 0.0;
    for (var i = 0; i < length; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }

  void _checkLength(Float32List vector) {
    if (vector.length != dim) {
      throw ArgumentError.value(
        vector.length,
        'vector',
        'expected $dim dimensions',
      );
    }
  }
}
