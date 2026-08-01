/// 剪切板同步服务：与在线信任设备建立 WS 连接、防回声去重、心跳与重连。
///
/// 连接协商（协议 §5.1 细化）：每对设备只保留一条连接——fingerprint
/// 较小者主动发起（出站），较大者仅监听（入站）；较大者若 60s 内未等到
/// 入站连接则兜底主动发起，服务端按指纹去重旧连接。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/constants.dart';
import '../discovery/discovery_service.dart';
import '../model/device_profile.dart';
import '../security/trust_store.dart';
import 'clipboard_backend.dart';
import 'clipboard_message.dart';

class _PeerSession {
  _PeerSession.outgoing(String this.fingerprint, String this.baseUrl)
      : inboundSend = null;

  _PeerSession.incoming(String this.fingerprint, void Function(String) send)
      : baseUrl = null,
        inboundSend = send;

  final String fingerprint;

  /// 出站连接的目标地址（ws://host:port）；入站为 null。
  final String? baseUrl;

  /// 入站连接的回发通道；出站为 null。
  final void Function(String data)? inboundSend;

  WebSocket? ws;
  int backoffSeconds = 1;
  bool closing = false;
  DateTime lastRx = DateTime.now();
  Timer? reconnectTimer;

  bool get incoming => inboundSend != null;

  void send(String data) {
    if (incoming) {
      inboundSend!(data);
    } else {
      ws?.add(data);
    }
  }
}

class ClipboardService {
  ClipboardService({
    required DeviceProfile self,
    required TrustStore trustStore,
    required DiscoveryService discovery,
    required ClipboardBackend backend,
    Stream<ClipboardServerEvent>? serverEvents,
  })  : _self = self,
        _trustStore = trustStore,
        _discovery = discovery,
        _backend = backend {
    _discoverySub = discovery.events.listen(_onDiscoveryEvent);
    serverEvents?.listen(_onServerEvent);
    _backendSub = backend.changes.listen(_onBackendChanged);
  }

  final DeviceProfile _self;
  final TrustStore _trustStore;
  final DiscoveryService _discovery;
  final ClipboardBackend _backend;
  final Map<String, _PeerSession> _sessions = {};
  final Map<String, DateTime> _peerFirstSeen = {};
  final StreamController<void> _state = StreamController.broadcast();
  late final StreamSubscription<DiscoveryEvent> _discoverySub;
  StreamSubscription<ClipboardServerEvent>? _serverSub;
  late final StreamSubscription<ClipboardSnapshot> _backendSub;
  Timer? _pingTimer;
  Timer? _reconcileTimer;
  String? _lastSentHash;
  String? _lastReceivedHash;
  bool _enabled = false;

  /// 状态变化通知（开关、连接数变化）。
  Stream<void> get state => _state.stream;

  bool get enabled => _enabled;

