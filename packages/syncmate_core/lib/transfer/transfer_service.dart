/// 传输任务编排：复制（上传/下载）、进度事件、速度统计、取消、断点续传。
///
/// 单文件下载：本机已存在同名文件且大小>0 时从该大小续传（先查远端总大小，
/// 已完整则直接完成）；大小 0 视为新文件，自动重命名目标。
/// 单文件上传：先查服务端分片进度，从该 offset 续传；取消时清理服务端 .sm-part。
/// 目录复制：递归收集文件清单与总大小后逐个传输，先建目录再传文件。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../client/syncmate_client.dart';
import '../discovery/discovery_service.dart';
import '../model/api_error.dart';
import '../model/device_profile.dart';

class TransferCancel {
  bool cancelled = false;

  void cancel() => cancelled = true;
}

enum TransferStatus { running, done, failed, cancelled }

class TransferTask {
  TransferTask({
    required this.id,
    required this.remotePath,
    required this.localPath,
    required this.toRemote,
    this.isDirectory = false,
    this.sourceBaseUrl,
    this.moveAfter = false,
    this.labelOverride,
  });

  final String id;
  final String remotePath;
  String localPath;
  final bool toRemote;
  final bool isDirectory;

  /// 设备→设备模式：源设备 baseUrl（非 null 表示两个不同设备之间复制）。
  final String? sourceBaseUrl;

  /// 设备→设备模式：传输成功后删除源路径（即"移动"）。
  final bool moveAfter;

  final String? labelOverride;
  final TransferCancel cancelToken = TransferCancel();

  int total = 0;
  int done = 0;
  double speed = 0;
  TransferStatus status = TransferStatus.running;
  String? error;
  String? finalRemotePath;

  String get label => labelOverride ?? (toRemote ? localPath : remotePath);

  double get progress => total <= 0 ? 0 : done / total;
}

sealed class TransferEvent {}

class TaskAdded extends TransferEvent {
  TaskAdded(this.task);
  final TransferTask task;
}

class TaskProgress extends TransferEvent {
  TaskProgress(this.task);
  final TransferTask task;
}

class TaskFinished extends TransferEvent {
  TaskFinished(this.task);
  final TransferTask task;
}

typedef _RemoteFileEntry = ({String remote, String local, int size});

class TransferService {
  TransferService({required this.self});

  final DeviceProfile self;
  final StreamController<TransferEvent> _events =
      StreamController<TransferEvent>.broadcast();
  final Map<String, TransferTask> _tasks = {};
  final Map<String, SyncMateClient> _clients = {};
  int _nextId = 0;

  Stream<TransferEvent> get events => _events.stream;

  List<TransferTask> get tasks => List.unmodifiable(_tasks.values);

  /// [toRemote] 为 true：本机 → 对方（上传），[localPath] 源、[remotePath] 目标。
  /// 为 false：对方 → 本机（下载），[remotePath] 源、[localPath] 目标目录+文件名。
  Future<TransferTask> copy({
    required DiscoveredDevice device,
    required String remotePath,
    required String localPath,
    required bool toRemote,
  }) {
    return _add(
      device: device,
      remotePath: remotePath,
      localPath: localPath,
      toRemote: toRemote,
    );
  }

  /// 目录整体复制：递归传输目录内全部文件。
  Future<TransferTask> copyDirectory({
    required DiscoveredDevice device,
    required String remotePath,
    required String localPath,
    required bool toRemote,
  }) {
    return _add(
      device: device,
      remotePath: remotePath,
      localPath: localPath,
      toRemote: toRemote,
      isDirectory: true,
    );
  }

  /// 设备→设备复制：经本机临时目录中转，[move] 为 true 时成功后删除源。
  Future<TransferTask> copyBetweenDevices({
    required DiscoveredDevice from,
    required String fromPath,
    required DiscoveredDevice to,
    required String toPath,
    bool move = false,
  }) {
    final name = _baseName(fromPath);
    return _add(
      device: to,
      remotePath: toPath,
      localPath: fromPath,
      toRemote: true,
      isDirectory: true,
      sourceBaseUrl: from.baseUrl,
      moveAfter: move,
      labelOverride:
          '${move ? '移动' : '复制'}（${from.alias} → ${to.alias}）$name',
    );
  }

