# SyncMate 通信协议定义（v1）

版本：v1 · 阶段一产物 · 后续实现以此为准，改动须先改本文档

## 1. 总览

| 通道 | 用途 | 传输 |
|---|---|---|
| UDP 组播 | 设备发现 / 在线广播 | UDP 组播 `224.0.0.170:53321` |
| HTTP REST | 信任建立、文件操作、设备信息 | 每台设备自起 HTTP 服务，端口 `53320`（明文） |
| WS | 剪切板同步长连接 | 与 REST 同端口，路径 `/api/clipboard/ws` |

- 所有设备端常量见 `packages/syncmate_core/lib/config/constants.dart`（以代码为准，此处默认值供参考）。
- 时间戳统一为 Unix 毫秒。
- 路径参数统一使用 `base64url(utf8(path))` 编码，避免 URL 编码与中文路径歧义。
- **明文传输（v1.1 变更）**：局域网可信环境不启用 TLS，加密开销纯属负担。设备身份由「证书指纹」改为「首启随机生成的 256-bit 身份 ID」并在本地持久化，字段名 `fingerprint` 不变。安全边界见 §6。

## 2. 设备发现（UDP 组播）

### 2.1 广播报文（announce）

组播地址 `224.0.0.170`，端口 `53321`，每个 announce 报文 ≤ 512 字节 UTF-8 JSON，单行。

Schema：`schemas/announce.schema.json`

```json
{
  "v": 1,
  "alias": "我的台式机",
  "deviceType": "windows",
  "fingerprint": "3A4B...64位大写HEX",
  "port": 53320,
  "protocol": "https",
  "appVersion": "0.1.0"
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| v | int | 协议版本，当前恒为 1 |
| alias | string | 设备别名，1-64 字符 |
| deviceType | enum | `windows` \| `android` |
| fingerprint | string | 设备身份 ID，大写 HEX，64 位，设备唯一身份 |
| port | int | 本机 HTTP 服务端口 |
| protocol | enum | 当前恒为 `http` |
| appVersion | string | 可选，应用版本号 |

### 2.2 收发规则

- 应用启动后立即广播一次，之后每 5 秒广播一次；停止时尽力再广播一次（无撤销消息，靠超时下线判定）。
- 收到 announce 后，若 fingerprint 等于本机指纹则丢弃。
- 设备在线判定：收到 announce 后 30 秒内未再收到则标记离线（在线状态用 TTL 而非显式下线消息）。
- 组播 socket 设置 `SO_REUSEADDR`；若组播不可达（路由器隔离），UI 端提示并保留手动输入 IP 入口（阶段八再评估）。
- 仅 IPv4。

## 3. 连接与信任建立

### 3.1 流程

```
A(发起方)                          B(接收方)
  |  POST /api/device/connect      |
  |  {alias, deviceType, fingerprint, port, protocol}  |
  |-------------------------------->|  校验字段 → 弹窗「是否信任 A？」
  |                                 |  用户同意 → 持久化 A → 200 {ok:true,...}
  |  (收到 200，校验 fingerprint    |
  |   与发现报文一致)               |
  |  持久化 B ← 完成双向信任          |
  |  不同意 → 403 {error: REJECTED} |
