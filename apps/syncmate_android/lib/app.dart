import 'package:flutter/material.dart';
import 'package:syncmate_core/syncmate_core.dart';

import 'pages/home_page.dart';

class SyncMateAndroidApp extends StatelessWidget {
  const SyncMateAndroidApp({
    super.key,
    required this.server,
    required this.discovery,
    required this.trustStore,
    required this.self,
    this.auditLogPath,
  });

  final SyncMateServer server;
  final DiscoveryService discovery;
  final TrustStore trustStore;
  final DeviceProfile self;
  final String? auditLogPath;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SyncMate',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: HomePage(
        server: server,
        discovery: discovery,
        trustStore: trustStore,
        self: self,
        auditLogPath: auditLogPath,
      ),
    );
  }
}