  Future<TransferTask> _add({
    required DiscoveredDevice device,
    required String remotePath,
    required String localPath,
    required bool toRemote,
    bool isDirectory = false,
    String? sourceBaseUrl,
    bool moveAfter = false,
    String? labelOverride,
  }) async {
    final task = TransferTask(
      id: 't${_nextId++}',
      remotePath: remotePath,
      localPath: localPath,
      toRemote: toRemote,
      isDirectory: isDirectory,
      sourceBaseUrl: sourceBaseUrl,
      moveAfter: moveAfter,
      labelOverride: labelOverride,
    );
    _tasks[task.id] = task;
    _events.add(TaskAdded(task));
    unawaited(_run(task, device));
    return task;
  }

  void dispose() {
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
    _tasks.clear();
    unawaited(_events.close());
  }

  Future<void> _run(TransferTask task, DiscoveredDevice device) async {
    final client = _clients.putIfAbsent(
      device.fingerprint,
      () => SyncMateClient(
        baseUrl: device.baseUrl,
        fingerprint: self.fingerprint,
      ),
    );
    final meter = _SpeedMeter();
    try {
      if (task.sourceBaseUrl != null) {
        final fromClient = _clients.putIfAbsent(
          'src|${task.sourceBaseUrl}',
          () => SyncMateClient(
            baseUrl: task.sourceBaseUrl!,
            fingerprint: self.fingerprint,
          ),
        );
        await _runBetweenDevices(task, fromClient, client, meter);
      } else if (task.isDirectory) {
        if (task.toRemote) {
          await _runDirUpload(task, client, meter);
        } else {
          await _runDirDownload(task, client, meter);
        }
      } else if (task.toRemote) {
        await _runUpload(task, client, meter);
      } else {
        await _runDownload(task, client, meter);
      }
      task.status = TransferStatus.done;
      task.speed = 0;
    } on _Cancelled {
      task.status = TransferStatus.cancelled;
      task.speed = 0;
      if (task.toRemote && !task.isDirectory) {
        try {
          await client.cancelUpload(task.remotePath);
        } on Object {
          // 服务端清理失败不阻断
        }
      }
    } on ApiException catch (e) {
      task.status = TransferStatus.failed;
      task.error = e.message;
      task.speed = 0;
    } on HttpException catch (e) {
      task.status = TransferStatus.failed;
      task.error = '传输中断（连接被对方关闭）：${e.message}';
      task.speed = 0;
    } on Object catch (e) {
      task.status = TransferStatus.failed;
      task.error = e.toString();
      task.speed = 0;
    } finally {
      _events.add(TaskFinished(task));
    }
  }

