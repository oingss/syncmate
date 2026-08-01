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
    alias: '我的手机',
    deviceType: 'android',
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
  // 前台服务不再无条件启动：仅当与其他设备建立连接且应用切到后台时，
  // 由 HomePage 依据 ClipboardService 的连接状态按需启停（见 home_page.dart）。
  runApp(SyncMateAndroidApp(
    server: server,
    discovery: discovery,
    trustStore: trustStore,
    self: profile,
    auditLogPath: server.auditLogPath,
  ));
}

/// 操作留痕路径：尝试 systemTemp（内部存储，无插件依赖）；不可写返回 null。
String? _resolveAuditLogPath() {
  final path = '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'syncmate_audit.log';
  try {
    File(path).createSync(recursive: true);
    return path;
  } on Object {
    return null;
  }
}
