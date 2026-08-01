# discovery — 设备发现（阶段二已实现）

- `docs/protocol.md` §2：UDP 组播 `224.0.0.170:53321` announce 收发。
- 启动即广播，之后每 5 秒一次；按 fingerprint 丢弃自身报文；在线表 30 秒 TTL 过期。
- `DiscoveryService`：
  - `start()` / `stop()` / `announceNow()`
  - `events`（`DiscoveryEvent`：`DeviceDiscovered` / `DeviceUpdated` / `DeviceExpired`）
  - `devices`（当前在线设备快照，含 baseUrl）
- 仅 IPv4；socket 使用 `reuseAddress`，组播 loopback 收自己的包靠 fingerprint 过滤。
- 已知边界：Windows 多网卡时默认接口外发；路由器 AP 隔离会导致发现失败（阶段八提供手动 IP 入口）。
