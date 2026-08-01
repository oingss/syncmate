/// 文件系统适配层：本机存储根探测、目录列出、路径越界防护。
///
/// Windows：枚举所有盘符（SystemDrive + A-Z 探测）。
/// Android：内部存储 `/storage/emulated/0` + `/storage` 下的其他卷。
/// 仅允许访问存储根以内的路径，越界抛 [FsException(invalidPath)]。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../model/file_entry.dart';

enum FsErrorKind { notFound, ioError, invalidPath, conflict, badRequest }

class FsException implements Exception {
  const FsException(this.kind, this.message);

  final FsErrorKind kind;
  final String message;

  @override
  String toString() => 'FsException(${kind.name}): $message';
}

abstract class FileSystemAdapter {
  Future<List<FileEntry>> roots();

  Future<List<FileEntry>> list(String path);

  Future<String> normalizePath(String path);

  Future<int> fileSize(String path);

  /// 流式读取文件。`maxBytes` 限制总产出字节数（Range 请求时避免超出
  /// 声明的 contentLength 导致 dart:io 中断连接）。
  Stream<List<int>> readFile(String path, {required int offset, int? maxBytes});

  Future<int> appendPart(String partPath, List<int> data);

  Future<int> partSize(String partPath);

  Future<String> commitPart(String partPath, String targetPath);

  Future<void> deletePart(String partPath);

  Future<String> uniquePath(String targetPath);

  /// 移动/重命名（跨文件系统时复制+删除兜底），返回实际路径。
  Future<String> move(String from, String to);

  /// 复制（文件或目录递归复制）；目标已存在时自动重命名，返回实际路径。
  Future<String> copy(String from, String to);

  /// 删除；目录必须 recursive=true，否则 [FsException(badRequest)]。
  Future<void> delete(String path, {required bool recursive});

  /// 新建目录；已存在抛 [FsException(conflict)]。
  Future<String> mkdir(String path);

  /// 读取文本文件（UTF-8）；非文本或超过 1MB 抛 [FsException(badRequest)]。
  Future<String> readText(String path);

  /// 以 UTF-8 覆写文本文件。
  Future<void> writeText(String path, String content);

  /// 压缩文件/文件夹（含子目录）。格式由目标扩展名决定：
  /// `.zip`（流式）或 `.tar.gz`；其他扩展名抛 [FsException(badRequest)]。
  /// 目标已存在时自动重命名，返回实际压缩包路径。
  Future<String> compress(String sourcePath, String archivePath);

  /// 解压。格式由扩展名识别：
  /// - 容器格式 `.zip/.tar/.tar.gz/.tgz/.tar.bz2/.tbz2/.tbz/.tar.xz/.txz`：
  ///   解压到 [targetDir]（自动创建，已存在时自动重命名），返回目录路径；
  /// - 单文件格式 `.gz/.bz2/.xz`：解压到 [targetDir]（须已存在），
  ///   返回解压出的文件路径；
  /// 不支持或非法抛 [FsException(badRequest)]。
  Future<String> extract(String archivePath, String targetDir);
}

class LocalFileSystemAdapter implements FileSystemAdapter {
  /// 显式指定存储根（如 iOS 的 App 文档目录）；为空时按平台探测。
  LocalFileSystemAdapter({List<String>? roots}) : _rootsOverride = roots;

  final List<String>? _rootsOverride;
  List<String>? _rootCache;

