import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';

import '../../app/app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../remote/remote_job_repo.dart';
import '../../remote/remote_outbox.dart';
import '../../remote/remote_protocol.dart';

class RemoteTargetBar extends StatelessWidget {
  const RemoteTargetBar({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (state.remoteHosts.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(
          label: Text(l10n.remoteThisDevice),
          selected: state.remoteTarget == null,
          onSelected: (_) => state.remoteTarget = null,
        ),
        for (final host in state.remoteHosts)
          ChoiceChip(
            avatar: Icon(
              state.hostOnline(host.id) ? Icons.computer : Icons.computer_outlined,
              size: 16,
            ),
            label: Text(host.name),
            selected: state.remoteTarget == host.id,
            onSelected: (_) => state.remoteTarget = host.id,
          ),
      ],
    );
  }
}

String remoteStageText(AppLocalizations l10n, String? stage) => switch (stage) {
  'decoding' => l10n.transcribeStageDecoding,
  'analyzing' => l10n.transcribeStageAnalyzing,
  'segmenting' => l10n.transcribeStageSegmenting,
  'loadingModel' => l10n.transcribeStageLoadingModel,
  'transcribing' => l10n.transcribeStageTranscribing,
  'finalizing' => l10n.transcribeStageFinalizing,
  _ => l10n.remoteStatusRunning,
};

class RemoteOutboxCard extends StatelessWidget {
  const RemoteOutboxCard({super.key, required this.state, this.hostId});

  final AppState state;
  final String? hostId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: state.remoteOutbox,
      builder: (context, _) {
        final items = [
          for (final item in state.remoteOutbox.items)
            if (hostId == null || item.hostId == hostId) item,
        ];
        if (items.isEmpty) return const SizedBox.shrink();
        final shown = items.take(3).toList();
        return Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              for (final item in shown)
                ListTile(
                  dense: true,
                  leading: Icon(_icon(item.status), color: scheme.primary),
                  title: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _line(l10n, item),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.text != null)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: l10n.transcribeCopy,
                          icon: const Icon(Icons.copy_all_outlined, size: 18),
                          onPressed: () => Clipboard.setData(
                            ClipboardData(text: item.text!),
                          ),
                        ),
                      if (item.status == OutboxStatus.failed &&
                          item.sourcePath != null)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: l10n.remoteRetry,
                          icon: const Icon(Icons.refresh, size: 18),
                          onPressed: () => state.remoteOutbox.retry(item),
                        ),
                      if (item.status == OutboxStatus.waiting ||
                          item.status == OutboxStatus.running)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: l10n.remoteWithdraw,
                          icon: const Icon(Icons.cancel_outlined, size: 18),
                          onPressed: () => state.remoteOutbox.withdraw(item),
                        ),
                      if (item.status == OutboxStatus.done ||
                          item.status == OutboxStatus.cancelled ||
                          item.status == OutboxStatus.failed)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: l10n.remoteDismiss,
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => state.remoteOutbox.dismiss(item),
                        ),
                    ],
                  ),
                ),
              if (items.length > shown.length)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Text(
                    l10n.remoteMore(items.length - shown.length),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  String _line(AppLocalizations l10n, OutboxItem item) => switch (item.status) {
    OutboxStatus.uploading =>
      l10n.remoteUploading(
        item.totalBytes == 0
            ? 0
            : (item.uploadedBytes * 100 ~/ item.totalBytes),
      ),
    OutboxStatus.waiting => l10n.remoteWaiting,
    OutboxStatus.running =>
      '${remoteStageText(l10n, item.stage)}'
          '${item.ratio == null ? '' : ' ${(item.ratio! * 100).round()}%'}',
    OutboxStatus.done => l10n.remoteSaved,
    OutboxStatus.cancelled => l10n.remoteStatusCancelled,
    OutboxStatus.failed => item.error ?? l10n.remoteStatusFailed,
  };

  IconData _icon(OutboxStatus status) => switch (status) {
    OutboxStatus.uploading => Icons.upload,
    OutboxStatus.waiting => Icons.schedule,
    OutboxStatus.running => Icons.sync,
    OutboxStatus.done => Icons.check_circle,
    OutboxStatus.failed => Icons.error_outline,
    OutboxStatus.cancelled => Icons.cancel,
  };
}

