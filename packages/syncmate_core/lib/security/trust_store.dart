/// 信任名单存储。持久化实现由各端注入（shared_preferences 等）。
library;

import '../model/trusted_device.dart';

abstract class TrustStore {
  Future<List<TrustedDevice>> load();

  Future<TrustedDevice?> find(String fingerprint);

  Future<void> addOrUpdate(TrustedDevice device);

  Future<void> remove(String fingerprint);
}
