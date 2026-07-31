/// iOS 存储访问：沙箱内 App 文档目录天然可访问，无需权限申请，
/// 恒为已授予（与 Android 版保持同一接口，页面无需差异）。
class StoragePermission {
  StoragePermission._();

  static Future<bool> isGranted() async => true;

  static Future<bool> request() async => true;
}
