# fs — 文件系统适配层（阶段三/四已实现）

- `FileSystemAdapter` 抽象：`roots()` / `list(path)` / `normalizePath(path)` / `fileSize(path)` / `readFile(path, offset)` / `appendPart` / `partSize` / `commitPart` / `deletePart` / `uniquePath` / `move` / `delete` / `mkdir`。
- `LocalFileSystemAdapter`：
  - Windows：SystemDrive + A-Z 盘符探测（光驱等不可访问盘跳过）。
  - Android：`/storage/emulated/0` + `/storage` 下其他卷。
  - 路径防护：normalize 后必须位于某个存储根之内（Windows 忽略大小写），越界抛 `FsException(invalidPath)`。
  - 目录优先 + 名称排序；文件返回 size/modified（ms）。
  - 传输支撑：64KB 分块流式读（Range 下载）、分片追加写、`.sm-part` 提交（rename + 自动重命名冲突）与清理、唯一文件名生成（`foo (1).ext`）。
  - 写操作（阶段五）：`move`（原生 rename，跨文件系统复制+删除兜底，禁止移入自身）、`delete`（目录必须 recursive）、`mkdir`（已存在抛 conflict）。
- `FsException`（notFound / ioError / invalidPath / conflict / badRequest）由 server 映射为协议错误码。
- 已知边界：盘符热插拔未监听（roots 缓存），阶段八打磨。
