/// 设备信息（对应 docs/schemas/device_info.schema.json）。
library;

class DeviceInfo {
  const DeviceInfo({
    required this.alias,
    required this.deviceType,
    required this.fingerprint,
    required this.port,
    required this.protocol,
    this.appVersion,
    this.osVersion,
    this.storageFree,
    this.storageTotal,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    return DeviceInfo(
      alias: json['alias'] as String,
      deviceType: json['deviceType'] as String,
      fingerprint: json['fingerprint'] as String,
      port: (json['port'] as num).toInt(),
      protocol: json['protocol'] as String,
      appVersion: json['appVersion'] as String?,
      osVersion: json['osVersion'] as String?,
      storageFree: (json['storageFree'] as num?)?.toInt(),
      storageTotal: (json['storageTotal'] as num?)?.toInt(),
    );
  }

  final String alias;
  final String deviceType;
  final String fingerprint;
  final int port;
  final String protocol;
  final String? appVersion;
  final String? osVersion;
  final int? storageFree;
  final int? storageTotal;

  Map<String, dynamic> toJson() => {
        'alias': alias,
        'deviceType': deviceType,
        'fingerprint': fingerprint,
        'port': port,
        'protocol': protocol,
        if (appVersion != null) 'appVersion': appVersion,
        if (osVersion != null) 'osVersion': osVersion,
        if (storageFree != null) 'storageFree': storageFree,
        if (storageTotal != null) 'storageTotal': storageTotal,
      };
}
