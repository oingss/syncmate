import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:syncmate_core/syncmate_core.dart';

/// 基于 flutter/services 轮询的系统剪贴板后端。
///
/// 文本：经系统剪贴板直接读写。
/// 图片：Android 经平台通道存 Pictures + 通知（saveImageToPictures）；
/// Windows 端 Flutter 暂不支持图片剪贴板写入（TODO：dart:ffi CF_DIB）。
class SystemClipboardBackend implements ClipboardBackend {
  SystemClipboardBackend({Duration pollInterval = const Duration(seconds: 2)}) {
    _pollTimer = Timer.periodic(pollInterval, (_) => _poll());
  }

  static const _channel = MethodChannel('syncmate/clipboard');

  final StreamController<ClipboardSnapshot> _changes =
      StreamController<ClipboardSnapshot>.broadcast();
  Timer? _pollTimer;
  String? _lastText;

  @override
  Future<ClipboardSnapshot> read() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _lastText = text;
      return ClipboardSnapshot(text: text);
    }
    return const ClipboardSnapshot();
  }

  @override
  Future<void> write(ClipboardSnapshot snapshot) async {
    if (snapshot.text != null) {
      await Clipboard.setData(ClipboardData(text: snapshot.text!));
      _lastText = snapshot.text;
    } else if (snapshot.imagePng != null) {
      if (Platform.isAndroid) {
        try {
          await _channel.invokeMethod<void>('saveImageToPictures', {
            'bytes': snapshot.imagePng,
          });
        } on MissingPluginException {
          // 平台实现待 flutter create 后接入（见 docs），忽略
        } on PlatformException catch (e) {
          debugPrint('saveImageToPictures failed: ${e.message}');
        }
      }
    }
  }

  @override
  Stream<ClipboardSnapshot> get changes => _changes.stream;

  Future<void> _poll() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text != null && text.isNotEmpty && text != _lastText) {
        _lastText = text;
        _changes.add(ClipboardSnapshot(text: text));
      }
    } on Object {
      // 轮询失败忽略，下次继续
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _changes.close();
  }
}