```

- **单向确认、双向生效**：B 同意一次后，A、B 互相加入对方的信任名单，此后无主从之分，所有操作直接放行。
- B 同意后即持久化 A；A 收到响应后校验其 `fingerprint` 与发现报文一致才持久化 B，防止张冠李戴（明文下为弱校验，见 §6）。
- 已信任设备上线：发现到 announce 后自动更新在线状态，无需再次确认；**已信任设备发来的连接请求由服务端自动接受**（不再弹窗）。
- 超时：A 端 60 秒未收到响应视为失败（403 `TIMEOUT`），可重试。

### 3.2 请求（POST /api/device/connect）

Schema：`schemas/connect_request.schema.json`

```json
{
  "alias": "我的台式机",
  "deviceType": "windows",
  "fingerprint": "3A4B...",
  "port": 53320,
  "protocol": "https"
}
```

### 3.3 响应

同意：`200`，体同 `schemas/device_info.schema.json`：

```json
{
  "alias": "对方别名",
  "deviceType": "android",
  "fingerprint": "C8D9...",
  "port": 53320,
  "protocol": "https",
  "appVersion": "0.1.0",
  "osVersion": "Android 14",
  "storageFree": 123456789,
  "storageTotal": 987654321
}
```

拒绝：`403`；未知设备来源：`403`；超时：客户端自行处理。

## 4. 文件操作接口（HTTPS REST）

### 4.1 通用规则

- 路径参数：`path=<base64url(utf8(path))>`。
- 鉴权头：所有文件操作请求（及 `/api/device/info`）必须携带 `X-SyncMate-Fingerprint: <己方身份 ID>`，服务端校验该 ID 在信任名单中，否则 403 `FORBIDDEN`。明文下该头可被伪造，仅作会话归属与防误标用途，真正的信任门槛在 §3 的连接确认（见 §6）。
- 响应体统一：成功为各接口定义的结构；失败为

```json
{"error": {"code": "FORBIDDEN|NOT_FOUND|INVALID_PATH|CONFLICT|IO_ERROR|BAD_REQUEST", "message": "..."}}
```

- 错误码语义：

| code | 说明 |
|---|---|
| FORBIDDEN | 不在信任名单 / 证书校验失败 |
| BAD_REQUEST | 参数缺失或格式错误 |
| NOT_FOUND | 路径不存在 |
| INVALID_PATH | 路径非法（越界、非法字符、根目录等） |
| CONFLICT | 目标已存在且不允许覆盖（当前策略下不应出现，见 §4.7） |
| IO_ERROR | 读写失败 |

- 目录遍历防护：任何 path 必须规范化后仍以允许的根为前缀（Windows 各磁盘根、Android `/storage/emulated/0` 及可选外置 SD），超出即 `INVALID_PATH`。仅暴露文件目录，不暴露系统目录、隐藏文件默认可见（信任场景从简）。

### 4.2 GET /api/files/list

参数：`path`（可空，空为根目录）。

响应 `200`（Schema：`schemas/file_list_response.schema.json`）：

```json
{
  "path": "/storage/emulated/0/Pictures",
  "entries": [
    {"name": "相册", "isDir": true, "size": 0, "modified": 1730000000000},
    {"name": "截图.png", "isDir": false, "size": 204800, "modified": 1730000001000}
  ]
}
```

条目排序：目录在前，名称不区分大小写按 Unicode 排序（服务端统一排序，客户端不再处理）。

### 4.3 GET /api/files/download

参数：`path`，可选 `offset`（默认 0，断点续传用）。

请求头：`Range: bytes=<offset>-`（客户端应携带，服务端以该头为准）。

响应：`200`（offset=0）/ `206`（offset>0），`Content-Type: application/octet-stream`，头部：
- `Content-Length: <剩余字节>`
- `Content-Range: bytes <offset>-(<total>-1)/<total>`（206 时必有，客户端据此取总大小）

文件不存在返回 `404` + error 体；客户端断开连接时服务端停止发送（不视为错误）。

### 4.4 POST /api/files/upload

分片续传设计：

- 参数：`path`（最终目标路径）、`offset`（本次写入的起始偏移，0 起）、`final`（`true`/`false`，最后一片为 `true`）。
- 请求体：原始字节流（`application/octet-stream`），单次分片 ≤ 4MB，不分块编码（multipart 不支持任意 offset 定位）。
- 服务端行为：
  1. 第一片（offset=0）：目标文件存在则检查 `X-SyncMate-Overwrite: true` 头，未携带按 §4.7 自动重命名策略处理（重命名目标，实际路径在响应中返回）。
  2. 写入临时文件 `<目标名>.sm-part`（与目标同目录，防跨盘），顺序追加各分片；分片 session 按「来源设备 + 目标路径」隔离，`offset` 必须等于服务端已写字节数，否则 400 `BAD_REQUEST`。
  3. `final=true` 且写入后总字节数与目标文件预期一致时，重命名临时文件为目标路径（存在同名则再次自动重命名）；否则返回 `IO_ERROR`。
  4. 临时文件在会话空闲超时（60s 无新分片）后清理。
- 分片响应 `200`：
  - 非末片：`{"ok": true, "offset": <已写字节>}`
  - 末片：`{"ok": true, "path": "/实际写入路径"}`
- 断点续传：客户端可随时查询已写进度（见 4.4.1），从该 offset 继续传；服务端重启后按 `.sm-part` 实际大小恢复。

### 4.4.1 GET /api/files/upload/status

参数：`path`（目标路径）。

响应 `200`：`{"ok": true, "offset": N}`——目标已有进行中/遗留的 `.sm-part` 时为已写字节数，否则 0。

### 4.4.2 DELETE /api/files/upload

参数：`path`（目标路径）。取消传输：删除进行中的 `.sm-part` 与会话。

响应 `200`：`{"ok": true}`

### 4.5 POST /api/files/move

Schema：`schemas/file_move_request.schema.json`，体：

```json
{"from": "/绝对路径", "to": "/绝对路径"}
```

- 跨目录移动与重命名同接口；目标已存在同名 → 按 §4.7 自动重命名。
- 服务端使用原生 rename 语义；跨文件系统（Android 内外部存储）由服务端做复制+删除兜底。

响应 `200`：`{"ok": true, "path": "/实际路径"}`

### 4.6 DELETE /api/files/delete

参数：`path`，可选 `recursive`（`true`/`false`，目录删除需为 `true`，否则返回 `BAD_REQUEST`）。

响应 `200`：`{"ok": true}`

删除不可恢复，直接物理删除（不提供回收站语义，信任场景从简；操作留痕见 §5.2）。

### 4.7 POST /api/files/mkdir

Schema：`schemas/file_mkdir_request.schema.json`，体：

```json
{"path": "/绝对路径"}
```

响应 `200`：`{"ok": true, "path": "/绝对路径"}`；已存在 → `CONFLICT`。

### 4.8 同名冲突策略（全局约定）

- 文档决策：**自动重命名**。目标已存在同名文件/目录时，生成 `<原名> (1)<扩展名>`、`(2)`… 直至不冲突，重命名粒度对「扩展名」：`foo.png → foo (1).png`；目录 `bar → bar (1)`。
- 自动重命名只适用于复制/移动/上传的「目标」；新建目录（mkdir）已存在则直接报 `CONFLICT`。
- 上传场景由服务端执行（客户端可能并发），move 由服务端执行，复制由客户端先探测（见 §4.9）。

### 4.9 GET /api/device/info

响应 `200`：同 §3.3 的 device_info（无需信任确认步骤的已有信任设备可随时查询）。

## 5. 剪切板同步（WebSocket）

### 5.1 连接

- 信任建立后，每对设备**只保留一条连接**：fingerprint 较小者主动发起
  `ws://<ip>:<port>/api/clipboard/ws`（携带 `X-SyncMate-Fingerprint` 头），较大者仅监听。
