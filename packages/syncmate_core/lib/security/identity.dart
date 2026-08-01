/// 设备身份 ID：首启随机生成 256-bit（大写 HEX 64 位）并持久化。
library;

import 'dart:math';

import 'key_value_store.dart';

class KeyValueIdentityProvider {
  KeyValueIdentityProvider(this._store);

  static const _key = 'device_identity';

  final KeyValueStore _store;
  String? _cached;

  Future<String> get identity async {
    final cached = _cached;
    if (cached != null) return cached;
    final existing = await _store.getString(_key);
    if (existing != null && existing.length == 64) {
      _cached = existing;
      return existing;
    }
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final id = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    await _store.setString(_key, id);
    _cached = id;
    return id;
  }
}
