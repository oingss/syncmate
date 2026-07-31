/// HTTP 服务端：连接（信任建立）、设备信息与目录浏览接口。
///
/// 阶段二实现：`POST /api/device/connect`、`GET /api/device/info`。
/// 阶段三实现：`GET /api/files/list`。其余接口在阶段四~六接入同一路由分发。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../clipboard/clipboard_message.dart';
import '../config/constants.dart';
import '../fs/fs_adapter.dart';
import '../model/api_error.dart';
import '../model/device_info.dart';
import '../model/device_profile.dart';
import '../model/trusted_device.dart';
import '../security/trust_store.dart';

/// 收到连接请求（需人工确认）。
class ConnectRequest {
  ConnectRequest._({
    required this.remote,
    required Future<void> Function() onAccept,
    required Future<void> Function() onReject,
  })  : _onAccept = onAccept,
        _onReject = onReject;

  final DeviceInfo remote;
  final Future<void> Function() _onAccept;
  final Future<void> Function() _onReject;
  bool _resolved = false;

  Future<void> accept() async {
    if (_resolved) return;
    _resolved = true;
    await _onAccept();
  }

  Future<void> reject() async {
    if (_resolved) return;
    _resolved = true;
    await _onReject();
  }
}

class _PendingConnect {
  _PendingConnect(this.request);
  final HttpRequest request;
}

class _UploadSession {
  _UploadSession({
    required this.partPath,
    required this.targetPath,
    required this.written,
  });

  final String partPath;
  String targetPath;
  int written;
  DateTime lastWrite = DateTime.now();
  Timer? idleTimer;
}

class SyncMateServer {
  SyncMateServer({
    required DeviceProfile self,
    required TrustStore trustStore,
    FileSystemAdapter? fileSystem,
    this.auditLogPath,
  })  : _self = self,
        _trustStore = trustStore,
        _fs = fileSystem ?? LocalFileSystemAdapter();

  static const _headerFingerprint = 'X-SyncMate-Fingerprint';

  final DeviceProfile _self;
  final TrustStore _trustStore;
  final FileSystemAdapter _fs;
  final String? auditLogPath;
  final StreamController<ConnectRequest> _connectRequests =
      StreamController<ConnectRequest>.broadcast();
  final Map<String, _PendingConnect> _pending = {};
  final Map<String, _UploadSession> _uploads = {};
  final Map<String, WebSocket> _activeClipboardSockets = {};
  final StreamController<ClipboardServerEvent> _clipboardEvents =
      StreamController<ClipboardServerEvent>.broadcast();
  Timer? _uploadCleanupTimer;

  HttpServer? _server;

  Stream<ConnectRequest> get connectRequests => _connectRequests.stream;

  /// 剪切板连接事件（入站连接 / 断开 / 消息）。
  Stream<ClipboardServerEvent> get clipboardEvents => _clipboardEvents.stream;

