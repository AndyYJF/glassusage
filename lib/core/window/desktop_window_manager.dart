import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../../domain/models/settings_model.dart';

/// Cross-platform window operations backed by window_manager.
///
/// Windows-specific tray, shortcut, autostart and Explorer integration remain
/// in the runner because those features have no equivalent behavior on every
/// desktop platform.
class DesktopWindowManager extends WindowListener {
  DesktopWindowManager._();

  static final DesktopWindowManager instance = DesktopWindowManager._();

  static const MethodChannel _channel = MethodChannel('glassusage/win32');
  static const MethodChannel _windowManagerChannel = MethodChannel(
    'window_manager',
  );
  final StreamController<String> _events = StreamController.broadcast();

  Stream<String> get events => _events.stream;

  Rect? _mainBounds;
  Timer? _snapTimer;
  bool _initialized = false;
  bool _miniMode = false;
  bool _miniFrosted = false;
  WindowMaterial _material = WindowMaterial.acrylic;
  bool _isDark = false;

  Future<void> initialize() async {
    if (_initialized ||
        (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux)) {
      return;
    }
    await windowManager.ensureInitialized();
    await acrylic.Window.initialize();
    _channel.setMethodCallHandler(_handleRunnerEvent);
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1220, 800),
        minimumSize: Size(900, 600),
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        title: 'GlassUsage',
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        await windowManager.show();
      },
    );
    _initialized = true;
  }

  Future<dynamic> _handleRunnerEvent(MethodCall call) async {
    if (call.method == 'onWin32Event') {
      final event = call.arguments as String?;
      if (event != null && !_events.isClosed) _events.add(event);
    }
  }

  @override
  void onWindowClose() {
    unawaited(hideToTray());
  }

  @override
  void onWindowMinimize() {
    if (!_events.isClosed) _events.add('window:hidden');
  }

  @override
  void onWindowRestore() {
    if (!_events.isClosed) _events.add('window:visible');
  }

  @override
  void onWindowMoved() {
    if (!_events.isClosed) _events.add('window:moved');
    _snapTimer?.cancel();
    if (_events.isClosed) return;
    _snapTimer = Timer(const Duration(milliseconds: 220), () {
      unawaited(snapWidgetToEdge());
    });
  }

  Future<void> applyMaterial(
    WindowMaterial material, {
    required bool isDark,
  }) async {
    _material = material;
    _isDark = isDark;
    if (!_initialized) return;

    final effect = switch (material) {
      WindowMaterial.acrylic =>
        Platform.isWindows
            ? acrylic.WindowEffect.acrylic
            : Platform.isMacOS
            ? acrylic.WindowEffect.sidebar
            : acrylic.WindowEffect.disabled,
      WindowMaterial.mica =>
        Platform.isWindows
            ? acrylic.WindowEffect.mica
            : Platform.isMacOS
            ? acrylic.WindowEffect.underWindowBackground
            : acrylic.WindowEffect.disabled,
      WindowMaterial.css =>
        Platform.isWindows || Platform.isLinux
            ? acrylic.WindowEffect.transparent
            : acrylic.WindowEffect.contentBackground,
    };
    await acrylic.Window.setEffect(
      effect: _miniMode
          ? (_miniFrosted
                ? (Platform.isMacOS
                      ? acrylic.WindowEffect.sidebar
                      : acrylic.WindowEffect.acrylic)
                : acrylic.WindowEffect.transparent)
          : effect,
      color: _miniMode && !_miniFrosted
          ? Colors.transparent
          : isDark
          ? const Color(0xCC171923)
          : const Color(0xCCF4F5F8),
      dark: isDark,
    );
  }

  Future<void> setMiniFrosted(bool enabled) async {
    if (_miniFrosted == enabled) return;
    _miniFrosted = enabled;
    if (!_initialized || !_miniMode) return;
    try {
      await applyMaterial(_material, isDark: _isDark);
    } catch (_) {
      // Some Linux compositors do not provide a system blur. The Dart surface
      // remains readable without claiming to refract desktop content.
    }
  }

  Future<void> startDragging() async {
    // Cancel once before the native move loop; Windows emits a Dart event for
    // every WM_MOVING message, so avoid work in onWindowMove per mouse update.
    _snapTimer?.cancel();
    _snapTimer = null;
    if (Platform.isWindows && _miniMode) {
      // Mini mode cannot be fullscreen; call the plugin method directly to
      // avoid its extra isFullScreen platform-channel round trip.
      await _windowManagerChannel.invokeMethod<void>('startDragging');
      return;
    }
    await windowManager.startDragging();
  }

  Future<void> minimize() => windowManager.minimize();

  Future<void> toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.restore();
    } else {
      await windowManager.maximize();
    }
  }

  Future<void> hideToTray() async {
    if (Platform.isWindows) {
      await windowManager.hide();
    } else {
      // These platforms have no tray integration; retain a way to restore it.
      await windowManager.minimize();
    }
    if (!_events.isClosed) _events.add('window:hidden');
  }

  Future<void> showMainWindow() async {
    await windowManager.show();
    await windowManager.focus();
    if (!_events.isClosed) _events.add('window:visible');
  }

  Future<void> setWidgetMode(
    bool enabled, {
    required bool compact,
    required bool alwaysOnTop,
  }) async {
    if (!_initialized) return;
    final currentBounds = await windowManager.getBounds();
    final displays = await screenRetriever.getAllDisplays();
    if (displays.isEmpty) return;
    final workArea = _workAreaFor(currentBounds, displays);

    if (enabled) {
      if (_mainBounds == null && currentBounds.width > 500) {
        _mainBounds = currentBounds;
      }
      final size = Size(compact ? 228 : 432, compact ? 54 : 300);
      final currentIsWidget = _miniMode;
      final position = currentIsWidget
          ? currentBounds.topLeft
          : Offset(workArea.right - size.width - 16, workArea.top + 16);
      await windowManager.setMinimumSize(Size(size.width, size.height));
      await windowManager.setSize(size);
      await windowManager.setPosition(_clampPosition(position, size, workArea));
      await windowManager.setAlwaysOnTop(alwaysOnTop);
      _miniMode = true;
      if (Platform.isWindows) {
        await _channel.invokeMethod<void>('setMiniMode', true);
      }
      await applyMaterial(_material, isDark: _isDark);
      if (!_events.isClosed) _events.add('widget:ready');
      return;
    }

    _miniMode = false;
    if (Platform.isWindows) {
      await _channel.invokeMethod<void>('setMiniMode', false);
    }
    await applyMaterial(_material, isDark: _isDark);

    final desiredBounds =
        _mainBounds ??
        Rect.fromCenter(center: workArea.center, width: 1220, height: 800);
    final minimum = Size(
      math.min(900, workArea.width),
      math.min(600, workArea.height),
    );
    final size = _clampSize(desiredBounds.size, workArea.size, minimum);
    await windowManager.setMinimumSize(minimum);
    await windowManager.setSize(size);
    await windowManager.setPosition(
      _clampPosition(desiredBounds.topLeft, size, workArea),
    );
    await windowManager.setAlwaysOnTop(false);
    _mainBounds = null;
  }

  Future<void> snapWidgetToEdge() async {
    if (!_initialized || !_miniMode) return;
    final bounds = await windowManager.getBounds();
    final displays = await screenRetriever.getAllDisplays();
    if (displays.isEmpty) return;
    final area = _workAreaFor(bounds, displays);
    const threshold = 24.0;
    const margin = 12.0;
    var x = bounds.left;
    var y = bounds.top;
    if ((bounds.left - area.left).abs() <= threshold) {
      x = area.left + margin;
    } else if ((area.right - bounds.right).abs() <= threshold) {
      x = area.right - bounds.width - margin;
    }
    if ((bounds.top - area.top).abs() <= threshold) {
      y = area.top + margin;
    } else if ((area.bottom - bounds.bottom).abs() <= threshold) {
      y = area.bottom - bounds.height - margin;
    }
    if (x != bounds.left || y != bounds.top) {
      await windowManager.setPosition(Offset(x, y));
    }
  }

  Rect _workAreaFor(Rect bounds, List<Display> displays) {
    Display? selected;
    var greatestOverlap = -1.0;
    for (final display in displays) {
      final area = _displayWorkArea(display);
      final overlapWidth = math.max(
        0.0,
        math.min(bounds.right, area.right) - math.max(bounds.left, area.left),
      );
      final overlapHeight = math.max(
        0.0,
        math.min(bounds.bottom, area.bottom) - math.max(bounds.top, area.top),
      );
      final overlapArea = overlapWidth * overlapHeight;
      if (overlapArea > greatestOverlap) {
        greatestOverlap = overlapArea;
        selected = display;
      }
    }
    selected ??= displays.first;
    return _displayWorkArea(selected);
  }

  Rect _displayWorkArea(Display display) {
    final position = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    return Rect.fromLTWH(position.dx, position.dy, size.width, size.height);
  }

  Size _clampSize(Size requested, Size area, Size minimum) {
    return Size(
      requested.width
          .clamp(math.min(minimum.width, area.width), area.width)
          .toDouble(),
      requested.height
          .clamp(math.min(minimum.height, area.height), area.height)
          .toDouble(),
    );
  }

  Offset _clampPosition(Offset position, Size size, Rect area) {
    return Offset(
      position.dx.clamp(area.left, area.right - size.width).toDouble(),
      position.dy.clamp(area.top, area.bottom - size.height).toDouble(),
    );
  }

  Future<void> setAutostart(bool enabled) async {
    if (!Platform.isWindows) return;
    const regKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
    const valueName = 'GlassUsage';
    try {
      if (enabled) {
        final exePath = Platform.resolvedExecutable;
        await Process.run('reg.exe', [
          'add',
          regKey,
          '/v',
          valueName,
          '/t',
          'REG_SZ',
          '/d',
          '"$exePath"',
          '/f',
        ]);
      } else {
        await Process.run('reg.exe', ['delete', regKey, '/v', valueName, '/f']);
      }
    } catch (_) {}
  }

  Future<void> openDataDir(String path) async {
    if (!Platform.isWindows) return;
    try {
      await Process.start('explorer.exe', [
        path,
      ], mode: ProcessStartMode.detached);
    } catch (_) {}
  }
}
