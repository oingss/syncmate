import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:syncmate_core/syncmate_core.dart';

import '../platform/storage_permission.dart';
import '../platform/system_clipboard_backend.dart';
import 'devices_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
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
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  List<TrustedDevice> _trusted = [];
  final Set<String> _online = {};
  StreamSubscription<DiscoveryEvent>? _discoverySub;
  StreamSubscription<ConnectRequest>? _connectSub;
  StreamSubscription<TransferEvent>? _transferSub;
  TabController? _tabController;
  bool _requestDialogVisible = false;
  bool? _storageGranted;

  late final TransferService _transfers;
  late final SystemClipboardBackend _clipboardBackend;
  ClipboardService? _clipboardService;
  StreamSubscription<void>? _clipboardSub;
  bool _clipboardEnabled = false;
  String? _remotePanePath;
  String? _localPanePath;
  List<TransferTask> _transferTasks = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _transfers = TransferService(self: widget.self);
    _clipboardBackend = SystemClipboardBackend();
    _clipboardService = ClipboardService(
      self: widget.self,
      trustStore: widget.trustStore,
      discovery: widget.discovery,
      backend: _clipboardBackend,
      serverEvents: widget.server.clipboardEvents,
    );
    _clipboardSub = _clipboardService!.state.listen((_) {
      if (mounted) setState(() {});
    });
    _discoverySub = widget.discovery.events.listen(_onDiscoveryEvent);
    _connectSub = widget.server.connectRequests.listen(_onConnectRequest);
    _transferSub = _transfers.events.listen((_) {
      if (!mounted) return;
      setState(() => _transferTasks = _transfers.tasks);
    });
    _refreshTrusted();
    _checkStoragePermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _discoverySub?.cancel();
    _connectSub?.cancel();
    _transferSub?.cancel();
    _clipboardSub?.cancel();
    unawaited(_clipboardService?.dispose());
    _tabController?.dispose();
    _transfers.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkStoragePermission();
    }
  }

  Future<void> _checkStoragePermission() async {
    final granted = await StoragePermission.isGranted();
    if (!mounted || granted == _storageGranted) return;
    setState(() => _storageGranted = granted);
  }

  Future<void> _grantStoragePermission() async {
    final granted = await StoragePermission.request();
    if (!mounted) return;
    setState(() => _storageGranted = granted);
    _showMessage(
      granted ? '文件访问权限已授予' : '请在系统设置中开启「允许访问所有文件」',
    );
  }

  void _toggleClipboard() {
    _clipboardEnabled = !_clipboardEnabled;
    _clipboardService!.setEnabled(_clipboardEnabled);
    _showMessage(_clipboardEnabled ? '剪切板同步已开启' : '剪切板同步已关闭');
  }

  void _onDiscoveryEvent(DiscoveryEvent event) {
    if (!mounted) return;
    setState(() {
      if (event is DeviceDiscovered) {
        _online.add(event.device.fingerprint);
      } else if (event is DeviceUpdated) {
        _online.add(event.device.fingerprint);
      } else if (event is DeviceExpired) {
        _online.remove(event.device.fingerprint);
      }
    });
  }

  Future<void> _refreshTrusted() async {
    final list = await widget.trustStore.load();
    if (!mounted) return;
    setState(() {
      _trusted = list;
      if (_tabController == null ||
          _tabController!.length != list.length ||
          list.isEmpty) {
        _tabController?.dispose();
        _tabController = list.isEmpty
            ? null
            : TabController(length: list.length, vsync: this);
      } else if (_tabController!.index >= list.length) {
        _tabController!.index = list.length - 1;
      }
    });
  }

  Future<void> _onConnectRequest(ConnectRequest request) async {
    if (_requestDialogVisible) return;
    _requestDialogVisible = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('连接请求'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('「${request.remote.alias}」请求与您的设备建立信任连接'),
            const SizedBox(height: 8),
            Text(
              '同意后对方可浏览、修改、删除本机全部文件',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              '身份 ID：${request.remote.fingerprint}',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              request.reject();
            },
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              request.accept();
              _refreshTrusted();
            },
            child: const Text('允许'),
          ),
        ],
      ),
    );
    _requestDialogVisible = false;
  }

  Future<void> _openDevicesPage() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DevicesPage(
        discovery: widget.discovery,
        trustStore: widget.trustStore,
        self: widget.self,
        auditLogPath: widget.auditLogPath,
      ),
    ));
    _refreshTrusted();
  }

  DiscoveredDevice? _onlineDevice(String fingerprint) {
    for (final device in widget.discovery.devices) {
      if (device.fingerprint == fingerprint) return device;
    }
    return null;
  }

  void _onRemotePathChanged(String? path) {
    if (_remotePanePath == path) return;
    setState(() => _remotePanePath = path);
  }

  void _onLocalPathChanged(String? path) {
    if (_localPanePath == path) return;
    setState(() => _localPanePath = path);
  }

  DiscoveredDevice? _currentDevice() {
    final tabIndex = _tabController?.index ?? 0;
    if (_trusted.isEmpty || tabIndex >= _trusted.length) return null;
    return _onlineDevice(_trusted[tabIndex].fingerprint);
  }

  /// 对方设备 → 本机（复制对方文件/文件夹到本机当前目录）。
  Future<void> _copyFromRemote(FileEntry entry, String fullPath) async {
    final device = _currentDevice();
    if (device == null) {
      _showMessage('对方设备离线');
      return;
    }
    final target = _localPanePath;
    if (target == null) {
      _showMessage('请先在本机侧进入目标文件夹');
      return;
    }
    try {
      if (entry.isDir) {
        await _transfers.copyDirectory(
          device: device,
          remotePath: fullPath,
          localPath: p.join(target, entry.name),
          toRemote: false,
        );
      } else {
        await _transfers.copy(
          device: device,
          remotePath: fullPath,
          localPath: p.join(target, entry.name),
          toRemote: false,
        );
      }
      _showMessage('已开始从对方设备复制到本机');
    } on Object catch (e) {
      _showMessage('复制失败：$e');
    }
  }

  /// 本机 → 对方设备（复制本机文件/文件夹到对方当前目录）。
  Future<void> _copyFromLocal(FileEntry entry, String fullPath) async {
    final device = _currentDevice();
    if (device == null) {
      _showMessage('对方设备离线');
      return;
    }
    final target = _remotePanePath;
    if (target == null) {
      _showMessage('请先进入对方设备的目标文件夹');
      return;
    }
    try {
      final remoteContext = device.deviceType == 'windows' ? p.windows : p.posix;
      final remoteTarget = remoteContext.join(target, entry.name);
      if (entry.isDir) {
        await _transfers.copyDirectory(
          device: device,
          remotePath: remoteTarget,
          localPath: fullPath,
          toRemote: true,
        );
      } else {
        await _transfers.copy(
          device: device,
          remotePath: remoteTarget,
          localPath: fullPath,
          toRemote: true,
        );
      }
      _showMessage('已开始复制到对方设备');
    } on Object catch (e) {
      _showMessage('复制失败：$e');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SyncMate'),
        actions: [
          IconButton(
            tooltip: _clipboardEnabled
                ? '剪切板同步已开启（已连接 ${_clipboardService?.connectedFingerprints.length ?? 0} 台）'
                : '开启剪切板同步',
            icon: Icon(
              _clipboardEnabled ? Icons.content_paste : Icons.content_paste_off,
              size: 20,
            ),
            onPressed: _toggleClipboard,
          ),
          IconButton(
            tooltip: '设备管理',
            icon: const Icon(Icons.devices, size: 20),
            onPressed: _openDevicesPage,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStorageBanner(context),
          Expanded(
            child: _trusted.isEmpty
                ? _buildEmptyState(context)
                : _buildFileManager(context),
          ),
        ],
      ),
    );
  }

  Widget _buildStorageBanner(BuildContext context) {
    if (_storageGranted == null || _storageGranted!) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            Icon(Icons.folder_off, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '未授予文件访问权限，本机及对方设备均无法访问本机文件',
                style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: _grantStoragePermission,
              child: const Text('去授权'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.link_off, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text('尚未与任何设备建立信任连接'),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _openDevicesPage,
            child: const Text('去设备管理页连接'),
          ),
        ],
      ),
    );
  }

  Widget _buildFileManager(BuildContext context) {
    final controller = _tabController!;
    final current = _trusted[controller.index];
    final remoteDevice = _onlineDevice(current.fingerprint);
    return Column(
      children: [
        TabBar(
          controller: controller,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            for (final device in _trusted)
              Tab(
                text: _online.contains(device.fingerprint)
                    ? '● ${device.alias}'
                    : '○ ${device.alias}',
              ),
          ],
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: _RemotePane(
                  key: ValueKey(current.fingerprint),
                  self: widget.self,
                  device: remoteDevice,
                  onPathChanged: _onRemotePathChanged,
                  onCopyRequested: _copyFromRemote,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _LocalPane(
                  onPathChanged: _onLocalPathChanged,
                  onCopyRequested: _copyFromLocal,
                ),
              ),
            ],
          ),
        ),
        _buildTransferPanel(context),
      ],
    );
  }

  Widget _buildTransferPanel(BuildContext context) {
    if (_transferTasks.isEmpty) return const SizedBox.shrink();
    final visible = _transferTasks.length > 3
        ? _transferTasks.sublist(_transferTasks.length - 3)
        : _transferTasks;
    return Container(
      constraints: const BoxConstraints(maxHeight: 120),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('传输任务', style: Theme.of(context).textTheme.titleSmall),
          Expanded(
            child: ListView.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final task = visible[index];
                return _buildTaskTile(context, task);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskTile(BuildContext context, TransferTask task) {
    final running = task.status == TransferStatus.running;
    final icon = switch (task.status) {
      TransferStatus.running => Icons.sync,
      TransferStatus.done => Icons.check_circle,
      TransferStatus.failed => Icons.error,
      TransferStatus.cancelled => Icons.cancel,
    };
    final color = switch (task.status) {
      TransferStatus.running => null,
      TransferStatus.done => Colors.green,
      TransferStatus.failed => Colors.red,
      TransferStatus.cancelled => Colors.grey,
    };
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 20, color: color),
      title: Text(task.label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
      subtitle: running
          ? LinearProgressIndicator(value: task.progress.clamp(0.0, 1.0).toDouble())
          : Text(
              task.status == TransferStatus.failed
                  ? '失败：${task.error}'
                  : task.status == TransferStatus.cancelled
                      ? '已取消'
                      : '完成${task.finalRemotePath != null ? '（${task.finalRemotePath}）' : ''}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
      trailing: running
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${formatBytes(task.done)}/${formatBytes(task.total)}'
                  '${task.speed > 0 ? ' · ${formatBytes(task.speed.toInt())}/s' : ''}',
                  style: const TextStyle(fontSize: 10),
                ),
                IconButton(
                  tooltip: '取消',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => task.cancelToken.cancel(),
                ),
              ],
            )
          : null,
    );
  }
}

