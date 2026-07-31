/// 轻量 KV 存储抽象，由各端 UI 应用用 shared_preferences 等实现后注入。
library;

abstract class KeyValueStore {
  Future<String?> getString(String key);

  Future<void> setString(String key, String value);

  Future<void> remove(String key);
}
