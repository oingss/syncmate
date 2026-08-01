# security — 身份与信任管理（阶段二已实现）

v1.1 协议变更：不再使用 TLS / 自签证书（局域网明文传输），设备身份改为首启随机生成的 256-bit ID。

- `KeyValueIdentityProvider`：生成并持久化设备身份 ID（大写 HEX 64 位，字段名 `fingerprint`）。
- `KeyValueStore`：轻量 KV 抽象，由各端用 shared_preferences 实现后注入。
- `TrustStore`（抽象）+ `KeyValueTrustStore`：信任名单持久化（JSON 数组），支持查询/增改/删除；撤销信任即从名单删除。
- 信任校验语义：明文下身份无法密码学验证，「人工确认 + 组播上下文」即门槛，见 docs/protocol.md §6。