  void _audit(String op, String fingerprint, String path, {String? extra}) {
    final filePath = auditLogPath;
    if (filePath == null) return;
    final line = '${DateTime.now().toIso8601String()} | $op | $fingerprint | $path'
        '${extra == null ? '' : ' | $extra'}';
    try {
      final file = File(filePath);
      // 简单轮换：超过 1MB 重置，防无限增长
      if (file.existsSync() && file.lengthSync() > 1024 * 1024) {
        file.deleteSync();
      }
      file.writeAsStringSync('$line\n', mode: FileMode.append);
    } on Object {
      // 日志失败不影响主流程
    }
  }

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, _self.port);
    _server = server;
    server.listen(_handle);
    _uploadCleanupTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _cleanupUploadSessions(),
    );
  }

  Future<void> stop() async {
    _uploadCleanupTimer?.cancel();
    await _server?.close(force: true);
    _server = null;
    _pending.clear();
    for (final session in _uploads.values) {
      session.idleTimer?.cancel();
    }
    _uploads.clear();
    for (final socket in _activeClipboardSockets.values) {
      try {
        await socket.close();
      } on Object {
        // ignore
      }
    }
    _activeClipboardSockets.clear();
    await _connectRequests.close();
    await _clipboardEvents.close();
  }

  Map<String, dynamic> get _selfInfoJson => _self.toInfo().toJson();

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/api/device/connect' && request.method == 'POST') {
        await _handleConnect(request);
      } else if (path == '/api/device/info' && request.method == 'GET') {
        await _handleInfo(request);
      } else if (path == '/api/files/list' && request.method == 'GET') {
        await _handleList(request);
      } else if (path == '/api/files/download' && request.method == 'GET') {
        await _handleDownload(request);
      } else if (path == '/api/files/upload' && request.method == 'POST') {
        await _handleUpload(request);
      } else if (path == '/api/files/upload/status' && request.method == 'GET') {
        await _handleUploadStatus(request);
      } else if (path == '/api/files/upload' && request.method == 'DELETE') {
        await _handleUploadCancel(request);
      } else if (path == '/api/files/move' && request.method == 'POST') {
        await _handleMove(request);
      } else if (path == '/api/files/copy' && request.method == 'POST') {
        await _handleCopy(request);
      } else if (path == '/api/files/delete' && request.method == 'DELETE') {
        await _handleDelete(request);
      } else if (path == '/api/files/mkdir' && request.method == 'POST') {
        await _handleMkdir(request);
      } else if (path == '/api/files/content' && request.method == 'GET') {
        await _handleReadContent(request);
      } else if (path == '/api/files/content' && request.method == 'PUT') {
        await _handleWriteContent(request);
      } else if (path == '/api/files/compress' && request.method == 'POST') {
        await _handleCompress(request);
      } else if (path == '/api/files/extract' && request.method == 'POST') {
        await _handleExtract(request);
      } else if (path == Constants.wsPath && request.method == 'GET') {
        await _handleClipboardWs(request);
      } else {
        await _writeError(
          request,
          HttpStatus.notFound,
          ApiErrorCode.notFound,
          'not found',
        );
      }
    } on Object {
      try {
        await _writeError(
          request,
          HttpStatus.internalServerError,
          ApiErrorCode.ioError,
          'internal error',
        );
      } on Object {
        // 连接已断开等场景，忽略
      }
    }
  }

  Future<void> _handleConnect(HttpRequest request) async {
    final Map<String, dynamic> body;
    try {
      final text = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      body = decoded;
    } on Object {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'invalid json body',
      );
      return;
    }

    final DeviceInfo remote;
    try {
      remote = DeviceInfo.fromJson(body);
    } on Object {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'invalid fields',
      );
      return;
    }
    if (!Constants.fingerprintPattern.hasMatch(remote.fingerprint) ||
        remote.port <= 0) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'invalid fingerprint or port',
      );
      return;
    }

    final fingerprint = remote.fingerprint;
    final existing = await _trustStore.find(fingerprint);
    if (existing != null) {
      await _trustStore.addOrUpdate(existing.copyWith(
        alias: remote.alias,
        lastConnected: DateTime.now(),
      ));
      await _writeJson(request, HttpStatus.ok, _selfInfoJson);
      return;
    }

    if (_pending.containsKey(fingerprint)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.rejected,
        'request already pending',
      );
      return;
    }

    _pending[fingerprint] = _PendingConnect(request);
    final timer = Timer(Constants.connectTimeout, () {
      final removed = _pending.remove(fingerprint);
      if (removed == null) return;
      unawaited(_writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.timeout,
        'accept timeout',
      ));
    });

    final connectRequest = ConnectRequest._(
      remote: remote,
      onAccept: () async {
        if (_pending.remove(fingerprint) == null) return;
        timer.cancel();
        await _trustStore.addOrUpdate(TrustedDevice(
          fingerprint: fingerprint,
          alias: remote.alias,
          deviceType: remote.deviceType,
          port: remote.port,
          lastConnected: DateTime.now(),
        ));
        await _writeJson(request, HttpStatus.ok, _selfInfoJson);
      },
      onReject: () async {
        if (_pending.remove(fingerprint) == null) return;
        timer.cancel();
        await _writeError(
          request,
          HttpStatus.forbidden,
          ApiErrorCode.rejected,
          'rejected by user',
        );
      },
    );
    _connectRequests.add(connectRequest);
  }

  Future<void> _handleInfo(HttpRequest request) async {
    if (!await _isTrusted(request)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.forbidden,
        'not trusted',
      );
      return;
    }
    await _writeJson(request, HttpStatus.ok, _selfInfoJson);
  }

  Future<void> _handleList(HttpRequest request) async {
    if (!await _isTrusted(request)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.forbidden,
        'not trusted',
      );
      return;
    }
    final pathParam = request.uri.queryParameters['path'];
    String? path;
    if (pathParam != null && pathParam.isNotEmpty) {
      try {
        path = utf8.decode(base64Url.decode(base64Url.normalize(pathParam)));
      } on Object {
        await _writeError(
          request,
          HttpStatus.badRequest,
          ApiErrorCode.badRequest,
          'invalid path parameter',
        );
        return;
      }
    }
    try {
      if (path == null) {
        final roots = await _fs.roots();
        await _writeJson(request, HttpStatus.ok, {
          'path': '',
          'entries': roots.map((e) => e.toJson()).toList(),
        });
      } else {
        final entries = await _fs.list(path);
        await _writeJson(request, HttpStatus.ok, {
          'path': path,
          'entries': entries.map((e) => e.toJson()).toList(),
        });
      }
    } on FsException catch (e) {
      await _writeFsError(request, e);
    }
  }

  /// 解析 JSON 请求体为 Map；失败返回 null。
  Future<Map<String, dynamic>?> _readJsonBody(HttpRequest request) async {
    try {
      final text = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      return decoded;
    } on Object {
      return null;
    }
  }

  Future<void> _handleMove(HttpRequest request) async {
    if (!await _isTrusted(request)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.forbidden,
        'not trusted',
      );
      return;
    }
    final body = await _readJsonBody(request);
    if (body == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'invalid json body',
      );
      return;
    }
    final from = body['from'];
    final to = body['to'];
    if (from is! String || from.isEmpty || to is! String || to.isEmpty) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'missing from/to',
      );
      return;
    }
    final fingerprint = request.headers.value(_headerFingerprint)!;
    try {
      final actual = await _fs.move(from, to);
      _audit('move', fingerprint, from, extra: '-> $actual');
      await _writeJson(request, HttpStatus.ok, {'ok': true, 'path': actual});
    } on FsException catch (e) {
      await _writeFsError(request, e);
    }
  }

  Future<void> _handleCopy(HttpRequest request) async {
    if (!await _isTrusted(request)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.forbidden,
        'not trusted',
      );
      return;
    }
    final body = await _readJsonBody(request);
    if (body == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'invalid json body',
      );
      return;
    }
    final from = body['from'];
    final to = body['to'];
    if (from is! String || from.isEmpty || to is! String || to.isEmpty) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'missing from/to',
      );
      return;
    }
    final fingerprint = request.headers.value(_headerFingerprint)!;
    try {
      final actual = await _fs.copy(from, to);
      _audit('copy', fingerprint, from, extra: '-> $actual');
      await _writeJson(request, HttpStatus.ok, {'ok': true, 'path': actual});
    } on FsException catch (e) {
      await _writeFsError(request, e);
    }
  }

  Future<void> _handleDelete(HttpRequest request) async {
    if (!await _isTrusted(request)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.forbidden,
        'not trusted',
      );
      return;
    }
    final path = await _pathFromQuery(request);
    if (path == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'missing path parameter',
      );
      return;
    }
    final recursive = request.uri.queryParameters['recursive'] == 'true';
    final fingerprint = request.headers.value(_headerFingerprint)!;
    try {
      await _fs.delete(path, recursive: recursive);
      _audit('delete', fingerprint, path, extra: 'recursive=$recursive');
      await _writeJson(request, HttpStatus.ok, {'ok': true});
    } on FsException catch (e) {
      await _writeFsError(request, e);
    }
  }

  Future<void> _handleMkdir(HttpRequest request) async {
    if (!await _isTrusted(request)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.forbidden,
        'not trusted',
      );
      return;
    }
    final body = await _readJsonBody(request);
    if (body == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'invalid json body',
      );
      return;
    }
    final path = body['path'];
    if (path is! String || path.isEmpty) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'missing path',
      );
      return;
    }
    final fingerprint = request.headers.value(_headerFingerprint)!;
    try {
      final actual = await _fs.mkdir(path);
      _audit('mkdir', fingerprint, actual);
      await _writeJson(request, HttpStatus.ok, {'ok': true, 'path': actual});
    } on FsException catch (e) {
      await _writeFsError(request, e);
    }
  }

  Future<void> _handleReadContent(HttpRequest request) async {
    if (!await _isTrusted(request)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.forbidden,
        'not trusted',
      );
      return;
    }
    final path = await _pathFromQuery(request);
    if (path == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'missing path parameter',
      );
      return;
    }
    final fingerprint = request.headers.value(_headerFingerprint)!;
    try {
      final content = await _fs.readText(path);
      _audit('read', fingerprint, path);
      await _writeJson(request, HttpStatus.ok, {
        'ok': true,
        'path': path,
        'content': content,
      });
    } on FsException catch (e) {
      await _writeFsError(request, e);
    }
  }

  Future<void> _handleWriteContent(HttpRequest request) async {
    if (!await _isTrusted(request)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.forbidden,
        'not trusted',
      );
      return;
    }
    final body = await _readJsonBody(request);
    if (body == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'invalid json body',
      );
      return;
    }
    final path = body['path'];
    final content = body['content'];
    if (path is! String || path.isEmpty || content is! String) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'missing path/content',
      );
      return;
    }
    final fingerprint = request.headers.value(_headerFingerprint)!;
    try {
      await _fs.writeText(path, content);
      _audit('write', fingerprint, path);
      await _writeJson(request, HttpStatus.ok, {'ok': true, 'path': path});
    } on FsException catch (e) {
      await _writeFsError(request, e);
    }
  }

  Future<void> _handleCompress(HttpRequest request) async {
    if (!await _isTrusted(request)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.forbidden,
        'not trusted',
      );
      return;
    }
    final body = await _readJsonBody(request);
    if (body == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'invalid json body',
      );
      return;
    }
    final source = body['source'];
    final archive = body['archive'];
    if (source is! String ||
        source.isEmpty ||
        archive is! String ||
        archive.isEmpty) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'missing source/archive',
      );
      return;
    }
    final fingerprint = request.headers.value(_headerFingerprint)!;
    try {
      final actual = await _fs.compress(source, archive);
      _audit('compress', fingerprint, source, extra: '-> $actual');
      await _writeJson(request, HttpStatus.ok, {'ok': true, 'path': actual});
    } on FsException catch (e) {
      await _writeFsError(request, e);
    }
  }

  Future<void> _handleExtract(HttpRequest request) async {
    if (!await _isTrusted(request)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.forbidden,
        'not trusted',
      );
      return;
    }
    final body = await _readJsonBody(request);
    if (body == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'invalid json body',
      );
      return;
    }
    final archive = body['archive'];
    final target = body['target'];
    if (archive is! String ||
        archive.isEmpty ||
        target is! String ||
        target.isEmpty) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'missing archive/target',
      );
      return;
    }
    final fingerprint = request.headers.value(_headerFingerprint)!;
    try {
      final actual = await _fs.extract(archive, target);
      _audit('extract', fingerprint, archive, extra: '-> $actual');
      await _writeJson(request, HttpStatus.ok, {'ok': true, 'path': actual});
    } on FsException catch (e) {
      await _writeFsError(request, e);
    }
  }

  /// FsException → 协议错误码 + HTTP 状态码。
  Future<void> _writeFsError(HttpRequest request, FsException e) {
    final code = switch (e.kind) {
      FsErrorKind.notFound => ApiErrorCode.notFound,
      FsErrorKind.invalidPath => ApiErrorCode.invalidPath,
      FsErrorKind.ioError => ApiErrorCode.ioError,
      FsErrorKind.conflict => ApiErrorCode.conflict,
      FsErrorKind.badRequest => ApiErrorCode.badRequest,
    };
    final status = switch (e.kind) {
      FsErrorKind.notFound => HttpStatus.notFound,
      FsErrorKind.conflict => HttpStatus.conflict,
      FsErrorKind.ioError => HttpStatus.internalServerError,
      _ => HttpStatus.badRequest,
    };
    return _writeError(request, status, code, e.message);
  }

  /// 剪切板 WS 端点：校验信任头后升级；同一来源指纹的新连接顶掉旧连接。
  Future<void> _handleClipboardWs(HttpRequest request) async {
    final fingerprint = request.headers.value(_headerFingerprint);
    if (fingerprint == null ||
        !Constants.fingerprintPattern.hasMatch(fingerprint) ||
        await _trustStore.find(fingerprint) == null) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    final WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(request);
    } on Object {
      return;
    }
    final previous = _activeClipboardSockets[fingerprint];
    if (previous != null) {
      try {
        await previous.close();
      } on Object {
        // ignore
      }
    }
    _activeClipboardSockets[fingerprint] = ws;
    _clipboardEvents.add(ClipboardConnected(ClipboardConnection(
      fingerprint: fingerprint,
      send: (data) {
        try {
          ws.add(data);
        } on Object {
          // 连接已关闭，忽略
        }
      },
    )));
    ws.listen(
      (data) {
        if (data is! String) return;
        if (data == '{"type":"ping"}') {
          try {
            ws.add('{"type":"pong"}');
          } on Object {
            // ignore
          }
          return;
        }
        final message = ClipboardMessage.tryParse(data);
        if (message != null) {
          _clipboardEvents.add(ClipboardMessageReceived(message));
        }
      },
      onDone: () {
        _activeClipboardSockets.remove(fingerprint);
        _clipboardEvents.add(ClipboardDisconnected(fingerprint));
      },
      onError: (Object _) {
        _activeClipboardSockets.remove(fingerprint);
        _clipboardEvents.add(ClipboardDisconnected(fingerprint));
      },
    );
  }

  Future<bool> _isTrusted(HttpRequest request) async {
    final header = request.headers.value(_headerFingerprint);
    if (header == null || !Constants.fingerprintPattern.hasMatch(header)) {
      return false;
    }
    return await _trustStore.find(header) != null;
  }

  Future<String?> _pathFromQuery(HttpRequest request) async {
    final pathParam = request.uri.queryParameters['path'];
    if (pathParam == null || pathParam.isEmpty) return null;
    try {
      return utf8.decode(base64Url.decode(base64Url.normalize(pathParam)));
    } on Object {
      return null;
    }
  }

  Future<void> _handleDownload(HttpRequest request) async {
    if (!await _isTrusted(request)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.forbidden,
        'not trusted',
      );
      return;
    }
    final path = await _pathFromQuery(request);
    if (path == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'missing path parameter',
      );
      return;
    }
    var offset = 0;
    final offsetParam = request.uri.queryParameters['offset'];
    if (offsetParam != null && offsetParam.isNotEmpty) {
      final parsed = int.tryParse(offsetParam);
      if (parsed == null || parsed < 0) {
        await _writeError(
          request,
          HttpStatus.badRequest,
          ApiErrorCode.badRequest,
          'invalid offset parameter',
        );
        return;
      }
      offset = parsed;
    }
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    var rangeEnd = -1;
    var hasRange = false;
    if (rangeHeader != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(rangeHeader);
      if (match != null) {
        hasRange = true;
        final start = match.group(1)!;
        final end = match.group(2)!;
        if (start.isNotEmpty) {
          final parsed = int.tryParse(start);
          if (parsed != null && parsed >= 0) offset = parsed;
        }
        if (end.isNotEmpty) {
          rangeEnd = int.tryParse(end) ?? -1;
        }
      }
    }
    try {
      final total = await _fs.fileSize(path);
      if (offset > total) {
        await _writeError(
          request,
          HttpStatus.badRequest,
          ApiErrorCode.badRequest,
          'offset beyond file end',
        );
        return;
      }
      var end = total - 1;
      if (rangeEnd >= 0 && rangeEnd < end) end = rangeEnd;
      final response = request.response;
      response.statusCode =
          (offset > 0 || hasRange) ? HttpStatus.partialContent : HttpStatus.ok;
      response.headers.contentType =
          ContentType('application', 'octet-stream');
      response.contentLength = end - offset + 1;
      if (offset > 0 || hasRange) {
        response.headers.set(HttpHeaders.contentRangeHeader,
            'bytes $offset-$end/$total');
      }
      if (offset >= total) {
        await response.close();
        return;
      }
      var served = 0;
      var started = false;
      try {
        await for (final chunk
            in _fs.readFile(path, offset: offset, maxBytes: end - offset + 1)) {
          response.add(chunk);
          started = true;
          served += chunk.length;
          if (served >= end - offset + 1) break;
        }
      } on FsException catch (e) {
        if (!started) {
          await _writeFsError(request, e);
          return;
        }
      } on Object {
        // 客户端断开等场景，忽略写错误
      }
      try {
        await response.close();
      } on Object {
        // ignore
      }
    } on FsException catch (e) {
      await _writeFsError(request, e);
    }
  }

  Future<void> _handleUpload(HttpRequest request) async {
    if (!await _isTrusted(request)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.forbidden,
        'not trusted',
      );
      return;
    }
    final sourceFingerprint = request.headers.value(_headerFingerprint)!;
    final path = await _pathFromQuery(request);
    if (path == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'missing path parameter',
      );
      return;
    }
    final offsetParam = request.uri.queryParameters['offset'] ?? '0';
    final offset = int.tryParse(offsetParam);
    if (offset == null || offset < 0) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'invalid offset parameter',
      );
      return;
    }
    final isFinal = request.uri.queryParameters['final'] == 'true';

    String targetPath;
    try {
      targetPath = await _fs.normalizePath(path);
    } on FsException {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.invalidPath,
        'path outside storage roots',
      );
      return;
    }

    final key = '$sourceFingerprint|$targetPath';
    var session = _uploads[key];
    if (session == null) {
      final partPath = '${targetPath}${Constants.partFileSuffix}';
      var written = await _fs.partSize(partPath);
      if (offset == 0 && written == 0) {
        final exists = await _fs.fileSize(targetPath).then((_) => true)
            .catchError((Object _) => false);
        final overwrite = request.headers.value('X-SyncMate-Overwrite') == 'true';
        if (exists && !overwrite) {
          targetPath = await _fs.uniquePath(targetPath);
        }
      }
      session = _UploadSession(
        partPath: partPath,
        targetPath: targetPath,
        written: written,
      );
      _uploads[key] = session;
    }

    if (offset != session.written) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'offset mismatch: expected ${session.written}, got $offset',
      );
      return;
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > 4 * 1024 * 1024) {
        await _writeError(
          request,
          HttpStatus.badRequest,
          ApiErrorCode.badRequest,
          'chunk too large',
        );
        return;
      }
    }
    final data = builder.takeBytes();
    if (data.isEmpty) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'empty body',
      );
      return;
    }

    try {
      session.written = await _fs.appendPart(session.partPath, data);
    } on FsException catch (e) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.ioError,
        e.message,
      );
      return;
    }
    session.lastWrite = DateTime.now();
    _scheduleIdleCleanup(key, session);

    if (isFinal) {
      if (session.written != offset + data.length) {
        await _writeError(
          request,
          HttpStatus.badRequest,
          ApiErrorCode.ioError,
          'written size mismatch on finalize',
        );
        return;
      }
      _uploads.remove(key);
      session.idleTimer?.cancel();
      String finalPath;
      try {
        finalPath = await _fs.commitPart(session.partPath, session.targetPath);
      } on FsException catch (e) {
        await _writeError(
          request,
          HttpStatus.badRequest,
          ApiErrorCode.ioError,
          e.message,
        );
        return;
      }
      await _writeJson(request, HttpStatus.ok, {
        'ok': true,
        'path': finalPath,
      });
    } else {
      await _writeJson(request, HttpStatus.ok, {
        'ok': true,
        'offset': session.written,
      });
    }
  }

  Future<void> _handleUploadStatus(HttpRequest request) async {
    if (!await _isTrusted(request)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.forbidden,
        'not trusted',
      );
      return;
    }
    final sourceFingerprint = request.headers.value(_headerFingerprint)!;
    final path = await _pathFromQuery(request);
    if (path == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'missing path parameter',
      );
      return;
    }
    String targetPath;
    try {
      targetPath = await _fs.normalizePath(path);
    } on FsException {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.invalidPath,
        'path outside storage roots',
      );
      return;
    }
    final key = '$sourceFingerprint|$targetPath';
    final session = _uploads[key];
    final offset = session?.written ??
        await _fs.partSize('${targetPath}${Constants.partFileSuffix}');
    await _writeJson(request, HttpStatus.ok, {'ok': true, 'offset': offset});
  }

  Future<void> _handleUploadCancel(HttpRequest request) async {
    if (!await _isTrusted(request)) {
      await _writeError(
        request,
        HttpStatus.forbidden,
        ApiErrorCode.forbidden,
        'not trusted',
      );
      return;
    }
    final sourceFingerprint = request.headers.value(_headerFingerprint)!;
    final path = await _pathFromQuery(request);
    if (path == null) {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.badRequest,
        'missing path parameter',
      );
      return;
    }
    String targetPath;
    try {
      targetPath = await _fs.normalizePath(path);
    } on FsException {
      await _writeError(
        request,
        HttpStatus.badRequest,
        ApiErrorCode.invalidPath,
        'path outside storage roots',
      );
      return;
    }
    final key = '$sourceFingerprint|$targetPath';
    final session = _uploads.remove(key);
    session?.idleTimer?.cancel();
    await _fs.deletePart('${targetPath}${Constants.partFileSuffix}');
    await _writeJson(request, HttpStatus.ok, {'ok': true});
  }

  void _scheduleIdleCleanup(String key, _UploadSession session) {
    session.idleTimer?.cancel();
    session.idleTimer = Timer(Constants.uploadSessionTimeout, () {
      final current = _uploads[key];
      if (current == null || !identical(current, session)) return;
      _uploads.remove(key);
      unawaited(_fs.deletePart(session.partPath));
    });
  }

  void _cleanupUploadSessions() {
    final cutoff = DateTime.now().subtract(Constants.uploadSessionTimeout);
    final stale = _uploads.entries
        .where((e) => e.value.lastWrite.isBefore(cutoff))
        .toList();
    for (final entry in stale) {
      _uploads.remove(entry.key);
      entry.value.idleTimer?.cancel();
      unawaited(_fs.deletePart(entry.value.partPath));
    }
  }

  Future<void> _writeJson(HttpRequest request, int status, Object body) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> _writeError(
    HttpRequest request,
    int status,
    ApiErrorCode code,
    String message,
  ) async {
    await _writeJson(request, status, {
      'error': {'code': code.wire, 'message': message},
    });
  }
}
