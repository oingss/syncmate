# 平台通道契约（Android）

## 通道清单

| 通道 | 方向 | 方法 |
|---|---|---|
| `syncmate/clipboard` | Dart→Kotlin | `saveImageToPictures` |
| `syncmate/service` | Dart→Kotlin | `start` / `stop` |

> 注意：平台目录尚未经 `flutter create` 生成，本契约先行落地。执行
> `flutter create --org org.syncmate .` 时若 MainActivity/AndroidManifest 冲突，
> 以本文件 + 仓库内已有文件为准合并（Manifest 已含明文 HTTP 放行
> `usesCleartextTraffic`，切勿回退，否则 Android 9+ 全接口 400）。
> 生成后需将 `android/app/build.gradle*` 的 `namespace` 与 `applicationId`
> 改为 `org.syncmate.app`（与已有 Kotlin 包一致），并按需调整
> `minSdk`（FFI 无要求，Clipboard 轮询建议 ≥ 21）。

## saveImageToPictures（syncmate/clipboard）

- 参数：`{"bytes": Uint8List}`（PNG 编码字节）
- 行为：Android 10+ 经 MediaStore 写入 `Pictures/SyncMate/syncmate_<ts>.png`（
  无需存储权限）；Android 9- 写入公共 Pictures 目录（需 WRITE_EXTERNAL_STORAGE，
  后续版本评估）。成功后 Toast 提示「图片已保存到 Pictures/SyncMate」。
- 返回：`Boolean`；失败返回 `MethodChannel.Error`（BAD_ARG / 其他）。

背景：Android 系统剪贴板 API 仅支持文本/URI，无法直接写入图片
（协议 §5.4），故收到图片消息时落盘 + 提示，用户可再通过图库/长按复制 URI。

## Windows（未实现，TODO）

- 写入图片剪贴板：dart:ffi 调用 user32 `OpenClipboard/SetClipboardData(CF_DIB)`，
  或评估 flutter engine 对 `image/png` mimetype 的桌面支持（3.10+ 部分平台已支持）。
- 文本读写走 flutter/services，无需通道。

## 剪贴板监听（两端）

- 采用 2s 轮询 `Clipboard.getData(kTextPlain)`，内容变化时发出事件
  （`SystemClipboardBackend`）。无原生监听事件，轮询在应用活跃时有效；
  后台行为见协议 §5.4 与阶段七（前台服务）。

# Windows 系统托盘（阶段七）

- `apps/syncmate_windows/lib/platform/windows_tray.dart`：纯 dart:ffi 实现，
  零插件依赖：
  - `FindWindowW('FLUTTER_RUNNER_WIN32_WINDOW')` 定位主窗口，`SetWindowLongPtrW`
    子类化其 WndProc（`NativeCallable.isolateLocal` 回调 + 原过程指针转发）。
  - `Shell_NotifyIconW(NIM_ADD)` 加托盘图标（占位 IDI_APPLICATION，正式图标随
    打包资源替换）；回调消息 = `WM_USER+1`。
  - 单击恢复窗口（ShowWindow SW_SHOW + SetForegroundWindow）；右键
    `TrackPopupMenu(TPM_RETURNCMD)` 弹「显示主窗口 / 退出」。
  - 拦截 `WM_CLOSE` → `SW_HIDE` 隐藏到托盘，应用与文件服务继续运行。
  - 已知风险（构建时验证）：NOTIFYICONDATAW x64 布局 976 字节（Dart Struct
    自动对齐，已按 C 顺序声明）；32 位系统 `SetWindowLongPtrW` 不存在（当前仅
    x64 目标）；子类化对 Flutter 引擎消息泵的兼容性需真机验证。
- 生命周期：main.dart 启动时 `tray.init`，失败降级为普通窗口退出；托盘菜单
  「退出」先 `discovery.stop()` + `server.stop()` 再 `exit(0)`。
