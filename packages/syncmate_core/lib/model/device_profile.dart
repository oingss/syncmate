/// 本机设备档案（身份 + 服务信息），用于 announce 广播、connect 请求与 device info 响应。
library;

import 'device_info.dart';

class DeviceProfile {
  const DeviceProfile({
    required this.alias,
    required this.deviceType,
    required this.fingerprint,
    required this.port,
    required this.protocol,
    this.appVersion,
  });

  final String alias;
  final String deviceType;
  final String fingerprint;
  final int port;
  final String protocol;
  final String? appVersion;

  DeviceInfo toInfo() => DeviceInfo(
        alias: alias,
        deviceType: deviceType,
        fingerprint: fingerprint,
        port: port,
        protocol: protocol,
        appVersion: appVersion,
      );
}
