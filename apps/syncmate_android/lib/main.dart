import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncmate_core/syncmate_core.dart';

import 'app.dart';
import 'platform/foreground_service.dart';
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
  // 前台服务：切后台后进程仍存活，文件服务与剪切板轮询保持在线
  await ForegroundService.start();
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
