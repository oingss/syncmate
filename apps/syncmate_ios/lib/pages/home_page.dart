import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:syncmate_core/syncmate_core.dart';

import '../platform/storage_permission.dart';
import '../platform/system_clipboard_backend.dart';
import 'devices_page.dart';

/// 单个视图的槽位：source 为 null 表示本机，否则为设备指纹。
class _PaneSlot {
  String? source;
  String? path;
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

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  List<TrustedDevice> _trusted = [];
  final Set<String> _online = {};
  StreamSubscription<DiscoveryEvent>? _discoverySub;
  StreamSubscription<ConnectRequest>? _connectSub;
  StreamSubscription<TransferEvent>? _transferSub;
  bool _requestDialogVisible = false;
  bool? _storageGranted;

  late final TransferService _transfers;
  late final SystemClipboardBackend _clipboardBackend;
  ClipboardService? _clipboardService;
  StreamSubscription<void>? _clipboardSub;
  bool _clipboardEnabled = false;

  final LocalFileSystemAdapter _fs = LocalFileSystemAdapter();
  final _PaneSlot _paneA = _PaneSlot();
  final _PaneSlot _paneB = _PaneSlot();
  final GlobalKey<_FilePaneState> _paneAKey = GlobalKey<_FilePaneState>();
  final GlobalKey<_FilePaneState> _paneBKey = GlobalKey<_FilePaneState>();
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
    setState(() => _trusted = list);
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

  /// 视图来源下拉项：本机 + 全部已信任设备（在线/离线标记）。
  List<({String? fingerprint, String alias})> _paneSources() {
    final list = <({String? fingerprint, String alias})>[
      (fingerprint: null, alias: '本机'),
    ];
    for (final trusted in _trusted) {
      final device = _onlineDevice(trusted.fingerprint);
      final alias = device?.alias ?? trusted.alias;
      final marker = _online.contains(trusted.fingerprint) ? '●' : '○';
      list.add((fingerprint: trusted.fingerprint, alias: '$marker $alias'));
    }
    return list;
  }

  void _reloadPanes() {
    _paneAKey.currentState?.reload();
    _paneBKey.currentState?.reload();
  }

  String _remoteJoin(DiscoveredDevice device, String dir, String name) {
    final context_ = device.deviceType == 'windows' ? p.windows : p.posix;
    return context_.join(dir, name);
  }

