/// 设备发现服务：UDP 组播 announce 收发 + 在线表（TTL 过期）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/constants.dart';
import '../model/device_profile.dart';
import 'announce.dart';

class DiscoveredDevice {
  const DiscoveredDevice({
    required this.alias,
    required this.deviceType,
    required this.fingerprint,
    required this.port,
    required this.protocol,
    required this.address,
    required this.lastSeen,
    this.appVersion,
  });

  final String alias;
  final String deviceType;
  final String fingerprint;
  final int port;
  final String protocol;
  final InternetAddress address;
  final DateTime lastSeen;
  final String? appVersion;

  String get baseUrl => 'http://${address.address}:$port';

  DiscoveredDevice copyWith({DateTime? lastSeen, String? alias}) {
    return DiscoveredDevice(
      alias: alias ?? this.alias,
      deviceType: deviceType,
      fingerprint: fingerprint,
      port: port,
      protocol: protocol,
      address: address,
      lastSeen: lastSeen ?? this.lastSeen,
      appVersion: appVersion,
    );
  }
}

sealed class DiscoveryEvent {}

class DeviceDiscovered extends DiscoveryEvent {
  DeviceDiscovered(this.device);
  final DiscoveredDevice device;
}

class DeviceUpdated extends DiscoveryEvent {
  DeviceUpdated(this.device);
  final DiscoveredDevice device;
}

class DeviceExpired extends DiscoveryEvent {
  DeviceExpired(this.device);
  final DiscoveredDevice device;
}

class DiscoveryService {
  DiscoveryService({
    required Future<DeviceProfile> Function() profileProvider,
  }) : _profileProvider = profileProvider;

  final Future<DeviceProfile> Function() _profileProvider;
  final StreamController<DiscoveryEvent> _events =
      StreamController<DiscoveryEvent>.broadcast();
  final Map<String, DiscoveredDevice> _devices = {};

  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  Timer? _cleanupTimer;
  String? _myFingerprint;
  bool _running = false;

  Stream<DiscoveryEvent> get events => _events.stream;

  List<DiscoveredDevice> get devices => List.unmodifiable(_devices.values);

  Future<void> start() async {
    if (_running) return;
    _running = true;
    final profile = await _profileProvider();
    _myFingerprint = profile.fingerprint;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      Constants.multicastPort,
      reuseAddress: true,
    );
    _socket = socket;
    socket.joinMulticast(InternetAddress(Constants.multicastGroup));
    socket.multicastHops = 1;
    socket.listen(_onSocketEvent);
    await announceNow();
    _announceTimer = Timer.periodic(
      Constants.announceInterval,
      (_) => unawaited(announceNow()),
    );
    _cleanupTimer = Timer.periodic(const Duration(seconds: 10), (_) => _cleanup());
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _announceTimer?.cancel();
    _cleanupTimer?.cancel();
    _socket?.close();
    _socket = null;
    _devices.clear();
    await _events.close();
  }

  Future<void> announceNow() async {
    final socket = _socket;
    if (socket == null) return;
    final profile = await _profileProvider();
    final payload =
        utf8.encode(jsonEncode(AnnounceMessage.fromProfile(profile).toJson()));
    socket.send(payload, InternetAddress(Constants.multicastGroup), Constants.multicastPort);
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _socket?.receive();
    if (datagram == null) return;
    final text = utf8.decode(datagram.data, allowMalformed: true);
    final message = AnnounceMessage.tryParse(text);
    if (!message.isValid || message.fingerprint == _myFingerprint) return;
    final now = DateTime.now();
    final device = DiscoveredDevice(
      alias: message.alias,
      deviceType: message.deviceType,
      fingerprint: message.fingerprint,
      port: message.port,
      protocol: message.protocol,
      address: datagram.address,
      lastSeen: now,
      appVersion: message.appVersion,
    );
    final existing = _devices[device.fingerprint];
    if (existing == null) {
      _devices[device.fingerprint] = device;
      _events.add(DeviceDiscovered(device));
    } else {
      final updated = existing.copyWith(
        lastSeen: now,
        alias: device.alias != existing.alias ? device.alias : null,
      );
      _devices[device.fingerprint] = updated;
      _events.add(DeviceUpdated(updated));
    }
  }

  void _cleanup() {
    final cutoff = DateTime.now().subtract(Constants.onlineTtl);
    final expired = _devices.values.where((d) => d.lastSeen.isBefore(cutoff)).toList();
    for (final device in expired) {
      _devices.remove(device.fingerprint);
      _events.add(DeviceExpired(device));
    }
  }
}
