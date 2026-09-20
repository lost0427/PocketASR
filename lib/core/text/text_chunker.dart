/// Bounded text chunking for embedding input.
///
/// Embedding models take one sequence per vector, and the native encoder costs
/// grow superlinearly with its length: measured on the pinned Qwen3-Embedding
/// 0.6B q8 model, ~7.5 ms per character up to ~1k characters, rising to
/// 22.6 ms per character at 20k (attention is quadratic in tokens). Splitting a
/// transcript into budget-sized chunks therefore both speeds indexing up and
/// — because the native tokenizer *silently* truncates at the model's context
/// length (32k tokens for that model) — stops the tail of a long transcript
/// from becoming unsearchable.
library;

/// Upper bound on the tokens [text] costs the target model.
///
/// Deliberately an overestimate, in tenths of a token: CJK/kana/Hangul count as
/// 1.0 each (a BPE token covers 1-2 such characters) and everything else as 0.3
/// (Latin text averages ~4 characters per token). Dart has no tokenizer — the
/// native count is only readable from an API that runs a full forward pass — so
/// a chunk sized by this bound can never be silently truncated by the model.
int estimatedTokens(String text) => (_tenths(text) + 9) ~/ 10;

/// Splits [text] into chunks of at most [maxTokens] estimated tokens.
///
/// Boundaries fall on paragraph/sentence enders first, so a chunk holds whole
/// sentences; only a single sentence longer than the entire budget is hard-cut
/// by characters. No overlap: sentence boundaries already keep phrases intact,
/// and repeating text across chunks would bias the stored vectors toward it.
/// The chunks tile the trimmed input exactly, so no text is dropped.
List<String> chunkForEmbedding(String text, {int maxTokens = 512}) {
  if (maxTokens <= 0) {
    throw ArgumentError.value(maxTokens, 'maxTokens', 'must be positive');
  }
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];

  final budget = maxTokens * 10;
  final chunks = <String>[];
  final current = StringBuffer();
  var used = 0;

  void flush() {
    if (used == 0) return;
    chunks.add(current.toString());
    current.clear();
    used = 0;
  }

  for (final atom in _atoms(trimmed, budget)) {
    final cost = _tenths(atom);
    if (used > 0 && used + cost > budget) flush();
    current.write(atom);
    used += cost;
  }
  flush();
  return chunks;
}

/// Sentence-ish atoms, then hard cuts for any atom over [budget] tenths.
/// Atoms concatenate back to exactly [text].
Iterable<String> _atoms(String text, int budget) sync* {
  for (final sentence in _sentences(text)) {
    if (_tenths(sentence) <= budget) {
      yield sentence;
      continue;
    }
    final piece = StringBuffer();
    var used = 0;
    for (final rune in sentence.runes) {
      final cost = _runeTenths(rune);
      if (used > 0 && used + cost > budget) {
        yield piece.toString();
        piece.clear();
        used = 0;
      }
      piece.writeCharCode(rune);
      used += cost;
    }
    if (used > 0) yield piece.toString();
  }
}

/// Splits after each boundary character, keeping it, so [text] is tiled.
Iterable<String> _sentences(String text) sync* {
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    if (_boundaries.contains(text.codeUnitAt(i))) {
      yield text.substring(start, i + 1);
      start = i + 1;
    }
  }
  if (start < text.length) yield text.substring(start);
}

/// Sentence enders in both scripts plus the paragraph break. Newlines count so
/// paragraphs split even when the transcriber emitted no punctuation.
final Set<int> _boundaries = '。！？!?.;；\n'.codeUnits.toSet();

int _tenths(String text) {
  var sum = 0;
  for (final rune in text.runes) {
    sum += _runeTenths(rune);
  }
  return sum;
}

/// 0x2E80 opens CJK radicals, and the range covers Han, kana, Hangul, fullwidth
/// forms and punctuation — all scripts whose characters are near one token each.
int _runeTenths(int rune) => rune >= 0x2E80 ? 10 : 3;
