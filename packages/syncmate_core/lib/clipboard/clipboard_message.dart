/// 剪切板同步消息与事件模型（协议 §5）。
library;

import 'dart:convert';

/// 剪切板同步消息（协议 §5.2）。
class ClipboardMessage {
  const ClipboardMessage({
    required this.sourceFingerprint,
    required this.contentType,
    required this.content,
    required this.timestamp,
  });

  final String sourceFingerprint;
  final String contentType; // 'text' | 'image'
  final String content; // 文本原文；图片为 Base64 编码的 PNG 字节
  final int timestamp; // 毫秒时间戳

  String get contentHash => '$contentType:$content';

  Map<String, dynamic> toJson() => {
        'type': 'clipboard_update',
        'sourceFingerprint': sourceFingerprint,
        'contentType': contentType,
        'content': content,
        'timestamp': timestamp,
      };

  /// 解析消息；非 clipboard_update 或字段非法返回 null。
  static ClipboardMessage? tryParse(String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return null;
      if (json['type'] != 'clipboard_update') return null;
      final source = json['sourceFingerprint'];
      final contentType = json['contentType'];
      final content = json['content'];
      final timestamp = json['timestamp'];
      if (source is! String ||
          contentType is! String ||
          content is! String ||
          (contentType != 'text' && contentType != 'image')) {
        return null;
      }
      return ClipboardMessage(
        sourceFingerprint: source,
        contentType: contentType,
        content: content,
        timestamp: timestamp is num ? timestamp.toInt() : 0,
      );
    } on Object {
      return null;
    }
  }
}

/// 入站剪贴板连接（服务端视角）：可向对端回发数据。
class ClipboardConnection {
  ClipboardConnection({required this.fingerprint, required this.send});

  final String fingerprint;
  final void Function(String data) send;
}

/// 服务端剪贴板事件（连接/断开/消息）。
sealed class ClipboardServerEvent {}

class ClipboardConnected extends ClipboardServerEvent {
  ClipboardConnected(this.connection);
  final ClipboardConnection connection;
}

class ClipboardDisconnected extends ClipboardServerEvent {
  ClipboardDisconnected(this.fingerprint);
  final String fingerprint;
}

class ClipboardMessageReceived extends ClipboardServerEvent {
  ClipboardMessageReceived(this.message);
  final ClipboardMessage message;
}