class _RemotePane extends StatefulWidget {
  const _RemotePane({
    super.key,
    required this.self,
    required this.device,
    required this.onPathChanged,
    required this.onCopyRequested,
  });

  final DeviceProfile self;
  final DiscoveredDevice? device;
  final ValueChanged<String?> onPathChanged;
  final void Function(FileEntry entry, String fullPath) onCopyRequested;

  @override
  State<_RemotePane> createState() => _RemotePaneState();
}

class _RemotePaneState extends State<_RemotePane> {
  String? _path;
  List<FileEntry> _entries = [];
  bool _loading = true;
  String? _error;
  SyncMateClient? _client;
  late final p.Context _remotePath;

  @override
  void initState() {
    super.initState();
    _remotePath = widget.device?.deviceType == 'windows' ? p.windows : p.posix;
    _load();
  }

  Future<void> _load() async {
    final device = widget.device;
    if (device == null) {
      setState(() {
        _loading = false;
        _error = '设备离线';
        _entries = [];
      });
      widget.onPathChanged(null);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final client = _client ??= SyncMateClient(
      baseUrl: device.baseUrl,
      fingerprint: widget.self.fingerprint,
    );
    try {
      final list = _path == null
          ? await client.listRoots()
          : await client.listFiles(_path!);
      if (!mounted) return;
      setState(() {
        _entries = list.entries;
        _loading = false;
      });
      // 根目录时报告第一个存储根作为复制目标，保证双向复制在根目录也可用
      widget.onPathChanged(
        _path ?? (_entries.isEmpty ? null : _entries.first.name),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _error = '无法访问对方设备';
        _loading = false;
      });
    }
  }

