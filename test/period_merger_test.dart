import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/text/period_merger.dart';

void main() {
  test('merges runs of Chinese and English periods', () {
    expect(mergeConsecutivePeriods('你好。。。'), '你好。');
    expect(mergeConsecutivePeriods('hello...'), 'hello。');
    expect(mergeConsecutivePeriods('a.。.b'), 'a。b');
    expect(mergeConsecutivePeriods('a。 \t.b'), 'a。b');
    expect(mergeConsecutivePeriods('a。\n.b'), 'a。\n.b');
  });

  test('leaves single periods and decimals alone', () {
    expect(mergeConsecutivePeriods('你好。'), '你好。');
    expect(mergeConsecutivePeriods('3.14'), '3.14');
    expect(mergeConsecutivePeriods('e.g. test'), 'e.g. test');
  });
}