  Future<bool> _awaitTask(TransferTask task) async {
    while (task.status == TransferStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return task.status == TransferStatus.done;
  }

  /// 复制/移动到另一视图的当前目录。
  Future<void> _transferFrom({
    required _PaneSlot from,
    required _PaneSlot to,
    required FileEntry entry,
    required String fullPath,
    required bool move,
  }) async {
    final target = to.path;
    if (target == null) {
      _showMessage('请先在目标视图进入目标文件夹');
      return;
    }
    final fromRemote = from.source != null;
    final toRemote = to.source != null;
    try {
      if (!fromRemote && !toRemote) {
        // 本机 → 本机
        final dst = p.join(target, entry.name);
        if (move) {
          await _fs.move(fullPath, dst);
          _showMessage('已移动');
        } else {
          final actual = await _fs.copy(fullPath, dst);
          _showMessage('已复制到 $actual');
        }
        _reloadPanes();
        return;
      }
      if (fromRemote && toRemote) {
        if (from.source == to.source) {
          // 同一设备：服务端复制/移动
          final device = _onlineDevice(from.source!);
          if (device == null) {
            _showMessage('对方设备离线');
            return;
          }
          final client = SyncMateClient(
            baseUrl: device.baseUrl,
            fingerprint: widget.self.fingerprint,
          );
          final dst = _remoteJoin(device, target, entry.name);
          if (move) {
            final actual = await client.move(fullPath, dst);
            _showMessage('已移动至 $actual');
          } else {
            final actual = await client.copy(fullPath, dst);
            _showMessage('已复制到 $actual');
          }
          _reloadPanes();
          return;
        }
        // 不同设备：本机中转
        final fromDev = _onlineDevice(from.source!);
        final toDev = _onlineDevice(to.source!);
        if (fromDev == null || toDev == null) {
          _showMessage('对方设备离线');
          return;
        }
        await _transfers.copyBetweenDevices(
          from: fromDev,
          fromPath: fullPath,
          to: toDev,
          toPath: _remoteJoin(toDev, target, entry.name),
          move: move,
        );
        _showMessage(move ? '已开始移动' : '已开始复制');
        return;
      }
      // 本机 ↔ 设备
      final device = toRemote ? _onlineDevice(to.source!) : _onlineDevice(from.source!);
      if (device == null) {
        _showMessage('对方设备离线');
        return;
      }
      final remotePath =
          toRemote ? _remoteJoin(device, target, entry.name) : fullPath;
      final localPath =
          toRemote ? fullPath : p.join(target, entry.name);
      final task = entry.isDir
          ? await _transfers.copyDirectory(
              device: device,
              remotePath: remotePath,
              localPath: localPath,
              toRemote: toRemote,
            )
          : await _transfers.copy(
              device: device,
              remotePath: remotePath,
              localPath: localPath,
              toRemote: toRemote,
            );
      if (!move) {
        _showMessage('已开始复制');
        return;
      }
      final done = await _awaitTask(task);
      if (!done) {
        _showMessage('移动失败，源文件未删除');
        return;
      }
      if (fromRemote) {
        final fromClient = SyncMateClient(
          baseUrl: device.baseUrl,
          fingerprint: widget.self.fingerprint,
        );
        await fromClient.delete(fullPath, recursive: true);
      } else {
        await _fs.delete(fullPath, recursive: true);
      }
      _showMessage('已移动');
      _reloadPanes();
    } on FsException catch (e) {
      _showMessage('操作失败：${e.message}');
    } on ApiException catch (e) {
      _showMessage('操作失败：${e.message}');
    } on Object catch (e) {
      _showMessage('操作失败：$e');
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
          Expanded(child: _buildFileManager(context)),
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

  Widget _buildFileManager(BuildContext context) {
    final sources = _paneSources();
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _FilePane(
                  key: _paneAKey,
                  self: widget.self,
                  source: _paneA.source,
                  device: _onlineDevice(_paneA.source ?? ''),
                  sources: sources,
                  onSourceChanged: (fp) => setState(() {
                    _paneA.source = fp;
                    _paneA.path = null;
                  }),
                  onPathChanged: (path) => _paneA.path = path,
                  onTransferRequested: (entry, fullPath, move) =>
                      _transferFrom(
                          from: _paneA, to: _paneB, entry: entry, fullPath: fullPath, move: move),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _FilePane(
                  key: _paneBKey,
                  self: widget.self,
                  source: _paneB.source,
                  device: _onlineDevice(_paneB.source ?? ''),
                  sources: sources,
                  onSourceChanged: (fp) => setState(() {
                    _paneB.source = fp;
                    _paneB.path = null;
                  }),
                  onPathChanged: (path) => _paneB.path = path,
                  onTransferRequested: (entry, fullPath, move) =>
                      _transferFrom(
                          from: _paneB, to: _paneA, entry: entry, fullPath: fullPath, move: move),
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

/// 文件浏览视图：来源可切换（本机 / 任意在线信任设备）。
class _FilePane extends StatefulWidget {
  const _FilePane({
    super.key,
    required this.self,
    required this.source,
    required this.device,
    required this.sources,
    required this.onSourceChanged,
    required this.onPathChanged,
    required this.onTransferRequested,
  });

  final DeviceProfile self;

  /// null = 本机；否则为设备指纹。
  final String? source;
  final DiscoveredDevice? device;
  final List<({String? fingerprint, String alias})> sources;
  final ValueChanged<String?> onSourceChanged;
  final ValueChanged<String?> onPathChanged;
  final void Function(FileEntry entry, String fullPath, bool move)
      onTransferRequested;

  @override
  State<_FilePane> createState() => _FilePaneState();
}

class _FilePaneState extends State<_FilePane> {
  final LocalFileSystemAdapter _fs = LocalFileSystemAdapter();
  String? _path;
  List<FileEntry> _entries = [];
  bool _loading = true;
  String? _error;
  SyncMateClient? _client;
  late p.Context _remotePath;

  bool get _isRemote => widget.source != null;

  @override
  void initState() {
    super.initState();
    _remotePath =
        widget.device?.deviceType == 'windows' ? p.windows : p.posix;
    _load();
  }

  @override
  void didUpdateWidget(covariant _FilePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source != oldWidget.source ||
        widget.device?.fingerprint != oldWidget.device?.fingerprint) {
      _path = null;
      _client = null;
      _remotePath =
          widget.device?.deviceType == 'windows' ? p.windows : p.posix;
      _load();
    }
  }

  void reload() => _load();

  String _join(String dir, String name) =>
      _isRemote ? _remotePath.join(dir, name) : p.join(dir, name);

  String _joinCurrent(String name) => _join(_path ?? '', name);

  Future<void> _load() async {
    if (_isRemote) {
      await _loadRemote();
    } else {
      await _loadLocal();
    }
  }

  Future<void> _loadRemote() async {
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

  Future<void> _loadLocal() async {
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
    setState(() => _path = _joinCurrent(entry.name));
    _load();
  }

  void _goUp() {
    if (_path == null) return;
    final dirname = _isRemote ? _remotePath.dirname : p.dirname;
    final parent = dirname(_path!);
    setState(() => _path = parent == _path ? null : parent);
    _load();
  }

  void _goRoot() {
    setState(() => _path = null);
    _load();
  }

  /// 点击：文件夹进入；文件弹出操作菜单。长按：弹出操作菜单。
  void _select(FileEntry entry) {
    if (entry.isDir) {
      _enter(entry);
      return;
    }
    _showEntryActions(entry);
  }

  Future<void> _showEntryActions(FileEntry entry) async {
    final fullPath = _joinCurrent(entry.name);
    final action = await _showActionDialog(context, entry);
    if (!mounted || action == null) return;
    switch (action) {
      case _EntryAction.copy:
        widget.onTransferRequested(entry, fullPath, false);
      case _EntryAction.move:
        widget.onTransferRequested(entry, fullPath, true);
      case _EntryAction.rename:
        await _renameEntry(entry);
      case _EntryAction.edit:
        await _editEntry(entry);
      case _EntryAction.zip:
        await _zipEntry(entry);
      case _EntryAction.unzip:
        await _unzipEntry(entry);
      case _EntryAction.zipMove:
        await _zipAndMove(entry);
      case _EntryAction.unzipMove:
        await _unzipAndMove(entry);
      case _EntryAction.delete:
        await _deleteEntry(entry);
    }
  }

  Future<void> _renameEntry(FileEntry entry) async {
    final from = _joinCurrent(entry.name);
    final name = await _promptText('重命名', '新名称', entry.name);
    if (name == null || name.isEmpty || name == entry.name) return;
    try {
      if (_isRemote) {
        await _clientFor().move(from, _join(_remotePath.dirname(from), name));
      } else {
        await _fs.move(from, p.join(p.dirname(from), name));
      }
      _showMessage('已重命名');
    } on FsException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on ApiException catch (e) {
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
    final confirmed = await _confirmDelete(entry.name);
    if (!confirmed) return;
    try {
      if (_isRemote) {
        await _clientFor().delete(_joinCurrent(entry.name), recursive: true);
      } else {
        await _fs.delete(_joinCurrent(entry.name), recursive: true);
      }
      _showMessage('已删除 ${entry.name}');
    } on FsException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  SyncMateClient _clientFor() {
    final device = widget.device!;
    return _client ??= SyncMateClient(
      baseUrl: device.baseUrl,
      fingerprint: widget.self.fingerprint,
    );
  }

  /// 当前视图目录（根目录时取第一个存储根）。
  String get _currentDir =>
      _path ?? (_entries.isEmpty ? '' : _entries.first.name);

  String _compressBaseName(FileEntry entry) =>
      entry.isDir ? entry.name : p.basenameWithoutExtension(entry.name);

  Future<String> _doCompress(FileEntry entry, String format) {
    final ext = format == 'tar.gz' ? 'tar.gz' : 'zip';
    final archive = _join(_currentDir, '${_compressBaseName(entry)}.$ext');
    final fullPath = _joinCurrent(entry.name);
    if (_isRemote) return _clientFor().compress(fullPath, archive);
    return _fs.compress(fullPath, archive);
  }

  Future<String> _doExtract(FileEntry entry) {
    final fullPath = _joinCurrent(entry.name);
    final container = _isContainerArchive(entry.name);
    final target = container
        ? _join(_currentDir, _archiveBaseName(entry.name))
        : _currentDir;
    if (_isRemote) return _clientFor().extract(fullPath, target);
    return _fs.extract(fullPath, target);
  }

  Future<String?> _pickCompressFormat() {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('选择压缩格式'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('zip'),
            child: const Text('zip'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('tar.gz'),
            child: const Text('tar.gz'),
          ),
        ],
      ),
    );
  }

  Future<void> _zipEntry(FileEntry entry) async {
    final format = await _pickCompressFormat();
    if (format == null || !mounted) return;
    try {
      final result = await _doCompress(entry, format);
      _showMessage('已压缩为 ${p.basename(result)}');
    } on FsException catch (e) {
      _showMessage('压缩失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('压缩失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('压缩失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  Future<void> _unzipEntry(FileEntry entry) async {
    try {
      final result = await _doExtract(entry);
      _showMessage('已解压到 ${p.basename(result)}');
    } on FsException catch (e) {
      _showMessage('解压失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('解压失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('解压失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  Future<void> _zipAndMove(FileEntry entry) async {
    final format = await _pickCompressFormat();
    if (format == null || !mounted) return;
    final String result;
    try {
      result = await _doCompress(entry, format);
    } on FsException catch (e) {
      _showMessage('压缩失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('压缩失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('压缩失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
    widget.onTransferRequested(
      FileEntry(name: p.basename(result), isDir: false, size: 0, modified: 0),
      result,
      true,
    );
  }

  Future<void> _unzipAndMove(FileEntry entry) async {
    final String result;
    try {
      result = await _doExtract(entry);
    } on FsException catch (e) {
      _showMessage('解压失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('解压失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('解压失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
    widget.onTransferRequested(
      FileEntry(
        name: p.basename(result),
        isDir: _isContainerArchive(entry.name),
        size: 0,
        modified: 0,
      ),
      result,
      true,
    );
  }

  Future<void> _editEntry(FileEntry entry) async {
    if (entry.size > 512 * 1024) {
      _showMessage('文件超过 512KB，暂不支持编辑');
      return;
    }
    final fullPath = _joinCurrent(entry.name);
    final String initial;
    try {
      initial = _isRemote
          ? await _clientFor().readContent(fullPath)
          : await _fs.readText(fullPath);
    } on FsException catch (e) {
      _showMessage('读取失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('读取失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('读取失败：$e');
      return;
    }
    if (!mounted) return;
    final edited = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _EditPage(title: entry.name, initial: initial),
      ),
    );
    if (edited == null || !mounted) return;
    try {
      if (_isRemote) {
        await _clientFor().writeContent(fullPath, edited);
      } else {
        await _fs.writeText(fullPath, edited);
      }
      _showMessage('已保存');
    } on FsException catch (e) {
      _showMessage('保存失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('保存失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('保存失败：$e');
      return;
    }
    if (!mounted) return;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final label = _sourceLabel();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                PopupMenuButton<String?>(
                  tooltip: '切换视图来源',
                  onSelected: (fp) {
                    if (fp != widget.source) widget.onSourceChanged(fp);
                  },
                  itemBuilder: (context) => [
                    for (final s in widget.sources)
                      PopupMenuItem<String?>(
                        value: s.fingerprint,
                        child: Text(s.alias),
                      ),
                  ],
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isRemote ? Icons.smartphone : Icons.computer,
                        size: 18,
                      ),
                      const SizedBox(width: 4),
                      Text(label, style: Theme.of(context).textTheme.titleMedium),
                      const Icon(Icons.arrow_drop_down, size: 18),
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  _path ?? '(根目录)',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 4),
            _buildToolbar(context),
            const SizedBox(height: 4),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  String _sourceLabel() {
    if (!_isRemote) return '本机';
    final device = widget.device;
    if (device != null) return device.alias;
    return '离线设备';
  }

  Widget _buildToolbar(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: '返回上级',
          icon: const Icon(Icons.arrow_upward, size: 18),
          onPressed: _path == null ? null : _goUp,
        ),
        IconButton(
          tooltip: '根目录',
          icon: const Icon(Icons.home, size: 18),
          onPressed: _path == null ? null : _goRoot,
        ),
        const Spacer(),
        IconButton(
          tooltip: '刷新',
          icon: const Icon(Icons.refresh, size: 18),
          onPressed: _load,
        ),
        PopupMenuButton<String>(
          tooltip: '操作',
          onSelected: (_) => _handleMkdir(),
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'mkdir', child: Text('新建文件夹')),
          ],
        ),
      ],
    );
  }

  Future<void> _handleMkdir() async {
    final name = await _promptText('新建文件夹', '文件夹名称', '新建文件夹');
    if (name == null || name.isEmpty) return;
    final base = _path ?? (_entries.isEmpty ? '' : _entries.first.name);
    try {
      if (_isRemote) {
        await _clientFor().mkdir(_join(base, name));
      } else {
        await _fs.mkdir(p.join(base, name));
      }
      _showMessage('已创建 $name');
    } on FsException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on ApiException catch (e) {
      _showMessage('操作失败：${e.message}');
      return;
    } on Object catch (e) {
      _showMessage('操作失败：$e');
      return;
    }
    if (!mounted) return;
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

/// 支持的压缩包扩展名（解压可用）。
bool _isArchiveName(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.zip') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.tar.gz') ||
      lower.endsWith('.tgz') ||
      lower.endsWith('.tar.bz2') ||
      lower.endsWith('.tbz2') ||
      lower.endsWith('.tbz') ||
      lower.endsWith('.tar.xz') ||
      lower.endsWith('.txz') ||
      lower.endsWith('.gz') ||
      lower.endsWith('.bz2') ||
      lower.endsWith('.xz');
}

/// 容器型压缩包（解压产出文件夹）；单文件型（.gz/.bz2/.xz）解压产出文件。
bool _isContainerArchive(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.zip') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.tar.gz') ||
      lower.endsWith('.tgz') ||
      lower.endsWith('.tar.bz2') ||
      lower.endsWith('.tbz2') ||
      lower.endsWith('.tbz') ||
      lower.endsWith('.tar.xz') ||
      lower.endsWith('.txz');
}

/// 去掉压缩包扩展名（含复合扩展名，如 foo.tar.gz → foo）。
String _archiveBaseName(String name) {
  final lower = name.toLowerCase();
  for (final ext in [
    '.tar.gz', '.tar.bz2', '.tar.xz', '.tbz2', '.tbz', '.txz', '.tgz',
    '.zip', '.tar', '.gz', '.bz2', '.xz',
  ]) {
    if (lower.endsWith(ext)) {
      return name.substring(0, name.length - ext.length);
    }
  }
  return name;
}

/// 独立文本编辑页（保存后以内容字符串返回）。
class _EditPage extends StatefulWidget {
  const _EditPage({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<_EditPage> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _controller,
          maxLines: null,
          expands: true,
          autofocus: true,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '文本内容（UTF-8）',
          ),
        ),
      ),
    );
  }
}

enum _EntryAction {
  copy,
  move,
  rename,
  edit,
  zip,
  unzip,
  zipMove,
  unzipMove,
  delete,
}

Future<_EntryAction?> _showActionDialog(
  BuildContext context,
  FileEntry entry,
) {
  final name = entry.name;
  final isDir = entry.isDir;
  final isArchive = _isArchiveName(name);
  final isContainer = _isContainerArchive(name);
  return showDialog<_EntryAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(name, overflow: TextOverflow.ellipsis),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.copy),
              title: const Text('复制'),
              subtitle: const Text('复制到另一视图的当前目录'),
              onTap: () => Navigator.of(dialogContext).pop(_EntryAction.copy),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移动'),
              subtitle: const Text('移动到另一视图的当前目录'),
              onTap: () => Navigator.of(dialogContext).pop(_EntryAction.move),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => Navigator.of(dialogContext).pop(_EntryAction.rename),
            ),
            if (!isDir)
              ListTile(
                dense: true,
                leading: const Icon(Icons.edit_outlined),
                title: const Text('编辑'),
                subtitle: const Text('编辑文本内容（UTF-8，≤512KB）'),
                onTap: () => Navigator.of(dialogContext).pop(_EntryAction.edit),
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.folder_zip),
              title: const Text('压缩'),
              subtitle: const Text('打包为 zip / tar.gz'),
              onTap: () => Navigator.of(dialogContext).pop(_EntryAction.zip),
            ),
            if (isArchive)
              ListTile(
                dense: true,
                leading: const Icon(Icons.unarchive),
                title: const Text('解压'),
                subtitle: Text(
                  isContainer ? '解压到同名文件夹' : '解压为同名文件',
                ),
                onTap: () => Navigator.of(dialogContext).pop(_EntryAction.unzip),
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.archive_outlined),
              title: const Text('压缩并移动'),
              subtitle: const Text('压缩后移动到另一视图的当前目录'),
              onTap: () =>
                  Navigator.of(dialogContext).pop(_EntryAction.zipMove),
            ),
            if (isArchive)
              ListTile(
                dense: true,
                leading: const Icon(Icons.unarchive_outlined),
                title: const Text('解压并移动'),
                subtitle: Text(
                  isContainer ? '解压后移动到另一视图的当前目录' : '解压为文件后移动到另一视图的当前目录',
                ),
                onTap: () =>
                    Navigator.of(dialogContext).pop(_EntryAction.unzipMove),
              ),
            ListTile(
              dense: true,
              leading: Icon(isDir ? Icons.folder_delete : Icons.delete_outline),
              title: const Text('删除'),
              onTap: () => Navigator.of(dialogContext).pop(_EntryAction.delete),
            ),
          ],
        ),
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
