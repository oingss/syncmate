import 'dart:async';

import 'package:flutter/material.dart';
import 'package:syncmate_core/syncmate_core.dart';

import 'audit_log_page.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({
    super.key,
    required this.discovery,
    required this.trustStore,
    required this.self,
    this.auditLogPath,
  });

  final DiscoveryService discovery;
  final TrustStore trustStore;
  final DeviceProfile self;
  final String? auditLogPath;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<DiscoveredDevice> _nearby = [];
  List<TrustedDevice> _trusted = [];
  final Set<String> _online = {};
  StreamSubscription<DiscoveryEvent>? _discoverySub;

  @override
  void initState() {
    super.initState();
    _discoverySub = widget.discovery.events.listen(_onDiscoveryEvent);
    _refreshTrusted();
  }

  @override
  void dispose() {
    _discoverySub?.cancel();
    super.dispose();
  }

  void _onDiscoveryEvent(DiscoveryEvent event) {
    if (!mounted) return;
    setState(() {
      _nearby = widget.discovery.devices;
      if (event is DeviceDiscovered || event is DeviceUpdated) {
        _online.add(event.device.fingerprint);
      } else if (event is DeviceExpired) {
        _online.remove(event.device.fingerprint);
      }
    });
  }

  Future<void> _refreshTrusted() async {
    final list = await widget.trustStore.load();
    if (!mounted) return;
    setState(() => _trusted = list);
  }

  Future<void> _requestConnect(DiscoveredDevice device) async {
    final client =
        SyncMateClient(baseUrl: device.baseUrl, fingerprint: widget.self.fingerprint);
    try {
      final info = await client.connect(widget.self);
      if (info.fingerprint != device.fingerprint) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('连接失败：对方身份与发现报文不符')),
        );
        return;
      }
      await widget.trustStore.addOrUpdate(TrustedDevice(
        fingerprint: info.fingerprint,
        alias: info.alias,
        deviceType: info.deviceType,
        port: info.port,
        lastConnected: DateTime.now(),
      ));
      _refreshTrusted();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已与「${info.alias}」建立信任')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      final message = e.code == ApiErrorCode.rejected
          ? '对方拒绝了连接请求'
          : e.code == ApiErrorCode.timeout
              ? '连接请求超时'
              : '连接失败：${e.message}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('连接失败：无法访问对方设备')),
      );
    } finally {
      client.close();
    }
  }

  Future<void> _revokeTrust(TrustedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('撤销信任'),
        content: Text('确定撤销对「${device.alias}」的信任吗？撤销后对方需重新发起连接申请。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.trustStore.remove(device.fingerprint);
    _refreshTrusted();
  }

  Future<void> _renameTrust(TrustedDevice device) async {
    final controller = TextEditingController(text: device.alias);
    final newAlias = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名设备'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '别名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    final trimmed = newAlias?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == device.alias) return;
    await widget.trustStore.addOrUpdate(device.copyWith(alias: trimmed));
    _refreshTrusted();
  }

  void _openAuditLog() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AuditLogPage(logPath: widget.auditLogPath),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备管理'),
        actions: [
          IconButton(
            tooltip: '操作日志',
            icon: const Icon(Icons.receipt_long),
            onPressed: _openAuditLog,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshTrusted,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('已信任设备（${_trusted.length}）', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (_trusted.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('尚无信任设备，在下方列表发起连接'),
              )
            else
              ..._trusted.map((device) {
                final online = _online.contains(device.fingerprint);
                return Card(
                  child: ListTile(
                    leading: Icon(
                      device.deviceType == 'android'
                          ? Icons.phone_android
                          : Icons.desktop_windows,
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            device.alias,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _StatusDot(online: online),
                      ],
                    ),
                    subtitle: Text(
                      '${device.fingerprint.substring(0, 12)}…  ·  '
                      '最近连接：${_formatTime(device.lastConnected)}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '重命名',
                          icon: const Icon(Icons.edit),
                          onPressed: () => _renameTrust(device),
                        ),
                        IconButton(
                          tooltip: '撤销信任',
                          icon: const Icon(Icons.link_off),
                          onPressed: () => _revokeTrust(device),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            const SizedBox(height: 16),
            Text('附近设备（${_nearby.length}）', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            if (_nearby.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('正在搜索同一局域网内的设备…')),
              )
            else
              ..._nearby.map((device) {
                final trusted = _trusted.any(
                  (d) => d.fingerprint == device.fingerprint,
                );
                return Card(
                  child: ListTile(
                    leading: Icon(
                      device.deviceType == 'android'
                          ? Icons.phone_android
                          : Icons.desktop_windows,
                    ),
                    title: Text(device.alias),
                    subtitle: Text('${device.baseUrl}  ·  ${device.appVersion ?? ''}'),
                    trailing: trusted
                        ? const Text('已信任', style: TextStyle(color: Colors.green))
                        : FilledButton(
                            onPressed: () => _requestConnect(device),
                            child: const Text('请求连接'),
                          ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '从未';
    final local = time.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: online ? Colors.green : Colors.grey,
      ),
    );
  }
}
