import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
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
    alias: '我的 iPhone',
    deviceType: 'ios',
    fingerprint: await identity.identity,
    port: Constants.httpPort,
    protocol: Constants.protocol,
    appVersion: Constants.appVersion,
  );
  // iOS 沙箱无全局文件根，以 App 文档目录作为存储根（无插件拿不到该路径）。
  final docs = await getApplicationDocumentsDirectory();
  final server = SyncMateServer(
    self: profile,
    trustStore: trustStore,
    fileSystem: LocalFileSystemAdapter(roots: [docs.path]),
    auditLogPath: _resolveAuditLogPath(docs.path),
  );
  final discovery = DiscoveryService(profileProvider: () async => profile);
  await server.start();
  await discovery.start();

  runApp(SyncMateIosApp(
    server: server,
    discovery: discovery,
    trustStore: trustStore,
    self: profile,
    auditLogPath: server.auditLogPath,
  ));
}

/// 操作留痕路径：App 文档目录；iOS 沙箱内始终可写。
String? _resolveAuditLogPath(String docsPath) {
  final path = '$docsPath${Platform.pathSeparator}syncmate_audit.log';
  try {
    File(path).createSync(recursive: true);
    return path;
  } on Object {
    return null;
  }
}
