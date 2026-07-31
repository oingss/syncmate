/// 目录条目（对应 docs/schemas/file_list_response.schema.json 的 file_entry）。
library;

class FileEntry {
  const FileEntry({
    required this.name,
    required this.isDir,
    required this.size,
    required this.modified,
  });

  factory FileEntry.fromJson(Map<String, dynamic> json) {
    return FileEntry(
      name: json['name'] as String,
      isDir: json['isDir'] as bool,
      size: (json['size'] as num).toInt(),
      modified: (json['modified'] as num).toInt(),
    );
  }

  final String name;
  final bool isDir;
  final int size;
  final int modified;

  Map<String, dynamic> toJson() => {
        'name': name,
        'isDir': isDir,
        'size': size,
        'modified': modified,
      };
}