  void _enter(FileEntry entry) {
    setState(() => _path = _remotePath.join(_path ?? '', entry.name));
    _load();
  }

  void _select(FileEntry entry) {
    if (entry.isDir) {
      _enter(entry);
      return;
    }
    _showEntryActions(entry);
  }

  Future<void> _showEntryActions(FileEntry entry) async {
    final action = await _showActionDialog(
      context,
      entry,
      copyLabel: '复制到本机',
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _EntryAction.copy:
        widget.onCopyRequested(
          entry,
          _remotePath.join(_path ?? '', entry.name),
        );
      case _EntryAction.rename:
        await _renameEntry(entry);
      case _EntryAction.move:
        await _moveEntry(entry);
      case _EntryAction.delete:
        await _deleteEntry(entry);
    }
  }

  void _goUp() {
    if (_path == null) return;
    final parent = _remotePath.dirname(_path!);
    setState(() => _path = parent == _path ? null : parent);
    _load();
  }

  void _goRoot() {
    setState(() => _path = null);
    _load();
  }

  String get _basePath {
    if (_path != null) return _path!;
    return _entries.isEmpty ? '' : _entries.first.name;
  }

  SyncMateClient? _clientFor() {
    return _client ??=
        (widget.device == null
            ? null
            : SyncMateClient(
                baseUrl: widget.device!.baseUrl,
                fingerprint: widget.self.fingerprint,
              ));
  }