class RemoteInboxSection extends StatelessWidget {
  const RemoteInboxSection({
    super.key,
    required this.state,
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 12),
  });

  final AppState state;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: state.remoteJobs,
      builder: (context, _) {
        final jobs = state.remoteJobs.listAll();
        if (jobs.isEmpty) return const SizedBox.shrink();
        return Card(
          elevation: 0,
          margin: margin,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Text(
                  l10n.remoteInbox,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              for (final job in jobs.take(3)) _row(context, l10n, scheme, job),
              if (jobs.length > 3)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Text(
                    l10n.remoteMore(jobs.length - 3),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
    RemoteJob job,
  ) {
    final canRun =
        job.status == RemoteJobStatus.pending &&
        !state.engineBusy &&
        state.modelSpec != null &&
        state.modelSelectionProblem == null;
    return ListTile(
      dense: true,
      leading: Icon(_icon(job.status), color: scheme.primary),
      title: Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        _line(l10n, job),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (job.status == RemoteJobStatus.pending)
            TextButton(
              onPressed: canRun ? () => state.runRemoteJob(job) : null,
              child: Text(
                state.modelSpec == null
                    ? l10n.remoteModelRequired
                    : l10n.remoteRun,
              ),
            ),
          if (job.status == RemoteJobStatus.running)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: l10n.remoteCancel,
              icon: const Icon(Icons.cancel_outlined, size: 18),
              onPressed: () => state.cancelRemoteJob(job.id),
            ),
          if (job.status == RemoteJobStatus.done)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: l10n.remoteViewText,
              icon: const Icon(Icons.article_outlined, size: 18),
              onPressed: () => _showText(context, l10n, job),
            ),
          if (job.status != RemoteJobStatus.running)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: l10n.remoteDelete,
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => state.remoteJobs.delete(job.id),
            ),
        ],
      ),
    );
  }

  String _line(AppLocalizations l10n, RemoteJob job) {
    if (job.status == RemoteJobStatus.failed) {
      return job.error ?? l10n.remoteStatusFailed;
    }
    if (job.status == RemoteJobStatus.cancelled) {
      return l10n.remoteStatusCancelled;
    }
    if (job.status == RemoteJobStatus.done) {
      return '${l10n.remoteStatusDone} · ${job.modelFamily ?? ''} '
          '${job.modelQuant ?? ''}';
    }
    final stage = remoteStageText(l10n, job.stage);
    final ratio = job.ratio;
    return ratio == null
        ? stage
        : '$stage ${(ratio * 100).round()}%';
  }

  IconData _icon(RemoteJobStatus status) => switch (status) {
    RemoteJobStatus.pending => Icons.schedule,
    RemoteJobStatus.running => Icons.sync,
    RemoteJobStatus.done => Icons.check_circle,
    RemoteJobStatus.failed => Icons.error_outline,
    RemoteJobStatus.cancelled => Icons.cancel,
  };

  Future<void> _showText(
    BuildContext context,
    AppLocalizations l10n,
    RemoteJob job,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(job.title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: SelectableText(job.text ?? ''),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (job.text != null) {
              Clipboard.setData(ClipboardData(text: job.text!));
            }
          },
          child: Text(l10n.transcribeCopy),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    ),
  );
}

class HostServerSection extends StatefulWidget {
  const HostServerSection({super.key, required this.state});

  final AppState state;

  @override
  State<HostServerSection> createState() => _HostServerSectionState();
}

class _HostServerSectionState extends State<HostServerSection> {
  List<String> _addresses = const [];
  String? _selected;

  @override
  void initState() {
    super.initState();
    _loadAddresses();
  }

