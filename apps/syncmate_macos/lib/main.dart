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
    alias: '我的 Mac',
    deviceType: 'macos',
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

  runApp(SyncMateMacosApp(
    server: server,
    discovery: discovery,
    trustStore: trustStore,
    self: profile,
    auditLogPath: server.auditLogPath,
  ));
}

/// 操作留痕路径：$HOME/Library/Application Support/SyncMate/audit.log；
/// 不可写则返回 null（留痕关闭）。
String? _resolveAuditLogPath() {
  final home = Platform.environment['HOME'];
  if (home == null) return null;
  final path = '$home/Library/Application Support/SyncMate/audit.log';
  try {
    File(path).createSync(recursive: true);
    return path;
  } on Object {
    return null;
  }
}
