/// 传输任务编排：复制（上传/下载）、进度事件、速度统计、取消、断点续传。
///
/// 下载：本机已存在同名文件且大小>0 时从该大小续传（先查远端总大小，
/// 已完整则直接完成）；大小 0 视为新文件，自动重命名目标。
/// 上传：先查服务端分片进度，从该 offset 续传；取消时清理服务端 .sm-part。
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
  });

  final String id;
  final String remotePath;
  String localPath;
  final bool toRemote;
  final TransferCancel cancelToken = TransferCancel();

  int total = 0;
  int done = 0;
  double speed = 0;
  TransferStatus status = TransferStatus.running;
  String? error;
  String? finalRemotePath;

  String get label => toRemote ? localPath : remotePath;

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
  }) async {
    final task = TransferTask(
      id: 't${_nextId++}',
      remotePath: remotePath,
      localPath: localPath,
      toRemote: toRemote,
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
      if (task.toRemote) {
        await _runUpload(task, client, meter);
      } else {
        await _runDownload(task, client, meter);
      }
      task.status = TransferStatus.done;
      task.speed = 0;
    } on _Cancelled {
      task.status = TransferStatus.cancelled;
      task.speed = 0;
      if (task.toRemote) {
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
    } on Object catch (e) {
      task.status = TransferStatus.failed;
      task.error = e.toString();
      task.speed = 0;
    } finally {
      _events.add(TaskFinished(task));
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