  Future<void> _loadAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = [
        for (final interface in interfaces)
          for (final address in interface.addresses) address.address,
      ]..sort((a, b) => _rank(a).compareTo(_rank(b)));
      if (!mounted) return;
      setState(() {
        _addresses = addresses;
        _selected = addresses.isEmpty ? null : addresses.first;
      });
    } catch (_) {}
  }

  static int _rank(String address) {
    if (address.startsWith('192.168.')) return 0;
    if (address.startsWith('10.')) return 1;
    if (address.startsWith('172.')) return 2;
    if (address.startsWith('100.')) return 3;
    return 4;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final state = widget.state;
    return ListenableBuilder(
      listenable: Listenable.merge([state, state.remoteServer]),
      builder: (context, _) {
        final code = state.remoteServer.pairCode;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              elevation: 0,
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    title: Text(l10n.remoteServerEnable),
                    subtitle: Text(l10n.remoteServerEnableHint),
                    value: state.remoteServerEnabled,
                    onChanged: (value) => state.remoteServerEnabled = value,
                  ),
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    title: Text(l10n.remoteAutoRun),
                    subtitle: Text(l10n.remoteAutoRunHint),
                    value: state.remoteAutoRun,
                    onChanged: state.remoteServerEnabled
                        ? (value) => state.remoteAutoRun = value
                        : null,
                  ),
                  if (state.remoteServerError != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Text(
                        state.remoteServerError!,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  if (state.remoteServerEnabled) ...[
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.remoteServerPort('$remoteDefaultPort'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          Text(l10n.remoteServerAddresses),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final address in _addresses)
                                ChoiceChip(
                                  label: Text(address),
                                  selected: _selected == address,
                                  onSelected: (_) =>
                                      setState(() => _selected = address),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (code.isEmpty)
                            OutlinedButton.icon(
                              onPressed: state.remoteServer.startPairing,
                              icon: const Icon(Icons.qr_code_2),
                              label: Text(l10n.remoteShowCode),
                            )
                          else ...[
                            Wrap(
                              spacing: 16,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (_selected != null)
                                  QrView(
                                    data: RemotePairLink(
                                      hostId: state.hostId,
                                      name: state.hostName,
                                      host: _selected!,
                                      port: remoteDefaultPort,
                                      code: code,
                                    ).toUri().toString(),
                                  ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      code,
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineMedium
                                          ?.copyWith(letterSpacing: 6),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      l10n.remoteCodeHint,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              l10n.remoteScanHint,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.remoteFirewallHint,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Text(l10n.remoteDevices),
            const SizedBox(height: 6),
            for (final device in state.remoteAuth.devices())
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.phone_android),
                title: Text(device.name),
                subtitle: Text(
                  device.lastSeenAt == null
                      ? l10n.remoteOffline
                      : '${l10n.remoteOnline} · '
                            '${device.lastSeenAt!.toString().split('.').first}',
                ),
                trailing: IconButton(
                  tooltip: l10n.remoteUnpair,
                  icon: const Icon(Icons.link_off),
                  onPressed: () => setState(
                    () => state.remoteAuth.removeDevice(device.id),
                  ),
                ),
              ),
            if (state.remoteAuth.devices().isEmpty)
              Text(
                l10n.remoteNoDevices,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        );
      },
    );
  }
}

class ComputerLinkSection extends StatelessWidget {
  const ComputerLinkSection({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.remoteLinkHint, style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          for (final host in state.remoteHosts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                state.hostOnline(host.id)
                    ? Icons.computer
                    : Icons.computer_outlined,
              ),
              title: Text(host.name),
              subtitle: Text('${host.host}:${host.port}'),
              trailing: IconButton(
                tooltip: l10n.remoteUnpair,
                icon: const Icon(Icons.link_off),
                onPressed: () => state.removeRemoteHost(host.id),
              ),
            ),
          if (state.remoteHosts.isEmpty)
            Text(l10n.remoteNoComputer, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _add(context),
            icon: const Icon(Icons.add_link),
            label: Text(l10n.remoteAddComputer),
          ),
        ],
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final address = TextEditingController();
    final port = TextEditingController(text: '$remoteDefaultPort');
    final code = TextEditingController();
    String? error;
    var busy = false;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.remoteAddComputer),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.remoteScanHint),
              TextField(
                controller: address,
                decoration: InputDecoration(labelText: l10n.remoteAddress),
                keyboardType: TextInputType.url,
              ),
              TextField(
                controller: port,
                decoration: InputDecoration(labelText: l10n.remotePort),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: code,
                decoration: InputDecoration(labelText: l10n.remotePairCode),
                keyboardType: TextInputType.number,
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.of(context).pop(),
              child: Text(l10n.transcribeCancel),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await state.pairHost(
                          host: address.text.trim(),
                          port: int.tryParse(port.text.trim()) ??
                              remoteDefaultPort,
                          code: code.text.trim(),
                        );
                        if (context.mounted) Navigator.of(context).pop();
                      } on Object catch (failure) {
                        setState(() {
                          busy = false;
                          error = '$failure';
                        });
                      }
                    },
              child: Text(busy ? l10n.remotePairing : l10n.remotePair),
            ),
          ],
        ),
      ),
    );
    address.dispose();
    port.dispose();
    code.dispose();
  }
}

class QrView extends StatelessWidget {
  const QrView({super.key, required this.data, this.size = 160});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final image = QrImage(
      QrCode(
        payload: QrPayload.fromString(data),
        errorCorrectLevel: QrErrorCorrectLevel.medium,
      ),
    );
    return Container(
      width: size,
      height: size,
      color: Colors.white,
      child: CustomPaint(painter: _QrPainter(image)),
    );
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter(this.image);

  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final count = image.moduleCount;
    final module = size.width / (count + 8);
    final paint = Paint()..color = Colors.black;
    for (var row = 0; row < count; row++) {
      for (var col = 0; col < count; col++) {
        if (!image.isDark(row, col)) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (col + 4) * module,
            (row + 4) * module,
            module + 0.5,
            module + 0.5,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.image != image;
}
