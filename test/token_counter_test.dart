import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/text/token_counter.dart';

void main() {
  test('graphemeCount counts clusters, not code units', () {
    expect(graphemeCount('你好'), 2);
    expect(graphemeCount('你好🙂'), 3); // not 4: emoji is one cluster
    expect(graphemeCount('abc'), 3);
    expect(graphemeCount('e\u0301'), 1); // e + combining acute
    expect(graphemeCount(''), 0);
  });

  test('graphemesPerSecond guards non-positive durations', () {
    expect(graphemesPerSecond('你好', Duration.zero), isNull);
    expect(graphemesPerSecond('你好', const Duration(seconds: 1)), 2);
    expect(graphemesPerSecond('abcd', const Duration(milliseconds: 500)), 8);
  });
}
