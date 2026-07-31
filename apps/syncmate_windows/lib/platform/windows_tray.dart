import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;

/// Windows 系统托盘图标（纯 dart:ffi 实现，零插件依赖）。
///
/// 通过子类化 Flutter 主窗口（SetWindowLongPtrW GWLP_WNDPROC）接收
/// Shell_NotifyIcon 的回调消息；单击恢复窗口，右键弹出菜单（显示 / 退出）。
///
/// 注意：本文件在无 Flutter SDK 环境下无法编译验证，接入时需复查
/// NOTIFYICONDATAW 布局（x64 = 976 字节）与回调线程模型（主线程消息泵）。
class WindowsTray {
  /// 尝试初始化托盘。非 Windows 或失败时返回 false（调用方降级为普通退出）。
  Future<bool> init({
    required Future<void> Function() onShow,
    required Future<void> Function() onExit,
  }) async {
    if (!Platform.isWindows) return false;
    try {
      _onShow = onShow;
      _onExit = onExit;
      final hwnd = _findMainWindow();
      if (hwnd == 0) return false;
      _hwnd = hwnd;
      _proc = NativeCallable.isolateLocal(_wndProc);      final result = _setWindowLongPtr(
        hwnd,
        _gwlWndProc,
        _proc!.nativeAddress.address,
      );
      _originalProc = result;
      final ok = _addIcon(hwnd);
      if (!ok) {
        _restoreOriginalProc();
        _proc?.close();
        _proc = null;
        return false;
      }
      _installed = true;
      return true;
    } on Object catch (e) {
      print('WindowsTray init failed: $e');
      return false;
    }
  }

  /// 退出前清理：删除托盘图标并还原窗口过程。
  void dispose() {
    if (!_installed) return;
    try {
      if (_hwnd != 0) {
        _removeIcon(_hwnd);
        _restoreOriginalProc();
      }
    } on Object {
      // ignore
    }
    _proc?.close();
    _proc = null;
    _installed = false;
  }

  // ---------------------------------------------------------------------
  // 状态
  // ---------------------------------------------------------------------

  bool _installed = false;
  int _hwnd = 0;
  int _originalProc = 0;
  NativeCallable<IntPtr Function(IntPtr, Uint32, UintPtr, IntPtr)>? _proc;
  Future<void> Function()? _onShow;
  Future<void> Function()? _onExit;

  static const _gwlWndProc = -4;
  static const _wmUser = 0x0400;
  static const _wmClose = 0x0010;
  static const _callbackMessage = _wmUser + 1;
  static const _wmRButtonUp = 0x0205;
  static const _wmLButtonUp = 0x0202;
  static const _swHide = 0;
  static const _nifMessage = 0x1;
  static const _nifIcon = 0x2;
  static const _nifTip = 0x4;
  static const _nifState = 0x8;
  static const _nmSelect = 0x0400; // NIN_SELECT = WM_USER
  static const _idIcon = 1;
  static const _cmdShow = 1;
  static const _cmdExit = 2;
  static const _mfString = 0x0;
  static const _swShow = 5;
  static const _lmemZeroInit = 0x40;
  static const _tpmReturnCmd = 0x0100;
  static const _tpmRightButton = 0x0002;

  IntPtr _wndProc(int hwnd, int message, int wParam, int lParam) {
    if (message == _wmClose) {
      // 关闭按钮 → 隐藏到托盘，应用与文件服务继续运行
      _showWindow(_hwnd, _swHide);
      return 0;
    }
    if (message == _callbackMessage) {
      if (wParam == _idIcon) {
        if (lParam == _wmLButtonUp) {
          unawaited(_restoreWindow());
          return 0;
        }
        if (lParam == _wmRButtonUp) {
          unawaited(_showContextMenu());
          return 0;
        }
      }
      return 0;
    }
    return _callOriginal(hwnd, message, wParam, lParam);
  }

