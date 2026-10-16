import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import '../../domain/models/settings_model.dart';

// ─── Win32 FFI Structs & Bindings ──────────────────────────────────────────

final class _RECT extends ffi.Struct {
  @ffi.Int32()
  external int left;
  @ffi.Int32()
  external int top;
  @ffi.Int32()
  external int right;
  @ffi.Int32()
  external int bottom;
}

final class _MARGINS extends ffi.Struct {
  @ffi.Int32()
  external int cxLeftWidth;
  @ffi.Int32()
  external int cxRightWidth;
  @ffi.Int32()
  external int cyTopHeight;
  @ffi.Int32()
  external int cyBottomHeight;
}

final class _MONITORINFO extends ffi.Struct {
  @ffi.Uint32()
  external int cbSize;
  external _RECT rcMonitor;
  external _RECT rcWork;
  @ffi.Uint32()
  external int dwFlags;
}

typedef _FindWindowWNative = ffi.IntPtr Function(
    ffi.Pointer<Utf16> lpClassName, ffi.Pointer<Utf16> lpWindowName);
typedef _FindWindowWDart = int Function(
    ffi.Pointer<Utf16> lpClassName, ffi.Pointer<Utf16> lpWindowName);

typedef _GetActiveWindowNative = ffi.IntPtr Function();
typedef _GetActiveWindowDart = int Function();

typedef _ReleaseCaptureNative = ffi.Int32 Function();
typedef _ReleaseCaptureDart = int Function();

typedef _SendMessageWNative = ffi.IntPtr Function(
    ffi.IntPtr hWnd, ffi.Uint32 msg, ffi.IntPtr wParam, ffi.IntPtr lParam);
typedef _SendMessageWDart = int Function(
    int hWnd, int msg, int wParam, int lParam);

typedef _ShowWindowNative = ffi.Int32 Function(
    ffi.IntPtr hWnd, ffi.Int32 nCmdShow);
typedef _ShowWindowDart = int Function(int hWnd, int nCmdShow);

typedef _IsZoomedNative = ffi.Int32 Function(ffi.IntPtr hWnd);
typedef _IsZoomedDart = int Function(int hWnd);

typedef _SetWindowPosNative = ffi.Int32 Function(
  ffi.IntPtr hWnd,
  ffi.IntPtr hWndInsertAfter,
  ffi.Int32 x,
  ffi.Int32 y,
  ffi.Int32 cx,
  ffi.Int32 cy,
  ffi.Uint32 uFlags,
);
typedef _SetWindowPosDart = int Function(
  int hWnd,
  int hWndInsertAfter,
  int x,
  int y,
  int cx,
  int cy,
  int uFlags,
);

typedef _GetWindowRectNative = ffi.Int32 Function(
    ffi.IntPtr hWnd, ffi.Pointer<_RECT> lpRect);
typedef _GetWindowRectDart = int Function(
    int hWnd, ffi.Pointer<_RECT> lpRect);

typedef _MonitorFromWindowNative = ffi.IntPtr Function(
    ffi.IntPtr hwnd, ffi.Uint32 dwFlags);
typedef _MonitorFromWindowDart = int Function(int hwnd, int dwFlags);

typedef _GetMonitorInfoWNative = ffi.Int32 Function(
    ffi.IntPtr hMonitor, ffi.Pointer<_MONITORINFO> lpmi);
typedef _GetMonitorInfoWDart = int Function(
    int hMonitor, ffi.Pointer<_MONITORINFO> lpmi);

typedef _GetDpiForWindowNative = ffi.Uint32 Function(ffi.IntPtr hwnd);
typedef _GetDpiForWindowDart = int Function(int hwnd);

typedef _DwmSetWindowAttributeNative = ffi.Int32 Function(
  ffi.IntPtr hwnd,
  ffi.Uint32 dwAttribute,
  ffi.Pointer<ffi.Void> pvAttribute,
  ffi.Uint32 cbAttribute,
);
typedef _DwmSetWindowAttributeDart = int Function(
  int hwnd,
  int dwAttribute,
  ffi.Pointer<ffi.Void> pvAttribute,
  int cbAttribute,
);

typedef _DwmExtendFrameIntoClientAreaNative = ffi.Int32 Function(
    ffi.IntPtr hWnd, ffi.Pointer<_MARGINS> pMarInset);
typedef _DwmExtendFrameIntoClientAreaDart = int Function(
    int hWnd, ffi.Pointer<_MARGINS> pMarInset);

