import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:syncmate_core/syncmate_core.dart';

import 'pages/home_page.dart';

/// 顶部深色标题栏配色（与状态栏融合，图标为浅色）。
const _kAppBarBg = Color(0xFF1B1F24);
const _kAppBarFg = Color(0xFFECEDEE);

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
    final colorScheme = ColorScheme.fromSeed(seedColor: Colors.teal);
    return MaterialApp(
      title: 'SyncMate',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF4F5F6),
        appBarTheme: AppBarTheme(
          backgroundColor: _kAppBarBg,
          foregroundColor: _kAppBarFg,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          systemOverlayStyle: SystemUiOverlayStyle.light.copyWith(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            statusBarBrightness: Brightness.dark,
          ),
          titleTextStyle: const TextStyle(
            color: _kAppBarFg,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
          iconTheme: const IconThemeData(color: _kAppBarFg),
        ),
        dividerColor: const Color(0xFFE1E3E5),
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