  IntPtr _callOriginal(int hwnd, int message, int wParam, int lParam) {
    if (_originalProc == 0) return IntPtr.fromAddress(0);
    final original = Pointer<NativeFunction<IntPtr Function(
      IntPtr,
      Uint32,
      UintPtr,
      IntPtr,
    )>>.fromAddress(_originalProc);
    return original
        .asFunction<IntPtr Function(int, int, int, int)>()(
      hwnd,
      message,
      wParam,
      lParam,
    );
  }

  Future<void> _restoreWindow() async {
    if (_hwnd == 0) return;
    _showWindow(_hwnd, _swShow);
    _setForegroundWindow(_hwnd);
    await _onShow?.call();
  }

  Future<void> _showContextMenu() async {
    if (_hwnd == 0) return;
    final menu = _createPopupMenu();
    if (menu == 0) return;
    try {
      final showText = _utf16('显示主窗口');
      final exitText = _utf16('退出');
      _appendMenu(menu, _mfString, _cmdShow, showText);
      _appendMenu(menu, _mfString, _cmdExit, exitText);
      final pt = _getCursorPos();
      final command = _trackPopupMenu(
        menu,
        _tpmReturnCmd | _tpmRightButton,
        pt[0],
        pt[1],
        0,
        _hwnd,
        nullptr,
      );
      if (command == _cmdShow) {
        await _restoreWindow();
      } else if (command == _cmdExit) {
        await _exitApp();
      }
      _freeUtf16(showText);
      _freeUtf16(exitText);
    } finally {
      _destroyMenu(menu);
    }
  }

  Future<void> _exitApp() async {
    final onExit = _onExit;
    dispose();
    await onExit?.call();
  }

  // ---------------------------------------------------------------------
  // 原生绑定
  // ---------------------------------------------------------------------

  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final _findWindowW = _user32.lookupFunction<
      IntPtr Function(Pointer<Uint16>, Pointer<Uint16>),
      int Function(Pointer<Uint16>, Pointer<Uint16>)>('FindWindowW');

  static final _setWindowLongPtrW = _user32.lookupFunction<
      IntPtr Function(IntPtr, Int32, IntPtr),
      int Function(int, int, int)>('SetWindowLongPtrW');

  static final _showWindow = _user32.lookupFunction<
      Int32 Function(IntPtr, Int32),
      int Function(int, int)>('ShowWindow');

  static final _setForegroundWindow = _user32.lookupFunction<
      Int32 Function(IntPtr),
      int Function(int)>('SetForegroundWindow');

  static final _shellNotifyIconW = _user32.lookupFunction<
      Int32 Function(IntPtr, Pointer<_NotifyIconData>),
      int Function(int, Pointer<_NotifyIconData>)>('Shell_NotifyIconW');

  static final _loadIconW = _user32.lookupFunction<
      IntPtr Function(IntPtr, IntPtr),
      int Function(int, int)>('LoadIconW');

  static final _createPopupMenu = _user32.lookupFunction<
      IntPtr Function(),
      int Function()>('CreatePopupMenu');

  static final _appendMenuW = _user32.lookupFunction<
      Int32 Function(IntPtr, Uint32, UintPtr, Pointer<Uint16>),
      int Function(int, int, int, Pointer<Uint16>)>('AppendMenuW');

  static final _trackPopupMenu = _user32.lookupFunction<
      Uint32 Function(IntPtr, Uint32, Int32, Int32, Int32, IntPtr, Pointer<IntPtr>),
      int Function(int, int, int, int, int, int, Pointer<IntPtr>)>('TrackPopupMenu');

  static final _destroyMenu = _user32.lookupFunction<
      Int32 Function(IntPtr),
      int Function(int)>('DestroyMenu');

  static final _getCursorPos = _user32.lookupFunction<
      Int32 Function(Pointer<Int32>),
      int Function(Pointer<Int32>)>('GetCursorPos');

