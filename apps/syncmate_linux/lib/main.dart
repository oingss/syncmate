import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncmate_core/syncmate_core.dart';

import 'app.dart';
import 'platform/prefs_key_value_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final kv = SharedPreferencesKeyValueStore(prefs);
  final identity = KeyValueIdentityProvider(kv);
  final trustStore = KeyValueTrustStore(kv);
  final profile = DeviceProfile(
    alias: '我的 Linux',
    deviceType: 'linux',
    fingerprint: await identity.identity,
    port: Constants.httpPort,
    protocol: Constants.protocol,
    appVersion: Constants.appVersion,
  );
  final server = SyncMateServer(
    self: profile,
    trustStore: trustStore,
    auditLogPath: _resolveAuditLogPath(),
  );
  final discovery = DiscoveryService(profileProvider: () async => profile);
  await server.start();
  await discovery.start();

  runApp(SyncMateLinuxApp(
    server: server,
    discovery: discovery,
    trustStore: trustStore,
    self: profile,
    auditLogPath: server.auditLogPath,
  ));
}

/// 操作留痕路径：$XDG_DATA_HOME/syncmate/audit.log
/// （未设置 XDG_DATA_HOME 时退回 $HOME/.local/share）；不可写则返回 null。
String? _resolveAuditLogPath() {
  final xdg = Platform.environment['XDG_DATA_HOME'];
  final home = Platform.environment['HOME'];
  final base = (xdg != null && xdg.isNotEmpty)
      ? xdg
      : (home != null && home.isNotEmpty ? '$home/.local/share' : null);
  if (base == null) return null;
  final path = '$base/syncmate/audit.log';
  try {
    File(path).createSync(recursive: true);
    return path;
  } on Object {
    return null;
  }
}
