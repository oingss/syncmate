# server — HTTP 文件服务端（阶段二完成 connect/info，阶段三起逐步补全）

实现 `docs/protocol.md` §3、§4、§5 的服务端角色，`dart:io` HttpServer（明文 HTTP，端口 53320）：

| 路由 | 状态 |
|---|---|
| `POST /api/device/connect`（信任建立，含已信任自动放行、人工确认弹窗事件、60s 超时） | ✅ 阶段二 |
| `GET /api/device/info`（`X-SyncMate-Fingerprint` 头鉴权） | ✅ 阶段二 |
| `GET /api/files/list`（base64url path 参数，空 = 根目录列表；越界/不存在/IO 错误映射错误码） | ✅ 阶段三 |
| `GET /api/files/download`（query offset + Range 头，206 + Content-Range，支持空文件） | ✅ 阶段四 |
| `POST /api/files/upload`（offset 分片 + .sm-part + final 提交；offset 不符 400；空闲 60s 清理） | ✅ 阶段四 |
| `GET /api/files/upload/status`（查询分片进度，续传起点） | ✅ 阶段四 |
| `DELETE /api/files/upload`（取消：清理 .sm-part 与会话） | ✅ 阶段四 |
| `POST /api/files/move`（JSON 体 from/to，自动重命名，留痕） | ✅ 阶段五 |
| `DELETE /api/files/delete`（recursive 参数，留痕） | ✅ 阶段五 |
| `POST /api/files/mkdir`（JSON 体 path，已存在 CONFLICT，留痕） | ✅ 阶段五 |
| `GET /api/clipboard/ws`（WS 升级，信任头鉴权，ping→pong，同指纹去重） | ✅ 阶段六 |

- 剪切板：`clipboardEvents` 广播流（连接/断开/消息）供 `ClipboardService` 消费。

- 审计日志：构造时传 `auditLogPath` 后，远端发起的 move/delete/mkdir 以一行格式追加到该文件（时间 | 操作 | 来源指纹 | 路径）。默认关闭。
- `FsException` 统一经 `_writeFsError` 映射：notFound→404、conflict→409、ioError→500、其余→400。
| `POST /api/files/move`、`DELETE /api/files/delete`、`POST /api/files/mkdir` | 阶段五 |
| `GET /api/clipboard/ws` | 阶段六 |

- `SyncMateServer.connectRequests` 流推送待确认连接请求，UI 调用 `ConnectRequest.accept()/reject()`。
- 路由分发集中在 `_handle`，后续阶段在此追加；路径规范化与越界防护、自动重命名、upload 分片在对应阶段实现。