  static final _localAlloc = _kernel32.lookupFunction<
      Pointer<Void> Function(Uint32, UintPtr),
      Pointer<Void> Function(int, int)>('LocalAlloc');

  static final _localFree = _kernel32.lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)>('LocalFree');

  int _findMainWindow() {
    final className = _utf16('FLUTTER_RUNNER_WIN32_WINDOW');
    try {
      return _findWindowW(className, nullptr);
    } finally {
      _freeUtf16(className);
    }
  }

  bool _addIcon(int hwnd) {
    final data = _localAlloc(_lmemZeroInit, sizeOf<_NotifyIconData>());
    if (data == nullptr) return false;
    try {
      final nid = data.cast<_NotifyIconData>().ref;
      nid.cbSize = sizeOf<_NotifyIconData>();
      nid.hWnd = hwnd;
      nid.uID = _idIcon;
      nid.uFlags = _nifMessage | _nifIcon | _nifTip;
      nid.uCallbackMessage = _callbackMessage;
      nid.hIcon = _loadIconW(0, 32512); // IDI_APPLICATION
      _writeUtf16Into(nid.szTip, 'SyncMate');
      return _shellNotifyIconW(1, data) != 0; // NIM_ADD
    } finally {
      _localFree(data);
    }
  }

  void _removeIcon(int hwnd) {
    final data = _localAlloc(_lmemZeroInit, sizeOf<_NotifyIconData>());
    if (data == nullptr) return;
    try {
      final nid = data.cast<_NotifyIconData>().ref;
      nid.cbSize = sizeOf<_NotifyIconData>();
      nid.hWnd = hwnd;
      nid.uID = _idIcon;
      _shellNotifyIconW(2, data); // NIM_DELETE
    } finally {
      _localFree(data);
    }
  }

  void _restoreOriginalProc() {
    if (_hwnd == 0 || _originalProc == 0) return;
    _setWindowLongPtr(_hwnd, _gwlWndProc, _originalProc);
    _originalProc = 0;
  }

  int _setWindowLongPtr(int hwnd, int index, int value) =>
      _setWindowLongPtrW(hwnd, index, IntPtr.fromAddress(value)).address;

  List<int> _getCursorPos() {
    final pt = _localAlloc(0, 8);
    try {
      _getCursorPos(pt.cast<Int32>());
      return [pt.cast<Int32>()[0], pt.cast<Int32>()[1]];
    } finally {
      _localFree(pt);
    }
  }

  static Pointer<Uint16> _utf16(String text) {
    final length = text.length + 1;
    final buffer = _localAlloc(_lmemZeroInit, length * 2).cast<Uint16>();
    for (var i = 0; i < text.length; i++) {
      buffer[i] = text.codeUnitAt(i);
    }
    buffer[text.length] = 0;
    return buffer;
  }

  static void _freeUtf16(Pointer<Uint16> buffer) {
    _localFree(buffer.cast<Void>());
  }

  static void _writeUtf16Into(Array<Uint16> target, String text) {
    final length = text.length < target.length ? text.length : target.length;
    for (var i = 0; i < length; i++) {
      target[i] = text.codeUnitAt(i);
    }
    target[length] = 0;
  }
}

final class _NotifyIconData extends Struct {
  @Uint32()
  external int cbSize;

  @IntPtr()
  external int hWnd;

  @Uint32()
  external int uID;

  @Uint32()
  external int uFlags;

  @Uint32()
  external int uCallbackMessage;

  @IntPtr()
  external int hIcon;

  @Array(128)
  external Array<Uint16> szTip;

  @Uint32()
  external int dwState;

  @Uint32()
  external int dwStateMask;

  @Array(256)
  external Array<Uint16> szInfo;

  @Uint32()
  external int uTimeoutOrVersion;

  @Array(64)
  external Array<Uint16> szInfoTitle;

  @Uint32()
  external int dwInfoFlags;

  @Array(16)
  external Array<Uint8> guidItem;

  @IntPtr()
  external int hBalloonIcon;
}
