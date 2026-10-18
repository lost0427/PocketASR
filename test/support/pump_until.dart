import 'package:flutter_test/flutter_test.dart';

/// Waits for real I/O while also advancing widget-test microtasks and frames.
Future<void> pumpUntil(WidgetTester tester, bool Function() isComplete) async {
  final elapsed = Stopwatch()..start();
  while (!isComplete()) {
    if (elapsed.elapsed > const Duration(seconds: 5)) {
      fail('Timed out waiting for the asynchronous operation to complete');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}
