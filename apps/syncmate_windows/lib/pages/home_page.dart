import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:syncmate_core/syncmate_core.dart';

import '../platform/system_clipboard_backend.dart';
import 'devices_page.dart';

class _Selection {
  _Selection(this.fullPath, this.entry);

  final String fullPath;
  final FileEntry entry;
}

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

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  List<TrustedDevice> _trusted = [];
  final Set<String> _online = {};
  StreamSubscription<DiscoveryEvent>? _discoverySub;
  StreamSubscription<ConnectRequest>? _connectSub;
  StreamSubscription<TransferEvent>? _transferSub;
  TabController? _tabController;
  bool _requestDialogVisible = false;

  late final TransferService _transfers;
  late final SystemClipboardBackend _clipboardBackend;
  ClipboardService? _clipboardService;
  StreamSubscription<void>? _clipboardSub;
  bool _clipboardEnabled = false;
  String? _remotePanePath;
  String? _localPanePath;
  _Selection? _remoteSelected;
  _Selection? _localSelected;
  List<TransferTask> _transferTasks = [];

  @override
  void initState() {
    super.initState();
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
  }

  @override
  void dispose() {
    _discoverySub?.cancel();
    _connectSub?.cancel();
    _transferSub?.cancel();
    _clipboardSub?.cancel();
    unawaited(_clipboardService?.dispose());
    _tabController?.dispose();
    _transfers.dispose();
    super.dispose();
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
            Text('${request.remote.alias}（${request.remote.deviceType}）请求与您的设备建立信任连接。'),
            const SizedBox(height: 12),
            Text(
              '身份 ID：${request.remote.fingerprint}',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              '同意后对方可浏览、修改、删除本机全部文件，请确认设备身份。',
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

  void _onRemoteSelection(FileEntry? entry, String fullPath) {
    setState(() {
      if (entry == null) {
        _remoteSelected = null;
      } else {
        _remoteSelected = _Selection(fullPath, entry);
        _localSelected = null;
      }
    });
  }

  void _onLocalSelection(FileEntry? entry, String fullPath) {
    setState(() {
      if (entry == null) {
        _localSelected = null;
      } else {
        _localSelected = _Selection(fullPath, entry);
        _remoteSelected = null;
      }
    });
  }

  bool get _canCopy {
    if (_remoteSelected != null && _localPanePath != null) return true;
    if (_localSelected != null && _remotePanePath != null) return true;
    return false;
  }

  Future<void> _copySelection() async {
    final tabIndex = _tabController?.index ?? 0;
    if (_trusted.isEmpty || tabIndex >= _trusted.length) return;
    final device = _onlineDevice(_trusted[tabIndex].fingerprint);
    if (device == null) {
      _showMessage('对方设备离线');
      return;
    }
    final remoteContext = device.deviceType == 'windows' ? p.windows : p.posix;
    try {
      if (_remoteSelected != null) {
        final target = p.join(_localPanePath!, _remoteSelected!.entry.name);
        await _transfers.copy(
          device: device,
          remotePath: _remoteSelected!.fullPath,
          localPath: target,
          toRemote: false,
        );
      } else if (_localSelected != null) {
        final target = remoteContext.join(
          _remotePanePath!,
          _localSelected!.entry.name,
        );
        await _transfers.copy(
          device: device,
          remotePath: target,
          localPath: _localSelected!.fullPath,
          toRemote: true,
        );
      }
    } on Object catch (e) {
      _showMessage('复制失败：$e');
      return;
    }
    setState(() {
      _remoteSelected = null;
      _localSelected = null;
    });
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
            ),
            onPressed: _toggleClipboard,
          ),
          IconButton(
            tooltip: '设备管理',
            icon: const Icon(Icons.devices),
            onPressed: _openDevicesPage,
          ),
        ],
      ),
      body: _trusted.isEmpty ? _buildEmptyState(context) : _buildFileManager(context),
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
                  onSelectionChanged: _onRemoteSelection,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _LocalPane(
                  onPathChanged: _onLocalPathChanged,
                  onSelectionChanged: _onLocalSelection,
                ),
              ),
            ],
          ),
        ),
        _buildOperationBar(context),
        _buildTransferPanel(context),
      ],
    );
  }

  Widget _buildOperationBar(BuildContext context) {
    final _Selection? selection = _remoteSelected ?? _localSelected;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          if (selection != null)
            Expanded(
              child: Text(
                '已选：${selection.entry.name}',
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            const Expanded(child: Text('在任一栏选择文件后可复制到对侧')),
          FilledButton.icon(
            onPressed: _canCopy ? _copySelection : null,
            icon: const Icon(Icons.copy),
            label: const Text('复制到对面'),
          ),
        ],
      ),
    );
  }

  Widget _buildTransferPanel(BuildContext context) {
    if (_transferTasks.isEmpty) return const SizedBox.shrink();
    final visible = _transferTasks.length > 5
        ? _transferTasks.sublist(_transferTasks.length - 5)
        : _transferTasks;
    return Container(
      constraints: const BoxConstraints(maxHeight: 150),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
      leading: Icon(icon, color: color),
      title: Text(task.label, overflow: TextOverflow.ellipsis),
      subtitle: running
          ? LinearProgressIndicator(value: task.progress.clamp(0.0, 1.0).toDouble())
          : Text(
              task.status == TransferStatus.failed
                  ? '失败：${task.error}'
                  : task.status == TransferStatus.cancelled
                      ? '已取消'
                      : '完成${task.finalRemotePath != null ? '（${task.finalRemotePath}）' : ''}',
              overflow: TextOverflow.ellipsis,
            ),
      trailing: running
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${formatBytes(task.done)}/${formatBytes(task.total)}'
                  '${task.speed > 0 ? ' · ${formatBytes(task.speed.toInt())}/s' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                IconButton(
                  tooltip: '取消',
                  icon: const Icon(Icons.close),
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
    required this.onSelectionChanged,
  });

  final DeviceProfile self;
  final DiscoveredDevice? device;
  final ValueChanged<String?> onPathChanged;
  final void Function(FileEntry? entry, String fullPath) onSelectionChanged;

  @override
  State<_RemotePane> createState() => _RemotePaneState();
}

