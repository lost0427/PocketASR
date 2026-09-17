import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../l10n/app_localizations.dart';

/// Completed WAVs stay in documents so history keeps a valid audio path.
class RecordingControls extends StatefulWidget {
  const RecordingControls({
    super.key,
    required this.enabled,
    required this.onBusy,
    required this.onRecorded,
    this.recorderFactory = AudioRecorder.new,
    this.directoryProvider = getApplicationDocumentsDirectory,
  });

  final bool enabled;
  final ValueChanged<bool> onBusy;
  final ValueChanged<String> onRecorded;
  final AudioRecorder Function() recorderFactory;
  final Future<Directory> Function() directoryProvider;

  @override
  State<RecordingControls> createState() => _RecordingControlsState();
}

class _RecordingControlsState extends State<RecordingControls> {
  AudioRecorder? _recorder;
  Directory? _pendingDirectory;
  Future<void>? _operation;
  bool _changing = false;
  bool _recording = false;
  String? _error;
  final _clock = Stopwatch();
  Timer? _timer;

  void _run(Future<void> Function() action) {
    if (_changing) return;
    setState(() {
      _changing = true;
      _error = null;
    });
    widget.onBusy(true);
    _operation = _perform(action);
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
      // Keep a possibly active session accessible for Stop/Cancel retry.
    } finally {
      if (mounted) {
        setState(() => _changing = false);
        widget.onBusy(_recording);
      }
    }
  }

  Future<void> _start() async {
    final denied = AppLocalizations.of(context).recordPermissionDenied;
    final recorder = _recorder ??= widget.recorderFactory();
    if (!await recorder.hasPermission()) {
      if (mounted) setState(() => _error = denied);
      return;
    }
    if (!mounted) return;
    final root = await widget.directoryProvider();
    final recordings = await Directory('${root.path}/recordings')
        .create(recursive: true);
    _pendingDirectory = await recordings.createTemp('recording-');
    try {
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: '${_pendingDirectory!.path}/recording.wav',
      );
      _recording = true;
      _clock
        ..reset()
        ..start();
      if (mounted) {
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() {});
        });
      }
    } catch (_) {
      await recorder.cancel();
      await _deletePending();
      rethrow;
    }
  }

  Future<void> _finish({required bool discard}) async {
    final emptyMessage = AppLocalizations.of(context).recordEmpty;
    if (discard) {
      await _recorder!.cancel();
    } else {
      final path = await _recorder!.stop();
      if (path == null ||
          !await File(path).exists() ||
          await File(path).length() <= 44) {
        throw StateError(emptyMessage);
      }
      _pendingDirectory = null;
      if (mounted) widget.onRecorded(path);
    }
    _recording = false;
    _clock.stop();
    _timer?.cancel();
    await _deletePending();
  }

  Future<void> _deletePending() async {
    final directory = _pendingDirectory;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
    _pendingDirectory = null;
  }

  Future<void> _release() async {
    await _operation;
    try {
      if (_recording) await _recorder?.cancel();
    } finally {
      try {
        await _recorder?.dispose();
      } finally {
        await _deletePending();
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(
      _release().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(exception: error, stack: stack),
        );
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_recording) ...[
          Text(l10n.recordElapsed(_clock.elapsed.inSeconds)),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 12,
          children: [
            OutlinedButton.icon(
              onPressed: _changing || (!_recording && !widget.enabled)
                  ? null
                  : () => _run(
                      _recording ? () => _finish(discard: false) : _start,
                    ),
              icon: Icon(_recording ? Icons.stop : Icons.mic),
              label: Text(_recording ? l10n.recordStop : l10n.recordStart),
            ),
            if (_recording)
              TextButton(
                onPressed: _changing
                    ? null
                    : () => _run(() => _finish(discard: true)),
                child: Text(l10n.recordDiscard),
              ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }
}