  List<String> get connectedFingerprints => List.of(_sessions.keys);

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (value) {
      unawaited(_reconcile());
      _pingTimer = Timer.periodic(
        Constants.wsHeartbeatInterval,
        (_) => _pingAll(),
      );
      _reconcileTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (_enabled) unawaited(_reconcile());
      });
    } else {
      _pingTimer?.cancel();
      _reconcileTimer?.cancel();
      for (final session in _sessions.values) {
        _closeSession(session);
      }
      _sessions.clear();
    }
    _state.add(null);
  }

  Future<void> dispose() async {
    setEnabled(false);
    await _discoverySub.cancel();
    await _serverSub?.cancel();
    await _backendSub.cancel();
    _backend.dispose();
    await _state.close();
  }

  Future<void> _onDiscoveryEvent(DiscoveryEvent event) async {
    if (event is DeviceExpired) {
      _peerFirstSeen.remove(event.device.fingerprint);
      _closeSessionFingerprint(event.device.fingerprint);
      return;
    }
    final device = switch (event) {
      DeviceDiscovered(:final device) => device,
      DeviceUpdated(:final device) => device,
      DeviceExpired() => throw StateError('unreachable'),
    };
    if (device.fingerprint == _self.fingerprint || !_enabled) return;
    final trusted = await _trustStore.find(device.fingerprint);
    if (trusted == null) return;
    _peerFirstSeen.putIfAbsent(device.fingerprint, DateTime.now);
    if (_sessions.containsKey(device.fingerprint)) return;
    if (_shouldConnect(device.fingerprint)) {
      _startOutgoing(device);
    }
  }

  void _onServerEvent(ClipboardServerEvent event) {
    if (!_enabled) return;
    switch (event) {
      case ClipboardConnected():
        final conn = event.connection;
        if (conn.fingerprint == _self.fingerprint) return;
        if (_sessions.containsKey(conn.fingerprint)) return; // 服务端已去重
        _sessions[conn.fingerprint] =
            _PeerSession.incoming(conn.fingerprint, conn.send);
        _state.add(null);
      case ClipboardDisconnected():
        final session = _sessions[event.fingerprint];
        if (session == null || !session.incoming) return;
        _sessions.remove(event.fingerprint);
        _state.add(null);
      case ClipboardMessageReceived():
        _onMessage(event.message);
    }
  }

  bool _shouldConnect(String fingerprint) {
    if (_self.fingerprint.compareTo(fingerprint) < 0) return true;
    final firstSeen = _peerFirstSeen[fingerprint];
    if (firstSeen == null) return false;
    return DateTime.now().difference(firstSeen) >=
        Constants.wsConnectFallbackDelay;
  }

  /// 周期/开关扫描：为所有在线且受信任的远端建立出站连接（幂等，
  /// 已存在会话或尚未到兜底时机则跳过）。
  Future<void> _reconcile() async {
    if (!_enabled) return;
    for (final device in _discovery.devices) {
      if (device.fingerprint == _self.fingerprint) continue;
      if (_sessions.containsKey(device.fingerprint)) continue;
      final trusted = await _trustStore.find(device.fingerprint);
      if (trusted == null) continue;
      _peerFirstSeen.putIfAbsent(device.fingerprint, DateTime.now);
      if (_shouldConnect(device.fingerprint)) {
        _startOutgoing(device);
      }
    }
  }

  void _startOutgoing(DiscoveredDevice device) {
    final session =
        _PeerSession.outgoing(device.fingerprint, device.baseUrl);
    _sessions[device.fingerprint] = session;
    _state.add(null);
    unawaited(_connectOutgoing(session));
  }

  Future<void> _connectOutgoing(_PeerSession session) async {
    if (session.closing || !_enabled) return;
    final baseUrl = session.baseUrl;
    if (baseUrl == null) return;
    try {
      final wsUri =
          Uri.parse(baseUrl).replace(scheme: 'ws', path: Constants.wsPath);
      final ws = await WebSocket.connect(
        wsUri.toString(),
        headers: {_headerFingerprint: _self.fingerprint},
      ).timeout(Constants.connectTimeout);
      if (session.closing || !_enabled) {
        await ws.close();
        return;
      }
      session.ws = ws;
      session.backoffSeconds = 1;
      session.lastRx = DateTime.now();
      _state.add(null);
      ws.listen(
        (data) => _onSocketData(session, data),
        onDone: () => _onSocketDone(session),
        onError: (Object _) => _onSocketDone(session),
      );
    } on Object {
      _onSocketDone(session);
    }
  }

  void _onSocketData(_PeerSession session, dynamic data) {
    session.lastRx = DateTime.now();
    if (data is! String) return;
    if (data == '{"type":"ping"}') {
      session.send('{"type":"pong"}');
      return;
    }
    final message = ClipboardMessage.tryParse(data);
    if (message != null) _onMessage(message);
  }

  void _onSocketDone(_PeerSession session) {
    if (session.closing) return;
    session.ws = null;
    if (!_enabled) return;
    final delay = Duration(seconds: session.backoffSeconds);
    final maxBackoff = Constants.wsReconnectMax.inSeconds;
    session.backoffSeconds = session.backoffSeconds * 2 > maxBackoff
        ? maxBackoff
        : session.backoffSeconds * 2;
    session.reconnectTimer = Timer(delay, () {
      if (_enabled && !session.closing) {
        unawaited(_connectOutgoing(session));
      }
    });
  }

  void _pingAll() {
    final now = DateTime.now();
    for (final session in _sessions.values) {
      if (session.incoming) continue;
      if (session.ws != null) {
        session.send('{"type":"ping"}');
        if (now.difference(session.lastRx) > Constants.wsHeartbeatTimeout) {
          session.ws?.close();
        }
      }
    }
  }

  void _closeSessionFingerprint(String fingerprint) {
    final session = _sessions.remove(fingerprint);
    if (session == null) return;
    _closeSession(session);
    _state.add(null);
  }

  void _closeSession(_PeerSession session) {
    session.closing = true;
    session.reconnectTimer?.cancel();
    session.ws?.close();
    session.ws = null;
  }

  void _onBackendChanged(ClipboardSnapshot snapshot) {
    if (!_enabled || snapshot.isEmpty) return;
    final hash = snapshot.contentHash;
    if (hash == null || hash == _lastSentHash || hash == _lastReceivedHash) {
      return;
    }
    _lastSentHash = hash;
    final message = ClipboardMessage(
      sourceFingerprint: _self.fingerprint,
      contentType: snapshot.text != null ? 'text' : 'image',
      content: snapshot.text ?? base64Encode(snapshot.imagePng!),
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    final payload = jsonEncode(message.toJson());
    for (final session in _sessions.values) {
      session.send(payload);
    }
  }

  void _onMessage(ClipboardMessage message) {
    if (message.sourceFingerprint == _self.fingerprint) return;
    final hash = message.contentHash;
    if (hash == _lastReceivedHash || hash == _lastSentHash) return;
    _lastReceivedHash = hash;
    if (message.contentType == 'text') {
      unawaited(_backend.write(ClipboardSnapshot(text: message.content)));
    } else {
      try {
        final bytes = base64Decode(message.content);
        unawaited(_backend.write(ClipboardSnapshot(imagePng: bytes)));
      } on Object {
        // 图片解码失败忽略
      }
    }
  }
}

const _headerFingerprint = 'X-SyncMate-Fingerprint';
