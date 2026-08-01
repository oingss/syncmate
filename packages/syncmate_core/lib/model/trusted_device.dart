/// 已信任设备（本地持久化条目）。
library;

class TrustedDevice {
  const TrustedDevice({
    required this.fingerprint,
    required this.alias,
    required this.deviceType,
    required this.port,
    this.lastConnected,
  });

  factory TrustedDevice.fromJson(Map<String, dynamic> json) {
    return TrustedDevice(
      fingerprint: json['fingerprint'] as String,
      alias: json['alias'] as String,
      deviceType: json['deviceType'] as String,
      port: (json['port'] as num).toInt(),
      lastConnected: json['lastConnected'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['lastConnected'] as int)
          : null,
    );
  }

  final String fingerprint;
  final String alias;
  final String deviceType;
  final int port;
  final DateTime? lastConnected;

  TrustedDevice copyWith({String? alias, DateTime? lastConnected}) {
    return TrustedDevice(
      fingerprint: fingerprint,
      alias: alias ?? this.alias,
      deviceType: deviceType,
      port: port,
      lastConnected: lastConnected ?? this.lastConnected,
    );
  }

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'alias': alias,
        'deviceType': deviceType,
        'port': port,
        if (lastConnected != null)
          'lastConnected': lastConnected!.millisecondsSinceEpoch,
      };
}