  Future<void> _handleMkdir() async {
    final client = _clientFor();
    if (client == null) {
      _showMessage('对方设备离线');
      return;
    }
    try {
      final name = await _promptText('新建文件夹', '文件夹名称', '新建文件夹');
      if (name == null || name.isEmpty) return;
      await client.mkdir(_remotePath.join(_basePath, name));
      _showMessage('已创建 $name');
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  Future<void> _renameEntry(FileEntry entry) async {
    final client = _clientFor();
    if (client == null) {
      _showMessage('对方设备离线');
      return;
    }
    final from = _remotePath.join(_path ?? '', entry.name);
    try {
      final name = await _promptText('重命名', '新名称', entry.name);
      if (name == null || name.isEmpty) return;
      await client.move(
        from,
        _remotePath.join(_remotePath.dirname(from), name),
      );
      _showMessage('已重命名');
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  Future<void> _moveEntry(FileEntry entry) async {
    final client = _clientFor();
    if (client == null) {
      _showMessage('对方设备离线');
      return;
    }
    final from = _remotePath.join(_path ?? '', entry.name);
    try {
      final target = await _promptText(
        '移动',
        '目标完整路径',
        _remotePath.join(_remotePath.dirname(from), entry.name),
      );
      if (target == null || target.isEmpty) return;
      final actual = await client.move(from, target);
      _showMessage('已移动至 $actual');
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  Future<void> _deleteEntry(FileEntry entry) async {
    final client = _clientFor();
    if (client == null) {
      _showMessage('对方设备离线');
      return;
    }
    final from = _remotePath.join(_path ?? '', entry.name);
    final confirmed = await _confirmDelete(entry.name);
    if (!confirmed) return;
    try {
      await client.delete(from, recursive: true);
      _showMessage('已删除 ${entry.name}');
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return _buildPane(
      context,
      title: '对方设备',
      toolbar: _buildToolbar(context),
      body: _buildBody(context),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_upward, size: 18),
          onPressed: _path == null ? null : _goUp,
        ),
        IconButton(
          icon: const Icon(Icons.home, size: 18),
          onPressed: _path == null ? null : _goRoot,
        ),
        Expanded(
          child: Text(
            _path ?? '(根目录)',
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.refresh, size: 18),
          onPressed: _load,
        ),
        PopupMenuButton<String>(
          tooltip: '操作',
          icon: const Icon(Icons.more_vert, size: 18),
          onSelected: (action) => _handleAction(action),
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'mkdir', child: Text('新建文件夹')),
          ],
        ),
      ],
    );
  }

  Future<void> _handleAction(String action) async {
    switch (action) {
      case 'mkdir':
        await _handleMkdir();
    }
  }

  Future<String?> _promptText(String title, String label, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
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
  }

  Future<bool> _confirmDelete(String name) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除确认'),
        content: Text('确定要永久删除「$name」吗？该操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(child: Text('空目录'));
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return _buildTile(context, entry);
      },
    );
  }

