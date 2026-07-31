/// SyncMate 通信核心包。
///
/// 仅供两端 UI 应用消费，禁止反向依赖。
library;

export 'clipboard/clipboard_backend.dart';
export 'clipboard/clipboard_message.dart';
export 'clipboard/clipboard_service.dart';
export 'config/constants.dart';
export 'model/api_error.dart';
export 'model/device_info.dart';
export 'model/device_profile.dart';
export 'model/file_entry.dart';
export 'model/file_list.dart';
export 'model/trusted_device.dart';
export 'security/identity.dart';
export 'security/key_value_store.dart';
export 'security/key_value_trust_store.dart';
export 'security/trust_store.dart';
export 'discovery/announce.dart';
export 'discovery/discovery_service.dart';
export 'fs/fs_adapter.dart';
export 'server/syncmate_server.dart';
export 'client/syncmate_client.dart';
export 'transfer/transfer_service.dart';
export 'util/format.dart';
