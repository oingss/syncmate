/// 组播广播报文（对应 docs/schemas/announce.schema.json）。
library;

import 'dart:convert';

import '../model/device_profile.dart';

class AnnounceMessage {
  const AnnounceMessage({
    required this.v,
    required this.alias,
    required this.deviceType,
    required this.fingerprint,
    required this.port,
    required this.protocol,
    this.appVersion,
  });

  factory AnnounceMessage.fromProfile(DeviceProfile profile) {
    return AnnounceMessage(
      v: 1,
      alias: profile.alias,
      deviceType: profile.deviceType,
      fingerprint: profile.fingerprint,
      port: profile.port,
      protocol: profile.protocol,
      appVersion: profile.appVersion,
    );
  }

  factory AnnounceMessage.tryParse(String text) {
    final json = _tryDecode(text);
    if (json == null) return _invalid();
    try {
      final v = (json['v'] as num?)?.toInt();
      final alias = json['alias'] as String?;
      final deviceType = json['deviceType'] as String?;
      final fingerprint = json['fingerprint'] as String?;
      final port = (json['port'] as num?)?.toInt();
      final protocol = json['protocol'] as String?;
      if (v != 1 ||
          alias == null ||
          alias.isEmpty ||
          deviceType == null ||
          fingerprint == null ||
          fingerprint.length != 64 ||
          port == null ||
          protocol == null) {
        return _invalid();
      }
      return AnnounceMessage(
        v: v!,
        alias: alias,
        deviceType: deviceType,
        fingerprint: fingerprint,
        port: port,
        protocol: protocol,
        appVersion: json['appVersion'] as String?,
      );
    } on Object {
      return _invalid();
    }
  }

  static AnnounceMessage _invalid() => const AnnounceMessage(
        v: -1,
        alias: '',
        deviceType: '',
        fingerprint: '',
        port: -1,
        protocol: '',
      );

  static Map<String, dynamic>? _tryDecode(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  final int v;
  final String alias;
  final String deviceType;
  final String fingerprint;
  final int port;
  final String protocol;
  final String? appVersion;

  bool get isValid =>
      v == 1 &&
      alias.isNotEmpty &&
      fingerprint.length == 64 &&
      port > 0 &&
      protocol.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'v': v,
        'alias': alias,
        'deviceType': deviceType,
        'fingerprint': fingerprint,
        'port': port,
        'protocol': protocol,
        if (appVersion != null) 'appVersion': appVersion,
      };
}