  /// 设备→设备：下载到本机临时目录，再上传到目标设备；moveAfter 时删源。
  Future<void> _runBetweenDevices(
    TransferTask task,
    SyncMateClient fromClient,
    SyncMateClient toClient,
    _SpeedMeter meter,
  ) async {
    final tmpRoot = await Directory.systemTemp.createTemp('syncmate_between_');
    try {
      int? fileSize;
      try {
        fileSize = await fromClient.fileSize(task.localPath);
      } on ApiException {
        fileSize = null;
      }
      if (fileSize != null) {
        // 源为单个文件
        task.total = fileSize;
        _emit(task);
        if (fileSize > 0) {
          final tmpFile =
              _joinPath(tmpRoot.path, _baseName(task.localPath));
          await _downloadFile(task, fromClient, meter, task.localPath, tmpFile);
          await _uploadFile(task, toClient, meter, tmpFile, task.remotePath);
        }
      } else {
        // 源为目录：递归收集后逐个传输
        final files = <_RemoteFileEntry>[];
        await _walkRemote(fromClient, task.localPath, tmpRoot.path, files);
        task.total = files.fold(0, (sum, f) => sum + f.size);
        _emit(task);

        if (files.isEmpty) {
          try {
            await toClient.mkdir(task.remotePath);
          } on ApiException {
            // 目录已存在等情况可接受
          }
        } else {
          await _ensureRemoteDirs(toClient, files, task.remotePath);
          for (final f in files) {
            if (task.cancelToken.cancelled) throw const _Cancelled();
            await _downloadFile(task, fromClient, meter, f.remote, f.local);
            await _uploadFile(task, toClient, meter, f.local, f.remote);
          }
        }
      }
      if (task.moveAfter) {
        try {
          await fromClient.delete(task.localPath, recursive: true);
        } on Object catch (e) {
          task.error = '复制完成，但删除源失败：$e';
        }
      }
    } finally {
      try {
        await tmpRoot.delete(recursive: true);
      } on Object {
        // 临时目录清理失败不影响结果
      }
    }
  }

  Future<void> _runUpload(
    TransferTask task,
    SyncMateClient client,
    _SpeedMeter meter,
  ) async {
    const chunkSize = 1024 * 1024;
    final file = File(task.localPath);
    if (!await file.exists()) {
      throw const ApiException(ApiErrorCode.notFound, '本地文件不存在');
    }
    task.total = await file.length();
    _emit(task);
    if (task.total == 0) {
      return;
    }
    var offset = await client.uploadStatus(task.remotePath);
    if (offset >= task.total) {
      throw const ApiException(ApiErrorCode.ioError, '服务端分片已超出源文件大小');
    }
    task.done = offset;
    _emit(task);

    final raf = await file.open();
    try {
      while (offset < task.total) {
        if (task.cancelToken.cancelled) throw const _Cancelled();
        final end = offset + chunkSize < task.total ? offset + chunkSize : task.total;
        await raf.setPosition(offset);
        final data = await _readFully(raf, end - offset);
        final isFinal = end >= task.total;
        final result = await client.uploadChunk(
          task.remotePath,
          offset: offset,
          data: data,
          isFinal: isFinal,
        );
        offset = end;
        task.done = offset;
        task.speed = meter.update(task.done);
        _emit(task);
        if (isFinal && result.path != null) {
          task.finalRemotePath = result.path;
        }
      }
    } finally {
      await raf.close();
    }
  }