class _RemotePaneState extends State<_RemotePane> {
  String? _path;
  List<FileEntry> _entries = [];
  bool _loading = true;
  String? _error;
  FileEntry? _selection;
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
    setState(() {
      _selection = null;
      _path = _remotePath.join(_path ?? '', entry.name);
    });
    widget.onSelectionChanged(null, '');
    _load();
  }

  void _select(FileEntry entry) {
    if (entry.isDir) {
      _enter(entry);
      return;
    }
    setState(() => _selection = _selection == entry ? null : entry);
    if (_selection == entry) {
      widget.onSelectionChanged(
        entry,
        _remotePath.join(_path ?? '', entry.name),
      );
    } else {
      widget.onSelectionChanged(null, '');
    }
  }

  void _goUp() {
    if (_path == null) return;
    final parent = _remotePath.dirname(_path!);
    setState(() {
      _selection = null;
      _path = parent == _path ? null : parent;
    });
    widget.onSelectionChanged(null, '');
    _load();
  }

  void _goRoot() {
    setState(() {
      _selection = null;
      _path = null;
    });
    widget.onSelectionChanged(null, '');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('对方设备', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _buildToolbar(context),
            const SizedBox(height: 4),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: '返回上级',
          icon: const Icon(Icons.arrow_upward),
          onPressed: _path == null ? null : _goUp,
        ),
        IconButton(
          tooltip: '根目录',
          icon: const Icon(Icons.home),
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
          tooltip: '刷新',
          icon: const Icon(Icons.refresh),
          onPressed: _load,
        ),
        PopupMenuButton<String>(
          tooltip: '操作',
          onSelected: (action) => _handleAction(action),
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'mkdir', child: Text('新建文件夹')),
            if (_selection != null) ...[
              const PopupMenuItem(value: 'move', child: Text('重命名 / 移动')),
              const PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ],
        ),
      ],
    );
  }

  String get _basePath {
    if (_path != null) return _path!;
    return _entries.isEmpty ? '' : _entries.first.name;
  }

  String get _selectionPath =>
      _remotePath.join(_basePath, _selection!.name);

  Future<void> _handleAction(String action) async {
    final client = _client ??=
        (widget.device == null
            ? null
            : SyncMateClient(
                baseUrl: widget.device!.baseUrl,
                fingerprint: widget.self.fingerprint,
              ));
    if (client == null) {
      _showMessage('对方设备离线');
      return;
    }
    try {
      switch (action) {
        case 'mkdir':
          final name = await _promptText('新建文件夹', '文件夹名称', '新建文件夹');
          if (name == null || name.isEmpty) return;
          await client.mkdir(_remotePath.join(_basePath, name));
          _showMessage('已创建 $name');
        case 'move':
          final from = _selectionPath;
          final target = await _promptText(
            '重命名 / 移动',
            '目标完整路径',
            _remotePath.join(_remotePath.dirname(from), _selection!.name),
          );
          if (target == null || target.isEmpty) return;
          final actual = await client.move(from, target);
          _showMessage('已移动至 $actual');
        case 'delete':
          final name = _selection!.name;
          final confirmed = await _confirmDelete(name);
          if (!confirmed) return;
          await client.delete(_selectionPath, recursive: true);
          _showMessage('已删除 $name');
      }
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
    setState(() => _selection = null);
    widget.onSelectionChanged(null, '');
    _load();
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
            Text(_error!),
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
        return ListTile(
          dense: true,
          selected: _selection == entry,
          selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
          leading: Icon(_iconFor(entry)),
          title: Text(entry.name, overflow: TextOverflow.ellipsis),
          subtitle: entry.isDir
              ? null
              : Text(
                  '${formatBytes(entry.size)}  ·  ${_formatTime(entry.modified)}',
                ),
          onTap: () => _select(entry),
        );
      },
    );
  }
}

