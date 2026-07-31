/// 平台剪贴板适配抽象。
///
/// 两端各自实现（基于 flutter/services 轮询与平台通道），核心包不依赖 Flutter。
library;

import 'dart:async';

class ClipboardSnapshot {
  const ClipboardSnapshot({this.text, this.imagePng});

  final String? text;
  final List<int>? imagePng;

  bool get isEmpty => text == null && imagePng == null;

  /// 用于防回声去重的内容指纹；空剪贴板返回 null。
  String? get contentHash {
    if (text != null) return 'text:$text';
    if (imagePng != null) return 'image:${imagePng!.length}:'
            '${_quickHash(imagePng!)}';
    return null;
  }

  static int _quickHash(List<int> bytes) {
    var hash = 0;
    final step = bytes.length > 4096 ? bytes.length ~/ 64 : 1;
    for (var i = 0; i < bytes.length; i += step) {
      hash = (hash * 31 + bytes[i]) & 0x7fffffff;
    }
    return hash;
  }
}

abstract class ClipboardBackend {
  /// 读取当前剪贴板内容。
  Future<ClipboardSnapshot> read();

  /// 写入剪贴板（文本或图片）。
  Future<void> write(ClipboardSnapshot snapshot);

  /// 剪贴板内容变化事件（仅在有内容时发出）。
  Stream<ClipboardSnapshot> get changes;

  void dispose();
}