  @override
  Future<List<FileEntry>> roots() async {
    final paths = <String>[];
    final override = _rootsOverride;
    if (override != null && override.isNotEmpty) {
      for (final root in override) {
        final normalized = p.normalize(root);
        try {
          if (Directory(normalized).existsSync()) paths.add(normalized);
        } on Object {
          // ignore
        }
      }
    } else if (Platform.isWindows) {
      final systemDrive = Platform.environment['SystemDrive'];
      if (systemDrive != null && systemDrive.isNotEmpty) {
        final sysRoot = p.normalize('$systemDrive\\');
        if (Directory(sysRoot).existsSync()) {
          paths.add(sysRoot);
        }
      }
      for (var code = 65; code <= 90; code++) {
        final drive = '${String.fromCharCode(code)}:\\';
        if (paths.contains(drive)) continue;
        try {
          if (Directory(drive).existsSync()) paths.add(drive);
        } on Object {
          // 光驱等不可访问设备，跳过
        }
      }
    } else if (Platform.isAndroid) {
      const primary = '/storage/emulated/0';
      try {
        if (Directory(primary).existsSync()) paths.add(primary);
      } on Object {
        // ignore
      }
      final storage = Directory('/storage');
      try {
        if (storage.existsSync()) {
          for (final entry in storage.listSync()) {
            final path = entry.path;
            if (path == primary || !Directory(path).existsSync()) continue;
            paths.add(path);
          }
        }
      } on Object {
        // ignore
      }
    } else {
      // Linux / macOS 桌面端：优先 $HOME，缺失时退回根目录
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        final homeRoot = p.normalize(home);
        try {
          if (Directory(homeRoot).existsSync()) paths.add(homeRoot);
        } on Object {
          // ignore
        }
      }
      if (paths.isEmpty) {
        try {
          if (Directory('/').existsSync()) paths.add('/');
        } on Object {
          // ignore
        }
      }
    }
    _rootCache = List.of(paths);
    return paths
        .map((path) => FileEntry(name: path, isDir: true, size: 0, modified: 0))
        .toList();
  }

  @override
  Future<String> normalizePath(String path) async {
    final rootPaths =
        _rootCache ?? (await roots()).map((e) => e.name).toList();
    if (rootPaths.isEmpty) {
      throw const FsException(FsErrorKind.invalidPath, 'no storage root');
    }
    final normalized = p.normalize(path);
    final caseInsensitive = Platform.isWindows;
    final separator = Platform.isWindows ? p.separator : '/';
    var resolved = normalized;
    // drive-relative 路径（如 'C:foo' 表示 C 盘当前目录下的 foo）解析到盘根
    if (Platform.isWindows &&
        RegExp(r'^[a-zA-Z]:[^\\/]').hasMatch(normalized)) {
      resolved = '${normalized.substring(0, 2)}\\${normalized.substring(2)}';
    }
    final needle = caseInsensitive ? resolved.toLowerCase() : resolved;
    for (final root in rootPaths) {
      var rootNorm = p.normalize(root);
      // 根目录自带尾部分隔符（如 'D:\'）时去掉，避免拼出双分隔符
      if (rootNorm.length > 1 && rootNorm.endsWith(separator)) {
        rootNorm = rootNorm.substring(0, rootNorm.length - 1);
      }
      final haystack = caseInsensitive ? rootNorm.toLowerCase() : rootNorm;
      if (needle == haystack ||
          needle.startsWith('$haystack$separator')) {
        return resolved;
      }
    }
    throw const FsException(FsErrorKind.invalidPath, 'path outside storage roots');
  }

  @override
  Future<List<FileEntry>> list(String path) async {
    final normalized = await normalizePath(path);
    final dir = Directory(normalized);
    if (!await dir.exists()) {
      throw FsException(FsErrorKind.notFound, 'path not found: $path');
    }
    try {
      final entities = await dir.list(followLinks: false).toList();
      final entries = <FileEntry>[];
      for (final entity in entities) {
        final isDir = entity is Directory;
        var size = 0;
        var modified = 0;
        try {
          final stat = await entity.stat();
          size = isDir ? 0 : stat.size;
          modified = stat.modified.millisecondsSinceEpoch;
        } on Object {
          // stat 失败保留默认值
        }
        entries.add(FileEntry(
          name: p.basename(entity.path),
          isDir: isDir,
          size: size,
          modified: modified,
        ));
      }
      entries.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return entries;
    } on FsException {
      rethrow;
    } on Object catch (e) {
      throw FsException(FsErrorKind.ioError, e.toString());
    }
  }

  @override
  Future<int> fileSize(String path) async {
    final normalized = await normalizePath(path);
    final file = File(normalized);
    if (!await file.exists()) {
      throw FsException(FsErrorKind.notFound, 'path not found: $path');
    }
    try {
      return await file.length();
    } on Object catch (e) {
      throw FsException(FsErrorKind.ioError, e.toString());
    }
  }

  @override
  Stream<List<int>> readFile(String path,
      {required int offset, int? maxBytes}) async* {
    final normalized = await normalizePath(path);
    final file = File(normalized);
    if (!await file.exists()) {
      throw FsException(FsErrorKind.notFound, 'path not found: $path');
    }
    final RandomAccessFile raf;
    try {
      raf = await file.open();
      await raf.setPosition(offset);
    } on Object catch (e) {
      throw FsException(FsErrorKind.ioError, 'open failed: $e');
    }
    try {
      var remaining = maxBytes;
      while (true) {
        final want = remaining == null || remaining > 64 * 1024
            ? 64 * 1024
            : remaining;
        final chunk = await raf.read(want);
        if (chunk.isEmpty) break;
        yield chunk;
        if (remaining != null) {
          remaining -= chunk.length;
          if (remaining <= 0) break;
        }
      }
    } finally {
      await raf.close();
    }
  }

  @override
  Future<int> appendPart(String partPath, List<int> data) async {
    final file = File(partPath);
    try {
      final raf = await file.open(mode: FileMode.append);
      try {
        await raf.writeFrom(data);
      } finally {
        await raf.close();
      }
      return await file.length();
    } on Object catch (e) {
      throw FsException(FsErrorKind.ioError, e.toString());
    }
  }

  @override
  Future<int> partSize(String partPath) async {
    final file = File(partPath);
    try {
      if (!await file.exists()) return 0;
      return await file.length();
    } on Object {
      return 0;
    }
  }

  @override
  Future<String> commitPart(String partPath, String targetPath) async {
    final normalizedTarget = await normalizePath(targetPath);
    final finalPath = await uniquePath(normalizedTarget);
    try {
      await File(partPath).rename(finalPath);
    } on Object catch (e) {
      throw FsException(FsErrorKind.ioError, e.toString());
    }
    return finalPath;
  }

  @override
  Future<void> deletePart(String partPath) async {
    try {
      final file = File(partPath);
      if (await file.exists()) await file.delete();
    } on Object {
      // 清理失败不阻断主流程
    }
  }

  @override
  Future<String> uniquePath(String targetPath) async {
    final normalized = p.normalize(targetPath);
    try {
      final existingType = await FileSystemEntity.type(normalized);
      if (existingType == FileSystemEntityType.notFound) return normalized;
    } on Object {
      return normalized;
    }
    final dir = p.dirname(normalized);
    final base = p.basenameWithoutExtension(normalized);
    final ext = p.extension(normalized);
    for (var i = 1; i < 10000; i++) {
      final candidate = p.join(dir, '$base ($i)$ext');
      try {
        final type = await FileSystemEntity.type(candidate);
        if (type == FileSystemEntityType.notFound) return candidate;
      } on Object {
        return candidate;
      }
    }
    throw FsException(FsErrorKind.ioError, 'cannot find a unique name for $targetPath');
  }

  @override
  Future<String> move(String from, String to) async {
    final src = await normalizePath(from);
    final dstBase = await normalizePath(to);
    final separator = Platform.isWindows ? p.separator : '/';
    if (dstBase == src ||
        dstBase.startsWith('$src$separator')) {
      throw const FsException(FsErrorKind.badRequest, 'cannot move into itself');
    }
    final dst = await uniquePath(dstBase);
    try {
      final srcType = await FileSystemEntity.type(src);
      if (srcType == FileSystemEntityType.directory) {
        await Directory(src).rename(dst);
      } else {
        await File(src).rename(dst);
      }
      return dst;
    } on FsException {
      rethrow;
    } on Object {
      // 跨文件系统（如 Windows 跨盘）：复制+删除兜底
      try {
        await _copyRecursive(src, dst);
        await _deleteRecursive(src);
      } on FsException {
        rethrow;
      } on Object catch (e) {
        throw FsException(FsErrorKind.ioError, e.toString());
      }
      return dst;
    }
  }

  Future<void> _copyRecursive(String src, String dst) async {
    final type = await FileSystemEntity.type(src);
    if (type == FileSystemEntityType.directory) {
      await Directory(dst).create(recursive: true);
      await for (final entity in Directory(src).list(followLinks: false)) {
        await _copyRecursive(entity.path, p.join(dst, p.basename(entity.path)));
      }
    } else {
      await File(src).copy(dst);
    }
  }

  @override
  Future<String> copy(String from, String to) async {
    final src = await normalizePath(from);
    final dstBase = await normalizePath(to);
    final type = await FileSystemEntity.type(src);
    if (type == FileSystemEntityType.notFound) {
      throw FsException(FsErrorKind.notFound, 'path not found: $from');
    }
    final separator = Platform.isWindows ? p.separator : '/';
    if (dstBase.startsWith('$src$separator')) {
      throw const FsException(FsErrorKind.badRequest, 'cannot copy into itself');
    }
    final dst = await uniquePath(dstBase);
    try {
      await _copyRecursive(src, dst);
    } on FsException {
      rethrow;
    } on Object catch (e) {
      throw FsException(FsErrorKind.ioError, e.toString());
    }
    return dst;
  }

  Future<void> _deleteRecursive(String path) async {
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.directory) {
      await for (final entity in Directory(path).list(followLinks: false)) {
        await _deleteRecursive(entity.path);
      }
      await Directory(path).delete();
    } else {
      await File(path).delete();
    }
  }

  @override
  Future<void> delete(String path, {required bool recursive}) async {
    final normalized = await normalizePath(path);
    final type = await FileSystemEntity.type(normalized);
    if (type == FileSystemEntityType.notFound) {
      throw FsException(FsErrorKind.notFound, 'path not found: $path');
    }
    if (type == FileSystemEntityType.directory && !recursive) {
      throw const FsException(FsErrorKind.badRequest, 'directory delete requires recursive=true');
    }
    try {
      await _deleteRecursive(normalized);
    } on Object catch (e) {
      throw FsException(FsErrorKind.ioError, e.toString());
    }
  }

  @override
  Future<String> mkdir(String path) async {
    final normalized = await normalizePath(path);
    final type = await FileSystemEntity.type(normalized);
    if (type != FileSystemEntityType.notFound) {
      throw const FsException(FsErrorKind.conflict, 'path already exists');
    }
    try {
      await Directory(normalized).create();
    } on Object catch (e) {
      throw FsException(FsErrorKind.ioError, e.toString());
    }
    return normalized;
  }

  @override
  Future<String> readText(String path) async {
    final normalized = await normalizePath(path);
    final file = File(normalized);
    if (!await file.exists()) {
      throw FsException(FsErrorKind.notFound, 'path not found: $path');
    }
    try {
      final length = await file.length();
      if (length > 1024 * 1024) {
        throw const FsException(FsErrorKind.badRequest, 'file too large to edit');
      }
      final bytes = await file.readAsBytes();
      try {
        return utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        throw const FsException(FsErrorKind.badRequest, 'not a utf-8 text file');
      }
    } on FsException {
      rethrow;
    } on Object catch (e) {
      throw FsException(FsErrorKind.ioError, e.toString());
    }
  }

  @override
  Future<void> writeText(String path, String content) async {
    final normalized = await normalizePath(path);
    try {
      await File(normalized).writeAsString(content, flush: true);
    } on Object catch (e) {
      throw FsException(FsErrorKind.ioError, e.toString());
    }
  }

  @override
  Future<String> compress(String sourcePath, String archivePath) async {
    final src = await normalizePath(sourcePath);
    final dst = await uniquePath(await normalizePath(archivePath));
    final lower = dst.toLowerCase();
    final type = await FileSystemEntity.type(src);
    if (type == FileSystemEntityType.notFound) {
      throw FsException(FsErrorKind.notFound, 'path not found: $sourcePath');
    }
    if (!lower.endsWith('.zip') && !lower.endsWith('.tar.gz')) {
      throw const FsException(
          FsErrorKind.badRequest, 'unsupported archive format (zip/tar.gz)');
    }
    try {
      if (lower.endsWith('.zip')) {
        final encoder = ZipFileEncoder();
        encoder.create(dst);
        if (type == FileSystemEntityType.directory) {
          // 不带目录名作根：解压到同名文件夹后内容直接落位（往返一致）
          await encoder.addDirectory(Directory(src), includeDirName: false);
        } else {
          await encoder.addFile(File(src));
        }
        await encoder.close();
      } else {
        final archive = Archive();
        if (type == FileSystemEntityType.directory) {
          await _addDirToArchive(archive, Directory(src), src);
        } else {
          final file = File(src);
          final bytes = await file.readAsBytes();
          archive.addFile(ArchiveFile.bytes(p.basename(src), bytes));
        }
        final tar = TarEncoder().encode(archive);
        final gz = GZipEncoder().encode(tar);
        await File(dst).writeAsBytes(gz, flush: true);
      }
    } on FsException {
      rethrow;
    } on Object catch (e) {
      throw FsException(FsErrorKind.ioError, e.toString());
    }
    return dst;
  }

  Future<void> _addDirToArchive(Archive archive, Directory dir, String root) async {
    await for (final entity in dir.list(followLinks: false)) {
      final relative =
          p.relative(entity.path, from: root).replaceAll('\\', '/');
      if (entity is Directory) {
        await _addDirToArchive(archive, entity, root);
      } else {
        final bytes = await File(entity.path).readAsBytes();
        archive.addFile(ArchiveFile.bytes(relative, bytes));
      }
    }
  }

  /// 压缩层：zip / tar / gzip / bzip2 / xz，由扩展名识别。
  String? _compressionLayer(String lower) {
    if (lower.endsWith('.zip')) return 'zip';
    if (lower.endsWith('.tar')) return 'tar';
    if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) return 'gz';
    if (lower.endsWith('.tar.bz2') ||
        lower.endsWith('.tbz2') ||
        lower.endsWith('.tbz')) {
      return 'bz2';
    }
    if (lower.endsWith('.tar.xz') || lower.endsWith('.txz')) return 'xz';
    if (lower.endsWith('.gz')) return 'gz';
    if (lower.endsWith('.bz2')) return 'bz2';
    if (lower.endsWith('.xz')) return 'xz';
    return null;
  }

  bool _magicOk(String layer, List<int> bytes) {
    switch (layer) {
      case 'zip':
        return bytes.length >= 4 &&
            bytes[0] == 0x50 &&
            bytes[1] == 0x4B &&
            bytes[2] == 0x03 &&
            bytes[3] == 0x04;
      case 'tar':
        // ustar（POSIX/GNU）或旧式 tar（magic 全零）
        if (bytes.length < 262) return false;
        final magic = bytes.sublist(257, 262);
        final isUstar = magic[0] == 0x75 &&
            magic[1] == 0x73 &&
            magic[2] == 0x74 &&
            magic[3] == 0x61 &&
            magic[4] == 0x72;
        return isUstar || magic.every((b) => b == 0);
      case 'gz':
        return bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B;
      case 'bz2':
        return bytes.length >= 3 &&
            bytes[0] == 0x42 &&
            bytes[1] == 0x5A &&
            bytes[2] == 0x68;
      case 'xz':
        return bytes.length >= 6 &&
            bytes[0] == 0xFD &&
            bytes[1] == 0x37 &&
            bytes[2] == 0x7A &&
            bytes[3] == 0x58 &&
            bytes[4] == 0x5A &&
            bytes[5] == 0x00;
      default:
        return false;
    }
  }

  Archive _decodeContainer(String layer, List<int> bytes) {
    try {
      switch (layer) {
        case 'zip':
          return ZipDecoder().decodeBytes(bytes);
        case 'tar':
          return TarDecoder().decodeBytes(bytes);
        case 'gz':
          return TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
        case 'bz2':
          return TarDecoder().decodeBytes(BZip2Decoder().decodeBytes(bytes));
        case 'xz':
          return TarDecoder().decodeBytes(XZDecoder().decodeBytes(bytes));
        default:
          throw const FsException(
              FsErrorKind.badRequest, 'unsupported archive format');
      }
    } on FsException {
      rethrow;
    } on Object {
      throw const FsException(FsErrorKind.badRequest, 'invalid archive');
    }
  }

  List<int> _decompressSingle(String layer, List<int> bytes) {
    try {
      switch (layer) {
        case 'gz':
          return GZipDecoder().decodeBytes(bytes);
        case 'bz2':
          return BZip2Decoder().decodeBytes(bytes);
        case 'xz':
          return XZDecoder().decodeBytes(bytes);
        default:
          throw const FsException(
              FsErrorKind.badRequest, 'unsupported archive format');
      }
    } on FsException {
      rethrow;
    } on Object {
      throw const FsException(FsErrorKind.badRequest, 'invalid archive');
    }
  }

  static const _containerExts = [
    '.zip', '.tar',
    '.tar.gz', '.tgz',
    '.tar.bz2', '.tbz2', '.tbz',
    '.tar.xz', '.txz',
  ];

  @override
  Future<String> extract(String archivePath, String targetDir) async {
    final src = await normalizePath(archivePath);
    final file = File(src);
    if (!await file.exists()) {
      throw FsException(FsErrorKind.notFound, 'path not found: $archivePath');
    }
    final lower = src.toLowerCase();
    final layer = _compressionLayer(lower);
    if (layer == null) {
      throw const FsException(
          FsErrorKind.badRequest, 'unsupported archive format');
    }
    try {
      final bytes = await file.readAsBytes();
      if (!_magicOk(layer, bytes)) {
        throw const FsException(FsErrorKind.badRequest, 'invalid archive');
      }
      final container =
          _containerExts.any((ext) => lower.endsWith(ext));
      if (container) {
        final base = await uniquePath(await normalizePath(targetDir));
        final archive = _decodeContainer(layer, bytes);
        if (archive.files.isEmpty) {
          throw const FsException(FsErrorKind.badRequest, 'empty archive');
        }
        await Directory(base).create(recursive: true);
        final separator = Platform.isWindows ? p.separator : '/';
        for (final entry in archive.files) {
          if (!entry.isFile) continue;
          final target = p.normalize(p.join(base, entry.name));
          // 防 zip-slip：条目路径必须落在目标目录内
          if (!target.startsWith('$base$separator')) continue;
          final out = File(target);
          await out.create(recursive: true);
          await out.writeAsBytes(entry.content);
        }
        return base;
      }
      // 单文件格式：解压到已有目录，文件名去掉压缩扩展名
      final dir = await normalizePath(targetDir);
      final outName = p.basenameWithoutExtension(src);
      final dst = await uniquePath(p.join(dir, outName));
      final decompressed = _decompressSingle(layer, bytes);
      final out = File(dst);
      await out.create(recursive: true);
      await out.writeAsBytes(decompressed, flush: true);
      return dst;
    } on FsException {
      rethrow;
    } on Object catch (e) {
      throw FsException(FsErrorKind.ioError, e.toString());
    }
  }
}