  Widget _buildTile(BuildContext context, FileEntry entry) {
    return GestureDetector(
      onLongPress: () => _showEntryActions(entry),
      onSecondaryTap: () => _showEntryActions(entry),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: Icon(_iconFor(entry), size: 20),
        title: Text(
          entry.name,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13),
        ),
        subtitle: entry.isDir
            ? null
            : Text(
                '${formatBytes(entry.size)}  ·  ${_formatTime(entry.modified)}',
                style: const TextStyle(fontSize: 11),
              ),
        onTap: () => _select(entry),
      ),
    );
  }
}

class _LocalPane extends StatefulWidget {
  const _LocalPane({
    required this.onPathChanged,
    required this.onCopyRequested,
  });

  final ValueChanged<String?> onPathChanged;
  final void Function(FileEntry entry, String fullPath) onCopyRequested;

  @override
  State<_LocalPane> createState() => _LocalPaneState();
}

class _LocalPaneState extends State<_LocalPane> {
  final LocalFileSystemAdapter _fs = LocalFileSystemAdapter();
  String? _path;
  List<FileEntry> _entries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = _path == null ? await _fs.roots() : await _fs.list(_path!);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
      // 根目录时报告第一个存储根作为复制目标
      widget.onPathChanged(
        _path ?? (_entries.isEmpty ? null : _entries.first.name),
      );
    } on FsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _error = '无法读取本机目录';
        _loading = false;
      });
    }
  }

  void _enter(FileEntry entry) {
    setState(() => _path = p.join(_path ?? '', entry.name));
    _load();
  }

  void _select(FileEntry entry) {
    if (entry.isDir) {
      _enter(entry);
      return;
    }
    _showEntryActions(entry);
  }

  Future<void> _showEntryActions(FileEntry entry) async {
    final action = await _showActionDialog(
      context,
      entry,
      copyLabel: '复制到对方设备',
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _EntryAction.copy:
        widget.onCopyRequested(entry, p.join(_path ?? '', entry.name));
      case _EntryAction.rename:
        await _renameEntry(entry);
      case _EntryAction.move:
        await _moveEntry(entry);
      case _EntryAction.delete:
        await _deleteEntry(entry);
    }
  }

  void _goUp() {
    if (_path == null) return;
    final parent = p.dirname(_path!);
    setState(() => _path = parent == _path ? null : parent);
    _load();
  }

  void _goRoot() {
    setState(() => _path = null);
    _load();
  }

  String get _basePath {
    if (_path != null) return _path!;
    return _entries.isEmpty ? '' : _entries.first.name;
  }

  Future<void> _handleMkdir() async {
    try {
      final name = await _promptText('新建文件夹', '文件夹名称', '新建文件夹');
      if (name == null || name.isEmpty) return;
      await _fs.mkdir(p.join(_basePath, name));
      _showMessage('已创建 $name');
    } on FsException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  Future<void> _renameEntry(FileEntry entry) async {
    final from = p.join(_path ?? '', entry.name);
    try {
      final name = await _promptText('重命名', '新名称', entry.name);
      if (name == null || name.isEmpty) return;
      await _fs.move(from, p.join(p.dirname(from), name));
      _showMessage('已重命名');
    } on FsException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  Future<void> _moveEntry(FileEntry entry) async {
    final from = p.join(_path ?? '', entry.name);
    try {
      final target = await _promptText(
        '移动',
        '目标完整路径',
        p.join(p.dirname(from), entry.name),
      );
      if (target == null || target.isEmpty) return;
      final actual = await _fs.move(from, target);
      _showMessage('已移动至 $actual');
    } on FsException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  Future<void> _deleteEntry(FileEntry entry) async {
    final from = p.join(_path ?? '', entry.name);
    final confirmed = await _confirmDelete(entry.name);
    if (!confirmed) return;
    try {
      await _fs.delete(from, recursive: true);
      _showMessage('已删除 ${entry.name}');
    } on FsException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return _buildPane(
      context,
      title: '本机',
      toolbar: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 18),
            onPressed: _path == null ? null : _goUp,
          ),
          IconButton(
            icon: const Icon(Icons.home, size: 18),
            onPressed: _path == null ? null : _goRoot,
          ),
          Expanded(
            child: Text(
              _path ?? '(根目录)',
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: _load,
          ),
          PopupMenuButton<String>(
            tooltip: '操作',
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (action) => _handleAction(action),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'mkdir', child: Text('新建文件夹')),
            ],
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Future<void> _handleAction(String action) async {
    switch (action) {
      case 'mkdir':
        await _handleMkdir();
    }
  }

  Future<String?> _promptText(String title, String label, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
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
  }

  Future<bool> _confirmDelete(String name) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除确认'),
        content: Text('确定要永久删除「$name」吗？该操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(child: Text('空目录'));
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return GestureDetector(
          onLongPress: () => _showEntryActions(entry),
          onSecondaryTap: () => _showEntryActions(entry),
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: Icon(_iconFor(entry), size: 20),
            title: Text(
              entry.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: entry.isDir
                ? null
                : Text(
                    '${formatBytes(entry.size)}  ·  ${_formatTime(entry.modified)}',
                    style: const TextStyle(fontSize: 11),
                  ),
            onTap: () => _select(entry),
          ),
        );
      },
    );
  }
}

