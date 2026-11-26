import 'package:flutter/services.dart';

import 'remote_protocol.dart';

const MethodChannel pairLinkChannel = MethodChannel('pocket_asr/pair_link');

Future<void> listenForPairLinks(
  Future<void> Function(RemotePairLink link) onLink,
) async {
  Future<void> handle(String? raw) async {
    if (raw == null) return;
    final link = RemotePairLink.parse(raw);
    if (link != null) await onLink(link);
  }

  pairLinkChannel.setMethodCallHandler((call) async {
    if (call.method == 'pairLink') await handle(call.arguments as String?);
    return null;
  });
  try {
    await handle(await pairLinkChannel.invokeMethod<String>('pendingPairLink'));
  } on Object {
    // Desktop builds have no pair-link channel.
  }
}
