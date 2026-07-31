# transfer — 传输任务编排（阶段四已实现）

- `TransferService.copy(device, remotePath, localPath, toRemote)`：单向文件传输任务，事件流（TaskAdded/TaskProgress/TaskFinished）驱动 UI 进度面板。
- `TransferTask`：方向、总大小/已完成/速度（300ms 采样）、状态（running/done/failed/cancelled）、`cancelToken`。
- 上传：1MB 分片 → `uploadStatus` 查续传起点 → 顺序分片 → 末片 `final`；取消时 `cancelUpload` 清理服务端 .sm-part；空文件直接完成。
- 下载：先 `fileSize` 探测总大小 → 本机已有同名文件（>0 字节）续传，已完整直接完成，0 字节视为新文件自动重命名 → Range 流式写入（append）。
- 客户端按设备复用（putIfAbsent），`dispose()` 统一关闭。
- 已知边界：仅单文件传输，目录递归复制留待后续；上传失败需手动重试（可续传）。