class Win32Bridge {
  Win32Bridge._() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static final Win32Bridge instance = Win32Bridge._();

  static const MethodChannel _channel = MethodChannel('glassusage/win32');

  final StreamController<String> _eventsController =
      StreamController<String>.broadcast();

  Stream<String> get events => _eventsController.stream;

  int _cachedHwnd = 0;
  _RECT? _savedMainRect;

  static const int _wmNclButtonDown = 0x00A1;
  static const int _htCaption = 2;
  static const int _swHide = 0;
  static const int _swMaximize = 3;
  static const int _swMinimize = 6;
  static const int _swRestore = 9;

  static const int _hwndTopMost = -1;
  static const int _hwndNoTopMost = -2;
  static const int _swpNoSize = 0x0001;
  static const int _swpNoZOrder = 0x0004;
  static const int _swpNoActivate = 0x0010;
  static const int _swpShowWindow = 0x0040;

  static const int _monitorDefaultToNearest = 2;
  static const int _dwmwaUseImmersiveDarkMode = 20;
  static const int _dwmwaWindowCornerPreference = 33;
  static const int _dwmwaSystemBackdropType = 38;

  late final ffi.DynamicLibrary _user32 = ffi.DynamicLibrary.open('user32.dll');
  late final ffi.DynamicLibrary _dwmapi = ffi.DynamicLibrary.open('dwmapi.dll');

