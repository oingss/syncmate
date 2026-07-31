# client — HTTP 客户端（阶段二完成 connect/info，阶段四起补全文件操作）

- `SyncMateClient.connect(DeviceProfile)`：发起信任连接，返回对方 `DeviceInfo`（403 REJECTED/TIMEOUT 映射为 `ApiException`）。
- `SyncMateClient.deviceInfo({fingerprint})`：携带 `X-SyncMate-Fingerprint` 头查询。
- `SyncMateClient.listRoots()` / `listFiles(path)`：阶段三，path 用 base64url(utf8) 编码。
- `SyncMateClient.fileSize(path)`：Range bytes=0-0 探测远端文件总大小。
- `SyncMateClient.download(path, {offset})`：阶段四，206 流式下载，返回 `DownloadResponse`（total + stream）。
- `SyncMateClient.uploadChunk` / `uploadStatus` / `cancelUpload`：阶段四分片上传三件套。
- `SyncMateClient.move` / `delete` / `mkdir`：阶段五写操作，解析错误体为 `ApiException`。
- 错误统一解析 `docs/protocol.md` §4.1 错误体 → `ApiException`（code/message）。
