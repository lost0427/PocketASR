import 'package:characters/characters.dart';

/// Grapheme-cluster count used by the engine-independent chars/s metric.
/// Emoji and combining marks count once, so `'你好🙂'` is 3, not 4.
int graphemeCount(String text) => text.characters.length;

/// Grapheme clusters per second, or null when [elapsed] is non-positive.
double? graphemesPerSecond(String text, Duration elapsed) {
  final millis = elapsed.inMilliseconds;
  if (millis <= 0) return null;
  return graphemeCount(text) * 1000 / millis;
}