  Future<void> _runDownload(
    TransferTask task,
    SyncMateClient client,
    _SpeedMeter meter,
  ) async {
    final total = await client.fileSize(task.remotePath);
    task.total = total;
    _emit(task);

    var localFile = File(task.localPath);
    var offset = 0;
    if (await localFile.exists()) {
      offset = await localFile.length();
      if (offset == 0) {
        final unique = _uniqueLocalPath(task.localPath);
        task.localPath = unique;
        localFile = File(unique);
        offset = 0;
      }
    }
    if (total > 0 && offset >= total) {
      return;
    }
    task.done = offset;
    _emit(task);

    final response = await client.download(task.remotePath, offset: offset);
    final sink = localFile.openWrite(mode: FileMode.append);
    try {
      await for (final chunk in response.stream) {
        if (task.cancelToken.cancelled) throw const _Cancelled();
        sink.add(chunk);
        task.done += chunk.length;
        task.speed = meter.update(task.done);
        _emit(task);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  /// 目录复制（上传方向）：本机目录 → 对方目录。
  Future<void> _runDirUpload(
    TransferTask task,
    SyncMateClient client,
    _SpeedMeter meter,
  ) async {
    final root = Directory(task.localPath);
    if (!await root.exists()) {
      throw const ApiException(ApiErrorCode.notFound, '本地目录不存在');
    }
    final files = <_RemoteFileEntry>[];
    await _walkLocal(root.path, task.remotePath, files);
    task.total = files.fold(0, (sum, f) => sum + f.size);
    _emit(task);

    if (files.isEmpty) {
      try {
        await client.mkdir(task.remotePath);
      } on ApiException {
        // 目录已存在等情况可接受
      }
      return;
    }
    await _ensureRemoteDirs(client, files, task.remotePath);
    for (final f in files) {
      if (task.cancelToken.cancelled) throw const _Cancelled();
      await _uploadFile(task, client, meter, f.local, f.remote);
    }
  }

  /// 目录复制（下载方向）：对方目录 → 本机目录。
  Future<void> _runDirDownload(
    TransferTask task,
    SyncMateClient client,
    _SpeedMeter meter,
  ) async {
    final files = <_RemoteFileEntry>[];
    await _walkRemote(client, task.remotePath, task.localPath, files);
    task.total = files.fold(0, (sum, f) => sum + f.size);
    _emit(task);

    if (files.isEmpty) {
      await Directory(task.localPath).create(recursive: true);
      return;
    }
    await _ensureLocalDirs(task.localPath, files);
    for (final f in files) {
      if (task.cancelToken.cancelled) throw const _Cancelled();
      await _downloadFile(task, client, meter, f.remote, f.local);
    }
  }

  Future<void> _walkLocal(
    String localDir,
    String remoteDir,
    List<_RemoteFileEntry> files,
  ) async {
    await for (final entity in Directory(localDir).list(followLinks: false)) {
      if (entity is Directory) {
        await _walkLocal(
          entity.path,
          _joinPath(remoteDir, entity.path.split(Platform.pathSeparator).last),
          files,
        );
      } else if (entity is File) {
        try {
          final size = await entity.length();
          files.add((
            remote: _joinPath(remoteDir, entity.path.split(Platform.pathSeparator).last),
            local: entity.path,
            size: size,
          ));
        } on Object {
          // 不可读文件跳过
        }
      }
    }
  }

  Future<void> _walkRemote(
    SyncMateClient client,
    String remoteDir,
    String localDir,
    List<_RemoteFileEntry> files,
  ) async {
    final list = await client.listFiles(remoteDir);
    for (final entry in list.entries) {
      if (entry.isDir) {
        await _walkRemote(
          client,
          _joinPath(remoteDir, entry.name),
          _joinPath(localDir, entry.name),
          files,
        );
      } else {
        files.add((
          remote: _joinPath(remoteDir, entry.name),
          local: _joinPath(localDir, entry.name),
          size: entry.size,
        ));
      }
    }
  }

  Future<void> _ensureRemoteDirs(
    SyncMateClient client,
    List<_RemoteFileEntry> files,
    String remoteRoot,
  ) async {
    final dirs = <String>{};
    for (final f in files) {
      var parent = _parentOf(f.remote);
      while (parent.isNotEmpty && _inside(parent, remoteRoot) && parent != remoteRoot) {
        dirs.add(parent);
        parent = _parentOf(parent);
      }
    }
    final sorted = dirs.toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    for (final dir in sorted) {
      try {
        await client.mkdir(dir);
      } on ApiException {
        // 已存在或并发创建，忽略
      }
    }
  }

  String _parentOf(String path) {
    final idx = _lastSeparatorIndex(path);
    if (idx <= 0) return '';
    return path.substring(0, idx);
  }

  Future<void> _ensureLocalDirs(
    String localRoot,
    List<_RemoteFileEntry> files,
  ) async {
    final dirs = <String>{};
    for (final f in files) {
      final idx = _lastSeparatorIndex(f.local);
      if (idx > 0) dirs.add(f.local.substring(0, idx));
    }
    for (final dir in dirs) {
      if (dir.startsWith(localRoot)) {
        await Directory(dir).create(recursive: true);
      }
    }
  }

  Future<void> _uploadFile(
    TransferTask task,
    SyncMateClient client,
    _SpeedMeter meter,
    String localPath,
    String remotePath,
  ) async {
    const chunkSize = 1024 * 1024;
    final file = File(localPath);
    final length = await file.length();
    if (length == 0) return;
    final raf = await file.open();
    try {
      var offset = 0;
      while (offset < length) {
        if (task.cancelToken.cancelled) throw const _Cancelled();
        final end = offset + chunkSize < length ? offset + chunkSize : length;
        await raf.setPosition(offset);
        final data = await _readFully(raf, end - offset);
        final isFinal = end >= length;
        await client.uploadChunk(
          remotePath,
          offset: offset,
          data: data,
          isFinal: isFinal,
        );
        offset = end;
        task.done += data.length;
        task.speed = meter.update(task.done);
        _emit(task);
      }
    } finally {
      await raf.close();
    }
  }

  Future<void> _downloadFile(
    TransferTask task,
    SyncMateClient client,
    _SpeedMeter meter,
    String remotePath,
    String localPath,
  ) async {
    var localFile = File(localPath);
    if (await localFile.exists()) {
      localFile = File(_uniqueLocalPath(localPath));
    }
    final total = await client.fileSize(remotePath);
    if (total <= 0) return;
    final response = await client.download(remotePath, offset: 0);
    final sink = localFile.openWrite(mode: FileMode.append);
    try {
      await for (final chunk in response.stream) {
        if (task.cancelToken.cancelled) throw const _Cancelled();
        sink.add(chunk);
        task.done += chunk.length;
        task.speed = meter.update(task.done);
        _emit(task);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  bool _isWindowsPath(String path) => path.contains('\\');

  int _lastSeparatorIndex(String path) {
    final backslash = path.lastIndexOf('\\');
    final slash = path.lastIndexOf('/');
    return backslash > slash ? backslash : slash;
  }

  bool _inside(String path, String root) {
    if (!_isWindowsPath(path)) return path.startsWith(root);
    return path.toLowerCase().startsWith(root.toLowerCase());
  }

  String _joinPath(String dir, String name) {
    if (dir.endsWith('\\') || dir.endsWith('/')) return '$dir$name';
    return '$dir${_isWindowsPath(dir) ? '\\' : '/'}$name';
  }

  String _uniqueLocalPath(String path) {
    final dir = File(path).parent.path;
    final base = _baseNameWithoutExt(path);
    final ext = _ext(path);
    final separator = Platform.isWindows ? '\\' : '/';
    for (var i = 1; i < 10000; i++) {
      final candidate = '$dir$separator$base ($i)$ext';
      if (!File(candidate).existsSync()) return candidate;
    }
    return path;
  }

  String _baseNameWithoutExt(String path) {
    final name = path.split(Platform.isWindows ? '\\' : '/').last;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  String _ext(String path) {
    final name = path.split(Platform.isWindows ? '\\' : '/').last;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot);
  }

  String _baseName(String path) {
    final name = path.split(Platform.isWindows ? '\\' : '/').last;
    return name.isEmpty ? path : name;
  }

  Future<List<int>> _readFully(RandomAccessFile raf, int length) async {
    final builder = BytesBuilder(copy: false);
    var remaining = length;
    while (remaining > 0) {
      final chunk = await raf.read(remaining < 64 * 1024 ? remaining : 64 * 1024);
      if (chunk.isEmpty) break;
      builder.add(chunk);
      remaining -= chunk.length;
    }
    return builder.takeBytes();
  }

  void _emit(TransferTask task) {
    if (task.status == TransferStatus.running) {
      _events.add(TaskProgress(task));
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _SpeedMeter {
  DateTime _last = DateTime.now();
  int _lastDone = 0;

  double update(int done) {
    final now = DateTime.now();
    final elapsed = now.difference(_last).inMilliseconds;
    if (elapsed < 300) return 0;
    final delta = done - _lastDone;
    final speed = elapsed <= 0 ? 0.0 : delta * 1000 / elapsed;
    _last = now;
    _lastDone = done;
    return speed;
  }
}
