import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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
  // 与 macos/Runner/MainFlutterWindow.swift 的处理器配套合并；
  // 小窗固定宿主：仅在进入/退出、卡片落位时跨通道，拖动全程只改 Dart 场景。
  static const MethodChannel _macWindowChannel = MethodChannel(
    'glassusage/desktop_window',
  );
  final StreamController<String> _events = StreamController.broadcast();

  Stream<String> get events => _events.stream;

  final ValueNotifier<Rect?> miniCardBounds = ValueNotifier(null);
  Offset _miniHostOrigin = Offset.zero;
  bool _sendingMiniBounds = false;
  bool _miniBoundsPending = false;
  bool _miniHostRevealPending = false;

  Rect? _mainBounds;
  double _mainBoundsScale = 1;
  Future<void> _windowOperations = Future<void>.value();
  Timer? _snapTimer;
  bool _initialized = false;
  bool _miniMode = false;
  bool _miniFrosted = false;
  WindowMaterial _material = WindowMaterial.acrylic;
  bool _isDark = false;

  /// Platforms whose mini card moves inside a fixed transparent host window
  /// (card placement and texture sampling are submitted in one Flutter scene).
  static bool get _usesFixedHost => Platform.isWindows || Platform.isMacOS;
  bool get _fixedHostMini => _usesFixedHost && _miniMode;
  static MethodChannel get _hostChannel =>
      Platform.isMacOS ? _macWindowChannel : _channel;

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
        center: true,
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        title: 'GlassUsage',
        titleBarStyle: TitleBarStyle.hidden,
      ),
    );
    await _fitInitialWindowToWorkArea();
    await windowManager.show();
    await windowManager.focus();
    _initialized = true;
  }

  Future<void> _fitInitialWindowToWorkArea() async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      if (displays.isEmpty) return;
      final windowScale = _windowScale;
      final currentBounds = await windowManager.getBounds();
      final workArea = _workAreaFor(currentBounds, displays, windowScale);
      final minimum = Size(
        math.min(900, workArea.width),
        math.min(600, workArea.height),
      );
      final size = _clampSize(const Size(1220, 800), workArea.size, minimum);
      final centered = Rect.fromCenter(
        center: workArea.center,
        width: size.width,
        height: size.height,
      );
      await windowManager.setMinimumSize(minimum);
      await windowManager.setBounds(
        _clampPosition(centered.topLeft, size, workArea) & size,
      );
    } catch (_) {
      // Fall back to WindowOptions(center: true) if screen metrics fail.
    }
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
    if (_fixedHostMini) return;
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
    try {
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
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'GlassUsage window management',
          context: ErrorDescription('while applying window material'),
        ),
      );
    }
  }

  Future<void> setMiniFrosted(bool enabled) async {
    // A full-desktop host must remain transparent outside the card.
    if (_fixedHostMini) enabled = false;
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

  /// Applies native mini-window styling and the fixed transparent host.
  ///
  /// Windows and macOS both return the card rectangle inside the host and the
  /// host origin; leaving mini mode restores the main-window styling.
  /// Older runners without the handler are tolerated.
  Future<void> _setNativeMiniMode(bool enabled) async {
    try {
      if (_usesFixedHost) {
        final data = await _hostChannel.invokeMapMethod<String, dynamic>(
          'setMiniMode',
          enabled,
        );
        if (enabled && data != null) {
          _miniHostOrigin = Offset(
            data['hostLeft'] as double,
            data['hostTop'] as double,
          );
          if (Platform.isMacOS) _miniHostRevealPending = true;
          miniCardBounds.value = Rect.fromLTWH(
            data['left'] as double,
            data['top'] as double,
            data['width'] as double,
            data['height'] as double,
          );
        } else if (!enabled) {
          _miniHostRevealPending = false;
          miniCardBounds.value = null;
        }
      }
    } on MissingPluginException {
      // Older runner without the handler.
    }
  }

  /// macOS keeps the new host invisible until the card has been painted at
  /// its host offset; called by MiniCardView once it builds with bounds.
  void revealMiniHostAfterLayout() {
    if (!_miniHostRevealPending) return;
    _miniHostRevealPending = false;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // One more frame so the laid-out scene has reached the compositor.
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
      if (!_miniMode) return;
      try {
        await _macWindowChannel.invokeMethod<void>('showMiniHost');
      } on MissingPluginException {
        // The native side also reveals itself after a timeout.
      }
    });
  }

  void moveMiniCard(Offset position, Size hostSize) {
    final card = miniCardBounds.value;
    if (card == null) return;
    final scale = _windowScale;
    final next = Offset(
      (position.dx.clamp(0.0, math.max(0.0, hostSize.width - card.width)) *
                  scale)
              .round() /
          scale,
      (position.dy.clamp(0.0, math.max(0.0, hostSize.height - card.height)) *
                  scale)
              .round() /
          scale,
    );
    miniCardBounds.value = next & card.size;
    unawaited(_sendMiniBounds());
  }

  Future<void> _sendMiniBounds() async {
    _miniBoundsPending = true;
    if (_sendingMiniBounds) return;
    _sendingMiniBounds = true;
    try {
      while (_miniBoundsPending && _miniMode) {
        _miniBoundsPending = false;
        final card = miniCardBounds.value;
        if (card == null) break;
        final scale = _windowScale;
        await _hostChannel.invokeMethod<void>(
          'setMiniCardBounds',
          Float64List.fromList([
            card.left * scale,
            card.top * scale,
            card.right * scale,
            card.bottom * scale,
          ]),
        );
      }
    } finally {
      _sendingMiniBounds = false;
    }
  }

  Future<void> startDragging() async {
    // Cancel the pending snap before native mouse messages start moving it.
    _snapTimer?.cancel();
    _snapTimer = null;
    if (_fixedHostMini) {
      return; // The card moves within the fixed Flutter surface.
    }
    await windowManager.startDragging();
  }

  Future<void> minimize() => windowManager.minimize();

  /// Window top-left in global top-left logical points (the same space the
  /// desktop_glass texture origin is reported in).
  Future<Offset> windowTopLeft() async => miniCardBounds.value != null
      ? _miniHostOrigin + miniCardBounds.value!.topLeft
      : (await windowManager.getBounds()).topLeft;

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

  Future<void> _queueWindowOperation(Future<void> Function() operation) {
    final next = _windowOperations.then((_) => operation());
    _windowOperations = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<void> showMainWindow() => _queueWindowOperation(() async {
    await windowManager.show();
    await windowManager.focus();
    if (!_events.isClosed) _events.add('window:visible');
  });

  Future<void> setWidgetMode(
    bool enabled, {
    required bool compact,
    required bool alwaysOnTop,
  }) => _queueWindowOperation(
    () => _setWidgetMode(enabled, compact: compact, alwaysOnTop: alwaysOnTop),
  );

  double get _windowScale =>
      Platform.isWindows ? windowManager.getDevicePixelRatio() : 1;

  Future<void> _setWidgetMode(
    bool enabled, {
    required bool compact,
    required bool alwaysOnTop,
  }) async {
    if (!_initialized) return;
    final windowScale = _windowScale;
    final hostBounds = await windowManager.getBounds();
    final currentBounds = _usesFixedHost && miniCardBounds.value != null
        ? miniCardBounds.value!.shift(_miniHostOrigin)
        : hostBounds;
    final displays = await screenRetriever.getAllDisplays();
    if (displays.isEmpty) throw StateError('No displays available');
    final workArea = _workAreaFor(currentBounds, displays, windowScale);

    if (enabled) {
      if (_mainBounds == null && currentBounds.width > 500) {
        _mainBounds = currentBounds;
        _mainBoundsScale = windowScale;
      }
      final size = Size(compact ? 228 : 432, compact ? 54 : 300);
      final currentIsWidget = _miniMode;
      final position = currentIsWidget
          ? currentBounds.topLeft
          : Offset(workArea.right - size.width - 16, workArea.top + 16);
      if (_usesFixedHost && currentIsWidget) {
        miniCardBounds.value =
            _clampPosition(position, size, workArea) - _miniHostOrigin & size;
        await _sendMiniBounds();
        await windowManager.setAlwaysOnTop(alwaysOnTop);
        if (!_events.isClosed) _events.add('widget:ready');
        return;
      }
      await windowManager.setMinimumSize(Size(size.width, size.height));
      await windowManager.setBounds(
        _clampPosition(position, size, workArea) & size,
      );
      await windowManager.setAlwaysOnTop(alwaysOnTop);
      _miniMode = true;
      await _setNativeMiniMode(true);
      await applyMaterial(_material, isDark: _isDark);
      if (!_events.isClosed) _events.add('widget:ready');
      return;
    }

    _miniMode = false;
    if (Platform.isMacOS || Platform.isWindows) {
      // 先暂停并移除实时纹理，再恢复主窗口尺寸与材质，给在途绘制留出缓冲。
      // 此延迟不是无障碍崩溃修复；该修复位于 MiniCardView 的滑块实现。
      if (!_events.isClosed) _events.add('widget:suspend-glass');
      await Future<void>.delayed(
        Platform.isMacOS ? const Duration(milliseconds: 120) : Duration.zero,
      );
    }
    await _setNativeMiniMode(false);
    await applyMaterial(_material, isDark: _isDark);

    final desiredBounds = _mainBounds != null
        ? Rect.fromLTWH(
            _mainBounds!.left * _mainBoundsScale / windowScale,
            _mainBounds!.top * _mainBoundsScale / windowScale,
            _mainBounds!.width,
            _mainBounds!.height,
          )
        : Rect.fromCenter(center: workArea.center, width: 1220, height: 800);
    final minimum = Size(
      math.min(900, workArea.width),
      math.min(600, workArea.height),
    );
    final size = _clampSize(desiredBounds.size, workArea.size, minimum);
    await windowManager.setMinimumSize(minimum);
    await windowManager.setBounds(
      _clampPosition(desiredBounds.topLeft, size, workArea) & size,
    );
    await windowManager.setAlwaysOnTop(false);
    _mainBounds = null;
  }

  Future<void> snapWidgetToEdge() => _queueWindowOperation(_snapWidgetToEdge);

  Future<void> _snapWidgetToEdge() async {
    if (!_initialized || !_miniMode) return;
    final windowScale = _windowScale;
    final bounds = _usesFixedHost && miniCardBounds.value != null
        ? miniCardBounds.value!.shift(_miniHostOrigin)
        : await windowManager.getBounds();
    final displays = await screenRetriever.getAllDisplays();
    if (displays.isEmpty) return;
    final area = _workAreaFor(bounds, displays, windowScale);
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
      if (_usesFixedHost && miniCardBounds.value != null) {
        miniCardBounds.value = (Offset(x, y) - _miniHostOrigin) & bounds.size;
        await _sendMiniBounds();
      } else {
        await windowManager.setPosition(Offset(x, y));
      }
    }
  }

  Rect _workAreaFor(Rect bounds, List<Display> displays, double windowScale) {
    Display? selected;
    var greatestOverlap = -1.0;
    for (final display in displays) {
      final area = _displayWorkArea(display, windowScale);
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
    return _displayWorkArea(selected, windowScale);
  }

  Rect _displayWorkArea(Display display, double windowScale) {
    final position = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    final ratio = Platform.isWindows
        ? (display.scaleFactor ?? windowScale) / windowScale
        : 1.0;
    return Rect.fromLTWH(
      position.dx * ratio,
      position.dy * ratio,
      size.width * ratio,
      size.height * ratio,
    );
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
