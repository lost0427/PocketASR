import 'dart:async';

import 'package:flutter/material.dart';

/// Fires [onTriggered] once [taps] taps land within [window] of each other.
///
/// This is the hidden-benchmark gesture: the counter resets as soon as the user
/// pauses, so a stray tap in passing never adds to it. Used on the Settings
/// version row to enter, and on the Benchmark title to leave.
class SevenTapGate extends StatefulWidget {
  const SevenTapGate({
    super.key,
    required this.child,
    required this.onTriggered,
    this.taps = 7,
    this.window = const Duration(seconds: 3),
  });

  final Widget child;

  /// Called after the final tap; the counter is cleared first.
  final VoidCallback onTriggered;

  /// How many taps are needed.
  final int taps;

  /// Idle time after which the count resets.
  final Duration window;

  @override
  State<SevenTapGate> createState() => _SevenTapGateState();
}

class _SevenTapGateState extends State<SevenTapGate> {
  int _count = 0;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  void _handleTap() {
    _reset?.cancel();
    _count++;
    if (_count >= widget.taps) {
      _count = 0;
      widget.onTriggered();
      return;
    }
    _reset = Timer(widget.window, () {
      if (mounted) setState(() => _count = 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _handleTap,
      borderRadius: BorderRadius.circular(12),
      child: widget.child,
    );
  }
}
