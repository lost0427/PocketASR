import 'package:characters/characters.dart';

/// Grapheme-cluster count — the "字/s" figure for CJK users.
///
/// This is a display helper, *not* a model token count: tokens/s comes from the
/// engine's own tokenizer (plan §1.4). Emoji and combining marks count once, so
/// `'你好🙂'` is 3, not 4.
int graphemeCount(String text) => text.characters.length;

/// Grapheme clusters per second, or null when [elapsed] is non-positive.
double? graphemesPerSecond(String text, Duration elapsed) {
  final millis = elapsed.inMilliseconds;
  if (millis <= 0) return null;
  return graphemeCount(text) * 1000 / millis;
}