class _LocalPane extends StatefulWidget {
  const _LocalPane({
    required this.onPathChanged,
    required this.onSelectionChanged,
  });

  final ValueChanged<String?> onPathChanged;
  final void Function(FileEntry? entry, String fullPath) onSelectionChanged;

  @override
  State<_LocalPane> createState() => _LocalPaneState();
}

class _LocalPaneState extends State<_LocalPane> {
  final LocalFileSystemAdapter _fs = LocalFileSystemAdapter();
  String? _path;
  List<FileEntry> _entries = [];
  bool _loading = true;
  String? _error;
  FileEntry? _selection;

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
    setState(() {
      _selection = null;
      _path = p.join(_path ?? '', entry.name);
    });
    widget.onSelectionChanged(null, '');
    _load();
  }

  void _select(FileEntry entry) {
    if (entry.isDir) {
      _enter(entry);
      return;
    }
    setState(() => _selection = _selection == entry ? null : entry);
    if (_selection == entry) {
      widget.onSelectionChanged(entry, p.join(_path ?? '', entry.name));
    } else {
      widget.onSelectionChanged(null, '');
    }
  }

  void _goUp() {
    if (_path == null) return;
    final parent = p.dirname(_path!);
    setState(() {
      _selection = null;
      _path = parent == _path ? null : parent;
    });
    widget.onSelectionChanged(null, '');
    _load();
  }

  void _goRoot() {
    setState(() {
      _selection = null;
      _path = null;
    });
    widget.onSelectionChanged(null, '');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('本机', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  tooltip: '返回上级',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: _path == null ? null : _goUp,
                ),
                IconButton(
                  tooltip: '根目录',
                  icon: const Icon(Icons.home),
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
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh),
                  onPressed: _load,
                ),
                PopupMenuButton<String>(
                  tooltip: '操作',
                  onSelected: (action) => _handleAction(action),
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'mkdir', child: Text('新建文件夹')),
                    if (_selection != null) ...[
                      const PopupMenuItem(value: 'move', child: Text('重命名 / 移动')),
                      const PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  String get _basePath {
    if (_path != null) return _path!;
    return _entries.isEmpty ? '' : _entries.first.name;
  }

  String get _selectionPath => p.join(_basePath, _selection!.name);

  Future<void> _handleAction(String action) async {
    try {
      switch (action) {
        case 'mkdir':
          final name = await _promptText('新建文件夹', '文件夹名称', '新建文件夹');
          if (name == null || name.isEmpty) return;
          await _fs.mkdir(p.join(_basePath, name));
          _showMessage('已创建 $name');
        case 'move':
          final from = _selectionPath;
          final target = await _promptText(
            '重命名 / 移动',
            '目标完整路径',
            p.join(p.dirname(from), _selection!.name),
          );
          if (target == null || target.isEmpty) return;
          final actual = await _fs.move(from, target);
          _showMessage('已移动至 $actual');
        case 'delete':
          final name = _selection!.name;
          final confirmed = await _confirmDelete(name);
          if (!confirmed) return;
          await _fs.delete(_selectionPath, recursive: true);
          _showMessage('已删除 $name');
      }
    } on FsException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
    setState(() => _selection = null);
    widget.onSelectionChanged(null, '');
    _load();
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
            Text(_error!),
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
        return ListTile(
          dense: true,
          selected: _selection == entry,
          selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
          leading: Icon(_iconFor(entry)),
          title: Text(entry.name, overflow: TextOverflow.ellipsis),
          subtitle: entry.isDir
              ? null
              : Text(
                  '${formatBytes(entry.size)}  ·  ${_formatTime(entry.modified)}',
                ),
          onTap: () => _select(entry),
        );
      },
    );
  }
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