- 服务端放行条件：该头有效且在信任名单，否则 403 关闭；同一来源指纹的新连接顶掉旧连接（重连安全网）。
- 兜底：较小者离线超过 60s 未发起时，较大者主动发起（降级为双向连接，靠内容去重兜住）。
- 断线后指数退避重连（1s/2s/4s…上限 60s），重连不重建信任。
- 心跳：双方每 15 秒发 `{"type":"ping"}`，对端回 `{"type":"pong"}`；发送方 30 秒未收到任何消息判死关闭。

### 5.2 消息

Schema：`schemas/clipboard_message.schema.json`

```json
{
  "type": "clipboard_update",
  "sourceFingerprint": "A1B2...",
  "contentType": "text",
  "content": "剪贴板内容",
  "timestamp": 1730000000
}
```

| 字段 | 说明 |
|---|---|
| sourceFingerprint | 内容来源设备指纹（**防回声关键字段**） |
| contentType | `text` \| `image` |
| content | 文本原文；图片为 Base64 编码的 PNG 字节 |
| timestamp | 毫秒时间戳，接收端用于去重（与本地最近一次同步值比较） |

### 5.3 防回声与去重

- 收到 `sourceFingerprint == 己方指纹` 的消息直接丢弃（不写入本地剪贴板、不转发）。
- 本地剪贴板变化时：若变化内容与上次自己发送的（`_lastSentHash`）或上次收到的（`_lastReceivedHash`）一致则不再发送/不再写入；图片以「长度 + 采样哈希」作指纹。
- 无中继转发（点对点直连），不存在消息扩散问题；多设备场景（3+）下每对信任关系各自维护一条连接。

