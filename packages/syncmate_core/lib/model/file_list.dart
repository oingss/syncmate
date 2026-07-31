/// 目录列表响应（对应 docs/schemas/file_list_response.schema.json）。
library;

import 'file_entry.dart';

class FileList {
  const FileList({required this.path, required this.entries});

  factory FileList.fromJson(Map<String, dynamic> json) {
    return FileList(
      path: json['path'] as String,
      entries: (json['entries'] as List)
          .map((e) => FileEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// 空字符串表示根目录列表。
  final String path;
  final List<FileEntry> entries;

  Map<String, dynamic> toJson() => {
        'path': path,
        'entries': entries.map((e) => e.toJson()).toList(),
      };
}
