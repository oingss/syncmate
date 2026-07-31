import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 前台服务控制（保持进程存活，文件服务与剪切板轮询后台运行）。
///
/// 通道契约见 docs/platform_channels.md（MethodChannel 'syncmate/service'）；
/// Windows 无实现，MissingPluginException 直接忽略（由系统托盘承担常驻）。
class ForegroundService {
  static const _channel = MethodChannel('syncmate/service');

  static Future<void> start() async {
    try {
      await _channel.invokeMethod<void>('start');
    } on MissingPluginException {
      // 非 Android 平台
    } on PlatformException catch (e) {
      debugPrint('前台服务启动失败：${e.message}');
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // 非 Android 平台
    } on PlatformException {
      // ignore
    }
  }
}
