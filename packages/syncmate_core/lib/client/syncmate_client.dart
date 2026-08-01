/// HTTP 客户端：连接（信任建立）、设备信息、目录浏览、文件传输与写操作。
///
/// 阶段二：`connect` / `deviceInfo`；阶段三：`listRoots` / `listFiles`；
/// 阶段四：`download` / `uploadChunk` / `uploadStatus` / `cancelUpload`；
/// 阶段五：`move` / `delete` / `mkdir`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/constants.dart';
import '../model/api_error.dart';
import '../model/device_info.dart';
import '../model/device_profile.dart';
import '../model/file_list.dart';

class SyncMateClient {
  SyncMateClient({required this.baseUrl, required String fingerprint})
      : _fingerprint = fingerprint;

  final String baseUrl;
  final String _fingerprint;
  final HttpClient _http = HttpClient();

  Future<DeviceInfo> connect(DeviceProfile self) async {
    final uri = Uri.parse('$baseUrl/api/device/connect');
    final request = await _http.postUrl(uri).timeout(Constants.connectTimeout);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(self.toInfo().toJson()));
    final response = await request.close().timeout(Constants.connectTimeout);
    return _parseDeviceInfo(response);
  }

  Future<DeviceInfo> deviceInfo({required String fingerprint}) async {
    final uri = Uri.parse('$baseUrl/api/device/info');
    final request = await _http.getUrl(uri).timeout(Constants.connectTimeout);
    request.headers.set(_headerFingerprint, fingerprint);
    final response = await request.close().timeout(Constants.connectTimeout);
    return _parseDeviceInfo(response);
  }

  Future<FileList> listRoots() => _getFileList('/api/files/list');

  Future<FileList> listFiles(String path) {
    final encoded = base64Url.encode(utf8.encode(path));
    return _getFileList('/api/files/list?path=$encoded');
  }

  Future<FileList> _getFileList(String pathAndQuery) async {
    final uri = Uri.parse('$baseUrl$pathAndQuery');
    final request = await _http.getUrl(uri).timeout(Constants.connectTimeout);
    request.headers.set(_headerFingerprint, _fingerprint);
    final response = await request.close().timeout(Constants.connectTimeout);
    return _parseFileList(response);
  }

  /// 查询远端文件总大小（Range 探测，只读 1 字节）。
  Future<int> fileSize(String path) async {
    final encoded = base64Url.encode(utf8.encode(path));
    final uri = Uri.parse('$baseUrl/api/files/download?path=$encoded');
    final request = await _http.getUrl(uri).timeout(Constants.connectTimeout);
    request.headers.set(_headerFingerprint, _fingerprint);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final response = await request.close().timeout(Constants.connectTimeout);
    if (response.statusCode != HttpStatus.partialContent) {
      final text = await utf8.decoder.bind(response).join();
      throw _parseError(response.statusCode, text);
    }
    await response.drain<void>();
    final total = _parseContentRangeTotal(
      response.headers.value(HttpHeaders.contentRangeHeader),
    );
    if (total == null) {
      throw const ApiException(ApiErrorCode.badRequest, 'missing content-range');
    }
    return total;
  }

  /// 下载文件数据流。响应携带总大小与起始偏移（断点续传）。
  ///
  /// 调用方负责消费流；stream 发出错误时抛出 [ApiException]。
  Future<DownloadResponse> download(String path, {int offset = 0}) async {
    final encoded = base64Url.encode(utf8.encode(path));
    final uri = Uri.parse('$baseUrl/api/files/download?path=$encoded&offset=$offset');
    final request = await _http.getUrl(uri).timeout(Constants.connectTimeout);
    request.headers.set(_headerFingerprint, _fingerprint);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    final response = await request.close().timeout(Constants.connectTimeout);
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      final text = await utf8.decoder.bind(response).join();
      throw _parseError(response.statusCode, text);
    }
    final total = _parseContentRangeTotal(response.headers.value(HttpHeaders.contentRangeHeader)) ??
        response.contentLength;
    return DownloadResponse(
      offset: offset,
      total: total,
      stream: response,
    );
  }

  /// 上传单个分片。末片返回最终路径（可能因自动重命名与请求路径不同）。
  Future<UploadChunkResult> uploadChunk(
    String path, {
    required int offset,
    required List<int> data,
    required bool isFinal,
  }) async {
    final encoded = base64Url.encode(utf8.encode(path));
    final uri = Uri.parse(
        '$baseUrl/api/files/upload?path=$encoded&offset=$offset&final=$isFinal');
    final request = await _http.postUrl(uri).timeout(Constants.connectTimeout);
    request.headers.set(_headerFingerprint, _fingerprint);
    request.headers.contentType = ContentType('application', 'octet-stream');
    request.contentLength = data.length;
    request.add(data);
    final response = await request.close().timeout(Constants.connectTimeout);
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw _parseError(response.statusCode, text);
    }
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) throw const FormatException();
      final ok = json['ok'] == true;
      if (!ok) throw const FormatException();
      if (isFinal) {
        return UploadChunkResult(path: json['path'] as String? ?? path);
      }
      return UploadChunkResult(
        offset: (json['offset'] as num?)?.toInt() ?? 0,
      );
    } on Object {
      throw const ApiException(ApiErrorCode.badRequest, 'malformed response');
    }
  }

  /// 查询目标文件已上传进度（续传起点）。
  Future<int> uploadStatus(String path) async {
    final encoded = base64Url.encode(utf8.encode(path));
    final uri = Uri.parse('$baseUrl/api/files/upload/status?path=$encoded');
    final request = await _http.getUrl(uri).timeout(Constants.connectTimeout);
    request.headers.set(_headerFingerprint, _fingerprint);
    final response = await request.close().timeout(Constants.connectTimeout);
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw _parseError(response.statusCode, text);
    }
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) throw const FormatException();
      return (json['offset'] as num?)?.toInt() ?? 0;
    } on Object {
      throw const ApiException(ApiErrorCode.badRequest, 'malformed response');
    }
  }

  /// 取消上传：服务端删除进行中的 .sm-part 分片。
  Future<void> cancelUpload(String path) async {
    final encoded = base64Url.encode(utf8.encode(path));
    final uri = Uri.parse('$baseUrl/api/files/upload?path=$encoded');
    final request = await _http.deleteUrl(uri).timeout(Constants.connectTimeout);
    request.headers.set(_headerFingerprint, _fingerprint);
    final response = await request.close().timeout(Constants.connectTimeout);
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw _parseError(response.statusCode, text);
    }
  }

  /// 移动/重命名（目标已存在时服务端自动重命名），返回实际路径。
  Future<String> move(String from, String to) async {
    final uri = Uri.parse('$baseUrl/api/files/move');
    final request = await _http.postUrl(uri).timeout(Constants.connectTimeout);
    request.headers.set(_headerFingerprint, _fingerprint);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'from': from, 'to': to}));
    final response = await request.close().timeout(Constants.connectTimeout);
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw _parseError(response.statusCode, text);
    }
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) throw const FormatException();
      return json['path'] as String? ?? to;
    } on Object {
      throw const ApiException(ApiErrorCode.badRequest, 'malformed response');
    }
  }

  /// 复制（文件或目录递归；目标已存在时服务端自动重命名），返回实际路径。
  Future<String> copy(String from, String to) async {
    final uri = Uri.parse('$baseUrl/api/files/copy');
    final request = await _http.postUrl(uri).timeout(Constants.connectTimeout);
    request.headers.set(_headerFingerprint, _fingerprint);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'from': from, 'to': to}));
    final response = await request.close().timeout(Constants.connectTimeout);
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw _parseError(response.statusCode, text);
    }
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) throw const FormatException();
      return json['path'] as String? ?? to;
    } on Object {
      throw const ApiException(ApiErrorCode.badRequest, 'malformed response');
    }
  }

  /// 删除（目录需 recursive=true）。
  Future<void> delete(String path, {bool recursive = true}) async {
    final encoded = base64Url.encode(utf8.encode(path));
    final uri = Uri.parse(
        '$baseUrl/api/files/delete?path=$encoded&recursive=$recursive');
    final request = await _http.deleteUrl(uri).timeout(Constants.connectTimeout);
    request.headers.set(_headerFingerprint, _fingerprint);
    final response = await request.close().timeout(Constants.connectTimeout);
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw _parseError(response.statusCode, text);
    }
  }

  /// 新建目录；已存在抛 CONFLICT，返回实际路径。
  Future<String> mkdir(String path) async {
    final uri = Uri.parse('$baseUrl/api/files/mkdir');
    final request = await _http.postUrl(uri).timeout(Constants.connectTimeout);
    request.headers.set(_headerFingerprint, _fingerprint);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'path': path}));
    final response = await request.close().timeout(Constants.connectTimeout);
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw _parseError(response.statusCode, text);
    }
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) throw const FormatException();
      return json['path'] as String? ?? path;
    } on Object {
      throw const ApiException(ApiErrorCode.badRequest, 'malformed response');
    }
  }

  /// 读取远端文本文件内容（UTF-8；非文本文件抛 API 错误）。
  Future<String> readContent(String path) async {
    final encoded = base64Url.encode(utf8.encode(path));
    final uri = Uri.parse('$baseUrl/api/files/content?path=$encoded');
    final request = await _http.getUrl(uri).timeout(Constants.connectTimeout);
    request.headers.set(_headerFingerprint, _fingerprint);
    final response = await request.close().timeout(Constants.connectTimeout);
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw _parseError(response.statusCode, text);
    }
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) throw const FormatException();
      final content = json['content'];
      if (content is! String) throw const FormatException();
      return content;
    } on Object {
      throw const ApiException(ApiErrorCode.badRequest, 'malformed response');
    }
  }

  /// 覆写远端文本文件内容（UTF-8）。
  Future<void> writeContent(String path, String content) async {
    final uri = Uri.parse('$baseUrl/api/files/content');
    final request = await _http.putUrl(uri).timeout(Constants.connectTimeout);
    request.headers.set(_headerFingerprint, _fingerprint);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'path': path, 'content': content}));
    final response = await request.close().timeout(Constants.connectTimeout);
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw _parseError(response.statusCode, text);
    }
  }

  /// 压缩远端文件/文件夹。格式由 archive 扩展名决定（.zip / .tar.gz），
  /// 返回实际压缩包路径。
  Future<String> compress(String source, String archive) async {
    final json = await _postJson('/api/files/compress', {
      'source': source,
      'archive': archive,
    });
    return json['path'] as String? ?? archive;
  }

  /// 解压远端压缩包（zip/tar/tar.gz/tgz/tar.bz2/tbz2/tbz/tar.xz/txz/gz/bz2/xz），
  /// 返回实际解压目录或文件路径。
  Future<String> extract(String archive, String target) async {
    final json = await _postJson('/api/files/extract', {
      'archive': archive,
      'target': target,
    });
    return json['path'] as String? ?? target;
  }

  Future<Map<String, dynamic>> _postJson(
    String apiPath,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$baseUrl$apiPath');
    final request = await _http.postUrl(uri).timeout(Constants.connectTimeout);
    request.headers.set(_headerFingerprint, _fingerprint);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close().timeout(Constants.connectTimeout);
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw _parseError(response.statusCode, text);
    }
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) throw const FormatException();
      return json;
    } on Object {
      throw const ApiException(ApiErrorCode.badRequest, 'malformed response');
    }
  }

  int? _parseContentRangeTotal(String? header) {
    if (header == null) return null;
    final match = RegExp(r'/(\d+)$').firstMatch(header);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  Future<DeviceInfo> _parseDeviceInfo(HttpClientResponse response) async {
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode == HttpStatus.ok) {
      try {
        final json = jsonDecode(text);
        if (json is! Map<String, dynamic>) throw const FormatException();
        return DeviceInfo.fromJson(json);
      } on Object {
        throw const ApiException(ApiErrorCode.badRequest, 'malformed response');
      }
    }
    throw _parseError(response.statusCode, text);
  }

  Future<FileList> _parseFileList(HttpClientResponse response) async {
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode == HttpStatus.ok) {
      try {
        final json = jsonDecode(text);
        if (json is! Map<String, dynamic>) throw const FormatException();
        return FileList.fromJson(json);
      } on Object {
        throw const ApiException(ApiErrorCode.badRequest, 'malformed response');
      }
    }
    throw _parseError(response.statusCode, text);
  }

  ApiException _parseError(int status, String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) throw const FormatException();
      final error = json['error'];
      if (error is! Map<String, dynamic>) throw const FormatException();
      return ApiException(
        ApiErrorCode.fromWire(error['code'] as String? ?? ''),
        error['message'] as String? ?? '',
      );
    } on Object {
      return ApiException(ApiErrorCode.badRequest, 'HTTP $status');
    }
  }

  void close() {
    _http.close(force: true);
  }
}

/// 下载响应：总大小 + 起始偏移 + 数据流。
class DownloadResponse {
  const DownloadResponse({
    required this.offset,
    required this.total,
    required this.stream,
  });

  final int offset;
  final int total;
  final Stream<List<int>> stream;
}

/// 上传分片结果：末片返回最终路径，非末片返回服务端已写字节数。
class UploadChunkResult {
  const UploadChunkResult({this.offset = 0, this.path});

  final int offset;
  final String? path;
}

const _headerFingerprint = 'X-SyncMate-Fingerprint';
