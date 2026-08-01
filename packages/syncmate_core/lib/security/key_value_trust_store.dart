/// 基于 KeyValueStore 的信任名单实现（JSON 数组持久化）。
library;

import 'dart:convert';

import '../model/trusted_device.dart';
import 'key_value_store.dart';
import 'trust_store.dart';

class KeyValueTrustStore implements TrustStore {
  KeyValueTrustStore(this._store);

  static const _key = 'trusted_devices';

  final KeyValueStore _store;
  List<TrustedDevice>? _cache;

  @override
  Future<List<TrustedDevice>> load() async {
    final cached = _cache;
    if (cached != null) return List.of(cached);
    final raw = await _store.getString(_key);
    if (raw == null) {
      _cache = [];
      return [];
    }
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => TrustedDevice.fromJson(e as Map<String, dynamic>))
          .toList();
      _cache = list;
      return List.of(list);
    } on Object {
      _cache = [];
      return [];
    }
  }

  @override
  Future<TrustedDevice?> find(String fingerprint) async {
    final list = await load();
    for (final device in list) {
      if (device.fingerprint == fingerprint) return device;
    }
    return null;
  }

  @override
  Future<void> addOrUpdate(TrustedDevice device) async {
    final list = await load();
    final index = list.indexWhere((d) => d.fingerprint == device.fingerprint);
    if (index >= 0) {
      list[index] = device;
    } else {
      list.add(device);
    }
    await _persist(list);
  }

  @override
  Future<void> remove(String fingerprint) async {
    final list = await load();
    list.removeWhere((d) => d.fingerprint == fingerprint);
    await _persist(list);
  }

  Future<void> _persist(List<TrustedDevice> list) async {
    _cache = list;
    await _store.setString(_key, jsonEncode(list.map((d) => d.toJson()).toList()));
  }
}
