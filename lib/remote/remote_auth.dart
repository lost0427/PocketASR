import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../data/db.dart';

const String remoteDevicesKey = 'remote_devices';

class RemoteDevice {
  const RemoteDevice({
    required this.id,
    required this.name,
    required this.hash,
    required this.createdAt,
    this.lastSeenAt,
  });

  final String id;
  final String name;
  final String hash;
  final DateTime createdAt;
  final DateTime? lastSeenAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'hash': hash,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'lastSeenAt': lastSeenAt?.millisecondsSinceEpoch,
  };

  factory RemoteDevice.fromJson(Map<String, dynamic> json) => RemoteDevice(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    hash: json['hash'] as String? ?? '',
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      json['createdAt'] as int? ?? 0,
    ),
    lastSeenAt: json['lastSeenAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(json['lastSeenAt'] as int),
  );

  RemoteDevice seen() => RemoteDevice(
    id: id,
    name: name,
    hash: hash,
    createdAt: createdAt,
    lastSeenAt: DateTime.now(),
  );
}

final Random _random = Random.secure();

String randomHex(int bytes) => List.generate(
  bytes,
  (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

String newRemoteToken() => randomHex(24);

String newPairCode() => List.generate(
  6,
  (_) => _random.nextInt(10),
).join();

String remoteTokenHash(String token) =>
    sha256.convert(utf8.encode(token)).toString();

bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

class RemoteAuth {
  RemoteAuth(this._db);

  final AppDatabase _db;

  List<RemoteDevice> devices() {
    final raw = _db.getSetting(remoteDevicesKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final item in list)
          RemoteDevice.fromJson(item as Map<String, dynamic>),
      ];
    } catch (_) {
      return [];
    }
  }

  void saveDevices(List<RemoteDevice> devices) => _db.setSetting(
    remoteDevicesKey,
    jsonEncode([for (final device in devices) device.toJson()]),
  );

  RemoteDevice? deviceForToken(String token) {
    final hash = remoteTokenHash(token);
    for (final device in devices()) {
      if (constantTimeEquals(device.hash, hash)) return device;
    }
    return null;
  }

  RemoteDevice addDevice(String name) {
    final token = newRemoteToken();
    final device = RemoteDevice(
      id: 'd_${randomHex(6)}',
      name: name,
      hash: remoteTokenHash(token),
      createdAt: DateTime.now(),
      lastSeenAt: DateTime.now(),
    );
    saveDevices([...devices(), device]);
    return device;
  }

  void touch(String id) {
    final list = devices();
    var changed = false;
    for (var i = 0; i < list.length; i++) {
      if (list[i].id == id) {
        list[i] = list[i].seen();
        changed = true;
      }
    }
    if (changed) saveDevices(list);
  }
}