enum _EntryAction { copy, rename, move, delete }

Future<_EntryAction?> _showActionDialog(
  BuildContext context,
  FileEntry entry, {
  required String copyLabel,
}) {
  final name = entry.name;
  final isDir = entry.isDir;
  return showDialog<_EntryAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(name, overflow: TextOverflow.ellipsis),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.copy),
            title: Text(copyLabel),
            onTap: () => Navigator.of(dialogContext).pop(_EntryAction.copy),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('重命名'),
            onTap: () => Navigator.of(dialogContext).pop(_EntryAction.rename),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.drive_file_move_outline),
            title: const Text('移动'),
            onTap: () => Navigator.of(dialogContext).pop(_EntryAction.move),
          ),
          ListTile(
            dense: true,
            leading: Icon(Icons.delete_outline, color: Colors.red),
            title: Text(
              '删除',
              style: TextStyle(color: isDir ? Colors.red : null),
            ),
            onTap: () => Navigator.of(dialogContext).pop(_EntryAction.delete),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

Widget _buildPane(
  BuildContext context, {
  required String title,
  required Widget toolbar,
  required Widget body,
}) {
  return Card(
    margin: const EdgeInsets.symmetric(vertical: 4),
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          toolbar,
          Expanded(child: body),
        ],
      ),
    ),
  );
}

IconData _iconFor(FileEntry entry) {
  if (entry.isDir) return Icons.folder;
  final lower = entry.name.toLowerCase();
  if (lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.bmp')) {
    return Icons.image;
  }
  if (lower.endsWith('.mp4') ||
      lower.endsWith('.mkv') ||
      lower.endsWith('.avi') ||
      lower.endsWith('.mov') ||
      lower.endsWith('.webm')) {
    return Icons.movie;
  }
  if (lower.endsWith('.mp3') ||
      lower.endsWith('.wav') ||
      lower.endsWith('.flac') ||
      lower.endsWith('.aac') ||
      lower.endsWith('.ogg')) {
    return Icons.music_note;
  }
  if (lower.endsWith('.zip') ||
      lower.endsWith('.rar') ||
      lower.endsWith('.7z') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.gz')) {
    return Icons.folder_zip;
  }
  return Icons.insert_drive_file;
}

String _formatTime(int milliseconds) {
  final local = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}
