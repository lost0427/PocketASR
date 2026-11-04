final RegExp _consecutivePeriods = RegExp(r'[。.](?:[ \t]*[。.])+');

/// Collapses runs of Chinese/English periods into one Chinese full stop.
///
/// Requires at least two periods, so decimals (`3.14`) and abbreviations
/// (`e.g.`) are left untouched. Spaces and tabs between periods are absorbed;
/// newlines are not, so paragraph boundaries stay intact.
String mergeConsecutivePeriods(String text) =>
    text.replaceAll(_consecutivePeriods, '。');
