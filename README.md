# SyncMate 多端同步助手

局域网多端文件与剪切板同步助手（Windows / Android 双端），设计文档见 `docs/设计文档.md` 摘要，协议见 `docs/protocol.md`。

## 仓库结构（monorepo）

```
syncmate/
├── docs/
│   ├── protocol.md            # 通信协议定义（阶段一产物）
│   └── schemas/               # 协议 JSON Schema（draft-07）
├── packages/
│   └── syncmate_core/         # 纯 Dart 包：协议、发现、HTTP 服务/客户端、证书、剪切板通道
│                              #   不依赖 Flutter，可单元测试
└── apps/
    ├── syncmate_windows/      # Windows 桌面应用（独立 UI：双栏文件管理 + 托盘）
    └── syncmate_android/      # Android 移动应用（独立 UI：触屏双栏 + 前台服务）
```

## 架构决策

- **两套 UI 完全隔离**：Windows 与 Android 各自独立的 Flutter 应用，不共享任何 Widget / 页面 / 平台通道代码，各自适配自己的交互模式（桌面键鼠 + 托盘 vs 触屏 + 前台服务 + 通知）。
- **共享核心**：通信层、协议模型、证书与信任管理、传输逻辑全部收敛在 `packages/syncmate_core`（纯 Dart，不 import Flutter），两端 UI 只消费 core 暴露的服务接口。
- 依赖方向：`apps/*` → `packages/syncmate_core`，禁止反向依赖。
- **明文 HTTP（v1.1）**：局域网可信环境不启用 TLS，加密开销纯属负担；设备身份 = 首启随机生成的 256-bit ID（本地持久化），信任校验靠「人工确认 + 组播上下文」，详见 `docs/protocol.md` §6。

## 开发阶段

见 `docs/protocol.md` 末尾「开发阶段规划」。当前进度：**八阶段全部完成（代码层面）**：阶段八为信任管理补全（设备重命名）、操作日志查看页（服务端留痕 → UI 读取尾部 200 行，1MB 自动轮换）、异常提示细化。**尚未执行**：`flutter create` 落地两端平台工程 + 全量编译验证（见下方构建清单）。

## 构建清单（待 Flutter SDK 环境）

1. 两端分别执行 `flutter create --org org.syncmate .`（目录内），生成 platform 工程。
2. Android：`android/app/build.gradle*` 的 `namespace`/`applicationId` 改为 `org.syncmate.app`（与已有 Kotlin 包一致）；Manifest 已预写（含明文 HTTP 放行，勿回退）；校验 MainActivity/SyncMateService 合并。
3. Windows：重点验证 `windows_tray.dart`（NOTIFYICONDATAW x64 布局、`SetWindowLongPtrW` 子类化与引擎消息泵兼容、`NativeCallable.isolateLocal` 回调线程）。
4. `flutter analyze` + 真机联调：发现-信任-浏览-传输-写操作-剪切板-后台常驻全链路。
5. 已知待验证项汇总：见 `docs/platform_channels.md` 各节「已知风险」。

## 环境说明

本仓库代码手写骨架，尚未通过 `flutter create` 生成平台工程目录（android/、windows/、ios/ 等）。安装 Flutter SDK 后，在对应 app 目录下执行 `flutter create --platforms=android .` / `flutter create --platforms=windows .` 补齐平台工程，再 `flutter pub get` 即可。
