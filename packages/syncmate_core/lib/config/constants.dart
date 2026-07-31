/// SyncMate 协议常量，与 docs/protocol.md 保持一致（文档为准，代码同步）。
library;

abstract final class Constants {
  static const int protocolVersion = 1;

  static const String multicastGroup = '224.0.0.170';
  static const int multicastPort = 53321;
  static const Duration announceInterval = Duration(seconds: 5);
  static const Duration onlineTtl = Duration(seconds: 30);

  static const int httpPort = 53320;
  static const String protocol = 'http';
  static const String appVersion = '0.1.0';

  static const Duration connectTimeout = Duration(seconds: 60);
  static const Duration uploadSessionTimeout = Duration(seconds: 60);

  static const Duration wsHeartbeatInterval = Duration(seconds: 15);
  static const Duration wsHeartbeatTimeout = Duration(seconds: 30);
  static const Duration wsReconnectMin = Duration(seconds: 1);
  static const Duration wsReconnectMax = Duration(seconds: 60);
  static const String wsPath = '/api/clipboard/ws';
  static const Duration wsConnectFallbackDelay = Duration(seconds: 60);

  static const String partFileSuffix = '.sm-part';

  static final RegExp fingerprintPattern = RegExp(r'^[0-9A-F]{64}$');
}
