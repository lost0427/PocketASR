import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../core/update/release_check.dart';
import '../../core/update/windows_updater.dart';
import '../../l10n/app_localizations.dart';

class _Progress {
  const _Progress(this.label, this.fraction);

  final String label;
  final double? fraction;
}

Future<void> handleAvailableUpdate(
  BuildContext context,
  AppState state,
  ReleaseInfo info,
) async {
  final l10n = AppLocalizations.of(context);
  final installable = Platform.isWindows && info.sha256 != null;
  final installPath = File(Platform.resolvedExecutable).parent.path;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.settingsUpdateAvailableTitle),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.settingsUpdateAvailableBody(info.version)),
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                l10n.settingsUpdateNotes,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(info.notes),
            ],
            if (installable) ...[
              const SizedBox(height: 12),
              Text(
                l10n.updateInstallPath(installPath),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.updateLater),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            installable
                ? l10n.updateDownloadAndInstall
                : l10n.settingsUpdateDownload,
          ),
        ),
      ],
    ),
  );
  if (accepted != true) {
    state.skippedUpdateVersion = info.version;
    return;
  }
  if (!context.mounted) return;
  if (!installable) {
    await _openPage(context, info.downloadUrl);
    return;
  }
  await _install(context, info, installPath);
}

Future<void> _openPage(BuildContext context, String url) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened) throw StateError('No browser available');
  } on Object catch (error) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('${l10n.settingsUpdateFailed}: $error')),
      );
  }
}

Future<void> _install(
  BuildContext context,
  ReleaseInfo info,
  String installPath,
) async {
  final l10n = AppLocalizations.of(context);
  final navigator = Navigator.of(context);
  final updater = WindowsUpdater(
    info: info,
    installDirectory: Directory(installPath),
  );
  final progress = ValueNotifier<_Progress>(
    _Progress(l10n.updateDownloadingUnknown, null),
  );
  var cancelled = false;

  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(l10n.updateInProgress),
        content: ValueListenableBuilder<_Progress>(
          valueListenable: progress,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: value.fraction),
              const SizedBox(height: 12),
              Text(value.label),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => cancelled = true,
            child: Text(l10n.transcribeCancel),
          ),
        ],
      ),
    ),
  );

  try {
    await updater.preflight();
    await updater.download(
      onProgress: (received, total) => progress.value = _Progress(
        total > 0
            ? l10n.updateDownloading(received * 100 ~/ total)
            : l10n.updateDownloadingUnknown,
        total > 0 ? received / total : null,
      ),
      isCancelled: () => cancelled,
    );
    if (cancelled) throw const UpdateCancelled();
    if (cancelled) throw const UpdateCancelled();
    progress.value = _Progress(l10n.updateExtracting, null);
    await updater.extract(isCancelled: () => cancelled);
    if (cancelled) throw const UpdateCancelled();
    progress.value = _Progress(l10n.updateRestarting, null);
    await Future<void>.delayed(const Duration(seconds: 1));
    if (cancelled) throw const UpdateCancelled();
    await updater.applyAndExit();
  } on UpdateCancelled {
    if (context.mounted) navigator.pop();
  } on Object catch (error) {
    if (!context.mounted) return;
    navigator.pop();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.updateFailed),
        content: Text('$error'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
  } finally {
    progress.dispose();
  }
}