  late final _FindWindowWDart _findWindowW = _user32
      .lookupFunction<_FindWindowWNative, _FindWindowWDart>('FindWindowW');
  late final _GetActiveWindowDart _getActiveWindow =
      _user32.lookupFunction<_GetActiveWindowNative, _GetActiveWindowDart>(
          'GetActiveWindow');
  late final _ReleaseCaptureDart _releaseCapture =
      _user32.lookupFunction<_ReleaseCaptureNative, _ReleaseCaptureDart>(
          'ReleaseCapture');
  late final _SendMessageWDart _sendMessageW = _user32
      .lookupFunction<_SendMessageWNative, _SendMessageWDart>('SendMessageW');
  late final _ShowWindowDart _showWindow =
      _user32.lookupFunction<_ShowWindowNative, _ShowWindowDart>('ShowWindow');
  late final _IsZoomedDart _isZoomed =
      _user32.lookupFunction<_IsZoomedNative, _IsZoomedDart>('IsZoomed');
  late final _SetWindowPosDart _setWindowPos = _user32
      .lookupFunction<_SetWindowPosNative, _SetWindowPosDart>('SetWindowPos');
  late final _GetWindowRectDart _getWindowRect =
      _user32.lookupFunction<_GetWindowRectNative, _GetWindowRectDart>(
          'GetWindowRect');
  late final _MonitorFromWindowDart _monitorFromWindow =
      _user32.lookupFunction<_MonitorFromWindowNative, _MonitorFromWindowDart>(
          'MonitorFromWindow');
  late final _GetMonitorInfoWDart _getMonitorInfoW =
      _user32.lookupFunction<_GetMonitorInfoWNative, _GetMonitorInfoWDart>(
          'GetMonitorInfoW');
  late final _GetDpiForWindowDart _getDpiForWindow =
      _user32.lookupFunction<_GetDpiForWindowNative, _GetDpiForWindowDart>(
          'GetDpiForWindow');
  late final _DwmSetWindowAttributeDart _dwmSetWindowAttribute =
      _dwmapi.lookupFunction<_DwmSetWindowAttributeNative,
          _DwmSetWindowAttributeDart>('DwmSetWindowAttribute');
  late final _DwmExtendFrameIntoClientAreaDart _dwmExtendFrameIntoClientArea =
      _dwmapi.lookupFunction<_DwmExtendFrameIntoClientAreaNative,
          _DwmExtendFrameIntoClientAreaDart>('DwmExtendFrameIntoClientArea');

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onWin32Event') {
      final evt = call.arguments as String?;
      if (evt != null && !_eventsController.isClosed) {
        _eventsController.add(evt);
      }
    }
  }

  int _resolveHwnd() {
    if (!Platform.isWindows) return 0;
    if (_cachedHwnd != 0) return _cachedHwnd;
    final active = _getActiveWindow();
    if (active != 0) {
      _cachedHwnd = active;
      return active;
    }
    final classPtr = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    try {
      final found = _findWindowW(classPtr, ffi.nullptr);
      if (found != 0) {
        _cachedHwnd = found;
      }
      return found;
    } finally {
      calloc.free(classPtr);
    }
  }

  double _dpiScale(int hwnd) {
    if (hwnd == 0) return 1.0;
    try {
      final dpi = _getDpiForWindow(hwnd);
      if (dpi > 0) return dpi / 96.0;
    } catch (_) {}
    return 1.0;
  }

  void applyMaterial(WindowMaterial material, {required bool isDark}) {
    if (!Platform.isWindows) return;
    final hwnd = _resolveHwnd();
    if (hwnd == 0) return;

    final attrPtr = calloc<ffi.Uint32>();
    final marginsPtr = calloc<_MARGINS>();
    try {
      attrPtr.value = isDark ? 1 : 0;
      _dwmSetWindowAttribute(
        hwnd,
        _dwmwaUseImmersiveDarkMode,
        attrPtr.cast(),
        ffi.sizeOf<ffi.Uint32>(),
      );

      attrPtr.value = 2; // DWMWCP_ROUND
      _dwmSetWindowAttribute(
        hwnd,
        _dwmwaWindowCornerPreference,
        attrPtr.cast(),
        ffi.sizeOf<ffi.Uint32>(),
      );

      // 2 = Mica, 3 = Acrylic (Transient), 1 = None (Pure CSS Glass)
      final backdropType = switch (material) {
        WindowMaterial.mica => 2,
        WindowMaterial.acrylic => 3,
        WindowMaterial.css => 1,
      };
      attrPtr.value = backdropType;
      _dwmSetWindowAttribute(
        hwnd,
        _dwmwaSystemBackdropType,
        attrPtr.cast(),
        ffi.sizeOf<ffi.Uint32>(),
      );

      marginsPtr.ref
        ..cxLeftWidth = -1
        ..cxRightWidth = -1
        ..cyTopHeight = -1
        ..cyBottomHeight = -1;
      _dwmExtendFrameIntoClientArea(hwnd, marginsPtr);
    } finally {
      calloc.free(attrPtr);
      calloc.free(marginsPtr);
    }
  }

  void startDragging({bool snapAfterDrag = false}) {
    if (!Platform.isWindows) return;
    final hwnd = _resolveHwnd();
    if (hwnd == 0) return;
    _releaseCapture();
    _sendMessageW(hwnd, _wmNclButtonDown, _htCaption, 0);
    if (snapAfterDrag) {
      snapWidgetToEdge();
    }
  }

  void minimize() {
    if (!Platform.isWindows) return;
    final hwnd = _resolveHwnd();
    if (hwnd == 0) return;
    _showWindow(hwnd, _swMinimize);
  }

  void toggleMaximize() {
    if (!Platform.isWindows) return;
    final hwnd = _resolveHwnd();
    if (hwnd == 0) return;
    if (_isZoomed(hwnd) != 0) {
      _showWindow(hwnd, _swRestore);
    } else {
      _showWindow(hwnd, _swMaximize);
    }
  }

  Future<void> hideToTray() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod('hideToTray');
    } catch (_) {
      final hwnd = _resolveHwnd();
      if (hwnd != 0) _showWindow(hwnd, _swHide);
    }
  }

  Future<void> showMainWindow() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod('showMainWindow');
    } catch (_) {
      final hwnd = _resolveHwnd();
      if (hwnd != 0) _showWindow(hwnd, _swRestore);
    }
  }

  Future<void> quitApp() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod('quitApp');
    } catch (_) {
      exit(0);
    }
  }

  void setWidgetMode(
    bool enabled, {
    required bool compact,
    required bool alwaysOnTop,
  }) {
    if (!Platform.isWindows) return;
    final hwnd = _resolveHwnd();
    if (hwnd == 0) return;

    final scale = _dpiScale(hwnd);
    final rectPtr = calloc<_RECT>();
    final monPtr = calloc<_MONITORINFO>();
    try {
      monPtr.ref.cbSize = ffi.sizeOf<_MONITORINFO>();
      final hMon = _monitorFromWindow(hwnd, _monitorDefaultToNearest);
      final hasMonitor = _getMonitorInfoW(hMon, monPtr) != 0;

      if (enabled) {
        if (_savedMainRect == null && _getWindowRect(hwnd, rectPtr) != 0) {
          // Only save if currently large enough to be main window
          final curW = rectPtr.ref.right - rectPtr.ref.left;
          if (curW > (500 * scale).round()) {
            final saved = calloc<_RECT>();
            saved.ref
              ..left = rectPtr.ref.left
              ..top = rectPtr.ref.top
              ..right = rectPtr.ref.right
              ..bottom = rectPtr.ref.bottom;
            _savedMainRect = saved.ref;
          }
        }

        final w = ((compact ? 228 : 300) * scale).round();
        final h = ((compact ? 54 : 208) * scale).round();
        final margin = (16 * scale).round();

        var x = 100;
        var y = 100;
        if (hasMonitor) {
          final work = monPtr.ref.rcWork;
          x = work.right - w - margin;
          y = work.top + margin;
        }
        if (_getWindowRect(hwnd, rectPtr) != 0) {
          final curW = rectPtr.ref.right - rectPtr.ref.left;
          if (curW <= (420 * scale).round()) {
            // Already in widget mode; preserve current top-left
            x = rectPtr.ref.left;
            y = rectPtr.ref.top;
          }
        }

        _setWindowPos(
          hwnd,
          alwaysOnTop ? _hwndTopMost : _hwndNoTopMost,
          x,
          y,
          w,
          h,
          _swpShowWindow,
        );
      } else {
        final w = (1220 * scale).round();
        final h = (800 * scale).round();
        var x = 80;
        var y = 60;
        if (hasMonitor) {
          final work = monPtr.ref.rcWork;
          x = work.left + ((work.right - work.left - w) ~/ 2).clamp(20, 4000);
          y = work.top + ((work.bottom - work.top - h) ~/ 2).clamp(20, 4000);
        }
        _setWindowPos(
          hwnd,
          _hwndNoTopMost,
          x,
          y,
          w,
          h,
          _swpShowWindow,
        );
      }
    } finally {
      calloc.free(rectPtr);
      calloc.free(monPtr);
    }
  }

  /// Snaps MiniCard window to work-area edges when within 24 logical pixels
  /// (leaving a 12 logical pixel margin).
  void snapWidgetToEdge() {
    if (!Platform.isWindows) return;
    final hwnd = _resolveHwnd();
    if (hwnd == 0) return;

    final scale = _dpiScale(hwnd);
    final threshold = (24 * scale).round();
    final margin = (12 * scale).round();

    final rectPtr = calloc<_RECT>();
    final monPtr = calloc<_MONITORINFO>();
    try {
      if (_getWindowRect(hwnd, rectPtr) == 0) return;
      monPtr.ref.cbSize = ffi.sizeOf<_MONITORINFO>();
      final hMon = _monitorFromWindow(hwnd, _monitorDefaultToNearest);
      if (_getMonitorInfoW(hMon, monPtr) == 0) return;

      final rect = rectPtr.ref;
      final work = monPtr.ref.rcWork;
      final w = rect.right - rect.left;
      final h = rect.bottom - rect.top;

      var newX = rect.left;
      var newY = rect.top;
      var snapped = false;

      if ((rect.left - work.left).abs() <= threshold) {
        newX = work.left + margin;
        snapped = true;
      } else if ((work.right - rect.right).abs() <= threshold) {
        newX = work.right - w - margin;
        snapped = true;
      }

      if ((rect.top - work.top).abs() <= threshold) {
        newY = work.top + margin;
        snapped = true;
      } else if ((work.bottom - rect.bottom).abs() <= threshold) {
        newY = work.bottom - h - margin;
        snapped = true;
      }

      if (snapped) {
        _setWindowPos(
          hwnd,
          0,
          newX,
          newY,
          0,
          0,
          _swpNoSize | _swpNoZOrder | _swpNoActivate,
        );
      }
    } finally {
      calloc.free(rectPtr);
      calloc.free(monPtr);
    }
  }

  Future<void> setAutostart(bool enabled) async {
    if (!Platform.isWindows) return;
    const regKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
    const valueName = 'GlassUsage';
    try {
      if (enabled) {
        final exePath = Platform.resolvedExecutable;
        await Process.run(
          'reg.exe',
          ['add', regKey, '/v', valueName, '/t', 'REG_SZ', '/d', '"$exePath"', '/f'],
          runInShell: false,
        );
      } else {
        await Process.run(
          'reg.exe',
          ['delete', regKey, '/v', valueName, '/f'],
          runInShell: false,
        );
      }
    } catch (_) {}
  }

  Future<void> openDataDir(String path) async {
    if (!Platform.isWindows) return;
    try {
      await Process.start('explorer.exe', [path], mode: ProcessStartMode.detached);
    } catch (_) {}
  }
}
