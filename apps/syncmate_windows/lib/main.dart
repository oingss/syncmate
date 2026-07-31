import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncmate_core/syncmate_core.dart';

import 'app.dart';
import 'platform/prefs_key_value_store.dart';
import 'platform/windows_tray.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final kv = SharedPreferencesKeyValueStore(prefs);
  final identity = KeyValueIdentityProvider(kv);
  final trustStore = KeyValueTrustStore(kv);
  final profile = DeviceProfile(
    alias: '我的电脑',
    deviceType: 'windows',
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

  final tray = WindowsTray();
  final trayOk = await tray.init(
    onShow: () async {
      // 窗口已在托盘回调中 ShowWindow 恢复，此处仅留回调位
    },
    onExit: () async {
      await discovery.stop();
      await server.stop();
      exit(0);
    },
  );

  runApp(SyncMateWindowsApp(
    server: server,
    discovery: discovery,
    trustStore: trustStore,
    self: profile,
    auditLogPath: server.auditLogPath,
  ));

  if (!trayOk) {
    debugPrint('系统托盘不可用：关闭窗口将直接退出应用');
  } else {
    debugPrint('已驻留系统托盘：关闭窗口将隐藏到托盘，右键托盘图标可退出');
  }
}

/// 操作留痕路径：%APPDATA%\SyncMate\audit.log；不可写则返回 null（留痕关闭）。
String? _resolveAuditLogPath() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null) return null;
  final path = '$appData\\SyncMate\\audit.log';
  try {
    File(path).createSync(recursive: true);
    return path;
  } on Object {
    return null;
  }
}
