import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/features/bench/seven_tap.dart';

void main() {
  Widget host(VoidCallback onTriggered) => MaterialApp(
    home: Scaffold(
      body: SevenTapGate(onTriggered: onTriggered, child: const Text('tap')),
    ),
  );

  testWidgets('fires only after seven consecutive taps', (tester) async {
    var fired = 0;
    await tester.pumpWidget(host(() => fired++));

    for (var i = 0; i < 6; i++) {
      await tester.tap(find.text('tap'));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(fired, 0, reason: 'six taps must not trigger');

    await tester.tap(find.text('tap'));
    await tester.pump();
    expect(fired, 1);
  });

  testWidgets('a pause longer than the window resets the count', (
    tester,
  ) async {
    var fired = 0;
    await tester.pumpWidget(host(() => fired++));

    for (var i = 0; i < 6; i++) {
      await tester.tap(find.text('tap'));
      await tester.pump(const Duration(milliseconds: 50));
    }
    // Idle past the default 3 s window: the six taps are forgotten.
    await tester.pump(const Duration(seconds: 4));

    await tester.tap(find.text('tap'));
    await tester.pump();
    expect(fired, 0, reason: 'a single tap after the reset must not trigger');

    // Flush the timer this last tap scheduled.
    await tester.pump(const Duration(seconds: 4));
  });
}
