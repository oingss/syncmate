# clipboard — 剪切板同步（阶段六已实现）

- `ClipboardMessage`：协议 §5.2 消息模型（text/image + sourceFingerprint + 时间戳），
  `tryParse` 防御性解析；`contentHash` 为防回声指纹。
- `ClipboardBackend`：平台剪贴板抽象（read/write/changes/流式变化事件），
  两端各自实现（见 apps `platform/system_clipboard_backend.dart`），核心包零 Flutter 依赖。
- `ClipboardService`：
  - 会话管理：每对设备单连接，fingerprint 较小者主动连接、较大者监听，60s 兜底降级；
    设备离线即断开；断线指数退避重连（1→60s）；心跳 ping/pong 15s/30s 判死。
  - 入站连接经 server 的 `clipboardEvents` 接入（`ClipboardConnected/Disconnected/MessageReceived`）。
  - 防回声：来源指纹==己方丢弃；内容与 `_lastSentHash`/`_lastReceivedHash` 相同则跳过。
  - `setEnabled` 开关；`state` 流通知 UI（连接数等）。
- 服务端：`GET /api/clipboard/ws` 升级前校验信任头，403 拒绝；自动应答 ping→pong；
  同指纹新连接顶掉旧连接；`stop()` 时全部关闭。
- 已知边界：图片同步——Android 落 Pictures + Toast（平台通道，Kotlin 已写），
  Windows 图片剪贴板写入未实现（TODO FFI）；剪贴板监听为 2s 轮询，后台无效
  （阶段七前台服务）；轮询无法感知纯图片剪贴板变化（仅文本触发转发）。
