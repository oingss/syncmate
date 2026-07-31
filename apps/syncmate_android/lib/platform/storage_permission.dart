import 'package:flutter/services.dart';

/// Android 存储访问权限助手。
///
/// Android 11+：跳转系统"所有文件访问"设置页（MANAGE_EXTERNAL_STORAGE）。
/// Android 10 及以下：运行时申请读写外部存储权限。
class StoragePermission {
  StoragePermission._();

  static const MethodChannel _channel = MethodChannel('syncmate/storage');

  static Future<bool> isGranted() async {
    try {
      return await _channel.invokeMethod<bool>('isGranted') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 发起授权流程（Android 11+ 会跳转系统设置页，返回时授权可能尚未完成，
  /// 由页面在 resume 时重新检查）。
  static Future<bool> request() async {
    try {
      return await _channel.invokeMethod<bool>('request') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