### 5.4 平台限制（按设计文档 §3.4）

- Android 10+ 后台读取剪贴板受限：应用前台或前台服务活跃时监听；后台时提供「手动推送当前剪贴板」按钮兜底。
- Android 无法直接向剪贴板写入图片（系统 API 仅支持文本/URI）：收到图片消息时保存到 Pictures 目录并以通知形式提示「图片已保存」，用户可再通过长按复制 URI；Windows 端可正常写入图片剪贴板（CF_DIB/CF_HDROP）。

## 6. 安全模型（v1.1：明文传输版）

**明确取舍**：本方案在局域网可信环境放弃传输加密。明文 HTTP 不防窃听、不防篡改、不提供密码学身份认证——任何能接入广播域的设备理论上都能伪造身份、读取明文流量。这是针对「自用 / 小范围可信团队 + LAN」定位的主动简化（TLS 自签证书方案见设计文档原版，本协议 v1.1 起不再启用，后续如需强安全可回退）。

- **门槛前置、内部完全信任**：信任校验只发生在连接建立时；建立后所有文件操作不再逐次确认。
- 身份与鉴权：
  - 设备唯一身份 = 首启随机生成的 256-bit 身份 ID（大写 HEX 64 位），本地持久化，卸载重装即换新身份。
  - 信任名单（fingerprint + 别名 + 类型 + 端口 + 最近连接时间）存本地 KV（shared_preferences，JSON），可查看、重命名、撤销；撤销后对方需重新发起连接。
  - 信任建立依赖「人工确认 + 组播上下文」：只有看到真实 UI 弹窗并确认，才会加入名单；请求中的身份 ID 无法密码学验证，但组播域与人工确认已构成该场景可接受的门槛。
  - 文件操作接口校验 `X-SyncMate-Fingerprint` 头是否在信任名单（弱校验，防误标，不防伪造）。
- 局域网限制：仅监听局域网接口与组播域，不做公网穿透。
- 操作留痕：服务端对远端发起的 delete/move 追加本地日志（时间、来源指纹、操作、路径），见 `server/` 模块配置开关。
- 风险说明：误信任陌生设备 = 对方可读写删全部文件；明文流量可被同一 Wi-Fi 下的恶意设备嗅探/篡改；建议仅在可信家庭/办公网络使用。

## 7. JSON Schema 文件清单（`docs/schemas/`）

| 文件 | 对应 |
|---|---|
| announce.schema.json | §2.1 广播报文 |
| connect_request.schema.json | §3.2 连接请求 |
| device_info.schema.json | §3.3 / §4.9 设备信息 |
| file_list_response.schema.json | §4.2 目录列表 |
| file_move_request.schema.json | §4.5 移动 |
| file_mkdir_request.schema.json | §4.7 新建目录 |
| error_response.schema.json | §4.1 错误体 |
| clipboard_message.schema.json | §5.2 剪切板消息 |

所有 schema 为 JSON Schema draft-07，Dart 侧实现时不引入校验库，仅在编解码层做字段级防御（阶段一以文档为准）。

## 8. 开发阶段规划（来自设计文档，微调）

| 阶段 | 内容 | 产出 |
|---|---|---|
| 一 ✅ | 骨架、协议文档、Schema、目录结构 | 本目录 |
| 二 | 设备发现 + 信任连接（两端 UI：设备列表页 + 连接弹窗） | core: discovery/security/server 初版 ✅ |
| 三 ✅ | 双栏文件浏览（只读） | core: server 列表 + 两端 UI 双栏 |
| 四 ✅ | 文件传输（进度、取消、断点续传） | core: client/transfer |
| 五 ✅ | 写操作（移动/删除/新建） | server 补全 + UI 操作按钮 |
| 六 ✅ | 剪切板同步（文本 + 图片） | core: clipboard + 两端平台通道 |
| 七 ✅ | 后台常驻（Windows 托盘 / Android 前台服务） | 两端 platform/ |
| 八 ✅ | 打磨：信任管理、操作日志、多设备、异常处理 | 两端 UI + server 补全 |
