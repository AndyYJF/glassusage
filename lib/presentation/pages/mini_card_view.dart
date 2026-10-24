import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/app_format.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/window/desktop_window_manager.dart';
import '../../core/window/desktop_glass_controller.dart';
import '../../domain/models/usage_models.dart';
import '../providers/app_providers.dart';
import '../widgets/charts.dart';
import '../widgets/odometer.dart';

double get _miniCornerRadius =>
    defaultTargetPlatform == TargetPlatform.macOS ? 16.0 : 28.0;

/// 显示用量小窗，并将实时画面的逐帧刷新交给原生外部纹理。
///
/// 审核时需同时查看 desktop_glass 插件和原生窗口拖动实现；
/// 本组件只负责会话、控件和低频统计，不在 Dart 中追踪桌面裁剪位置。
class MiniCardView extends ConsumerStatefulWidget {
  const MiniCardView({super.key});

  @override
  ConsumerState<MiniCardView> createState() => _MiniCardViewState();
}

class _MiniCardViewState extends ConsumerState<MiniCardView>
    with WidgetsBindingObserver {
  final _glass = DesktopGlassController();
  ui.FragmentShader? _shader;
  ui.FragmentShader? _liveShader;
  ui.Image? _scene;
  int? _textureId;
  bool _hasLiveFrame = false;
  double _fps = 0;
  int _lastPresented = 0;
  double _lastElapsed = 0;
  int _renderedFrames = 0;
  int _lastRenderedFrames = 0;
  double _maxRasterMs = 0;
  final List<double> _rasterSamples = [];
  bool _lightBackdrop = false;
  Color get _foreground =>
      _lightBackdrop ? const Color(0xff182235) : Colors.white;
  Color get _secondary => _foreground.withValues(alpha: 0.75);
  Color get _teal =>
      _lightBackdrop ? const Color(0xff096b5d) : const Color(0xffa9f0d0);
  StreamSubscription<String>? _events;
  Timer? _refreshTimer;
  Timer? _statsTimer;
  bool _busy = false;
  bool _refreshPending = false;
  bool _useScene = false;
  bool _glassSuspended = false;
  bool _glassPaused = false;
  bool _readingStats = false;
  Duration? _statsPollInterval;
  double _refraction = 32;
  double _chromatic = 1.2;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(appSettingsProvider);
    _refraction = saved.widgetRefraction.clamp(0.0, 60.0).toDouble();
    _chromatic = saved.widgetChromatic.clamp(0.0, 4.0).toDouble();
    WidgetsBinding.instance.addObserver(this);
    _glass.addListener(_onGlassChanged);
    SchedulerBinding.instance.addTimingsCallback(_recordTimings);
    unawaited(_loadOptics());
    _events = DesktopWindowManager.instance.events.listen((event) {
      if (event == 'window:hidden') _setGlassPaused(true);
      if (event == 'widget:suspend-glass') {
        unawaited(_glass.setPaused(true));
        if (mounted && !_glassSuspended) {
          setState(() => _glassSuspended = true);
        }
      }
      if (event == 'window:visible') {
        _setGlassPaused(false);
        unawaited(_refresh());
      }
      if (event == 'widget:ready') {
        _refreshTimer?.cancel();
        _refreshTimer = Timer(const Duration(milliseconds: 350), () {
          if (!_useScene) unawaited(_refresh());
        });
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _setGlassPaused(true);
    } else if (state == AppLifecycleState.resumed) {
      _setGlassPaused(false);
      unawaited(_refresh());
    }
  }

  void _setGlassPaused(bool paused) {
    if (mounted && _glassPaused != paused) {
      setState(() => _glassPaused = paused);
    }
    unawaited(_glass.setPaused(paused));
  }

  void _onGlassChanged() {
    if (!mounted) return;
    setState(() {
      final nextTexture = _glass.session?.textureId;
      if (_textureId != nextTexture) {
        _hasLiveFrame = false;
        _lastElapsed = 0;
        _lastPresented = 0;
        _lastRenderedFrames = _renderedFrames;
        _rasterSamples.clear();
        if (nextTexture == null) {
          _statsTimer?.cancel();
          _statsPollInterval = null;
        }
      }
      _textureId = nextTexture;
      if (_glass.mode == DesktopGlassMode.frosted) {
        _lightBackdrop = !GlassTheme.of(context).isDark;
      }
    });
    unawaited(
      DesktopWindowManager.instance.setMiniFrosted(
        !_useScene && _glass.mode == DesktopGlassMode.frosted,
      ),
    );
  }

  void _recordTimings(List<ui.FrameTiming> timings) {
    _renderedFrames += timings.length;
    for (final timing in timings) {
      final ms = timing.rasterDuration.inMicroseconds / 1000;
      if (ms > _maxRasterMs) _maxRasterMs = ms;
      if (const bool.fromEnvironment('LIVE_GLASS_METRICS')) {
        _rasterSamples.add(ms);
      }
    }
  }

  Future<void> _loadOptics() async {
    try {
      final program = await ui.FragmentProgram.fromAsset(
        'assets/shaders/liquid_glass.frag',
      );
      if (mounted) {
        setState(() {
          _shader = program.fragmentShader();
          if (ui.ImageFilter.isShaderFilterSupported) {
            _liveShader = program.fragmentShader();
          }
        });
      }
    } catch (error) {
      debugPrint('Mini-window shader unavailable: $error');
    }
    final recorder = ui.PictureRecorder();
    const _MiniScenePainter().paint(Canvas(recorder), const Size(432, 300));
    final picture = recorder.endRecording();
    final scene = await picture.toImage(432, 300);
    picture.dispose();
    if (!mounted) {
      scene.dispose();
      return;
    }
    setState(() => _scene = scene);
    await _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted || _useScene) return;
    if (_busy) {
      _refreshPending = true;
      return;
    }
    setState(() => _busy = true);
    try {
      await _glass.connect(shaderSupported: _liveShader != null);
      if (!mounted || _useScene) return;
      if (_glass.session == null) return;
      // 100ms 仅等待首帧；收到捕获帧后恢复到 1Hz，不用统计定时器驱动画面。
      _setStatsPolling(const Duration(milliseconds: 100));
      await _readStats();
    } catch (error) {
      debugPrint('Mini-window capture error: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
      if (_refreshPending) {
        _refreshPending = false;
        if (mounted && !_useScene) unawaited(_refresh());
      }
    }
  }

  void _setStatsPolling(Duration interval) {
    if (_statsPollInterval == interval && _statsTimer?.isActive == true) {
      return;
    }
    _statsTimer?.cancel();
    _statsPollInterval = interval;
    _statsTimer = Timer.periodic(interval, (_) => _readStats());
  }

  Future<void> _readStats() async {
    if (!mounted || _useScene || _readingStats) return;
    _readingStats = true;
    try {
      final stats = await _glass.refreshStats();
      if (!mounted || stats == null) return;
      _setStatsPolling(
        stats.hasValidFrame
            ? const Duration(seconds: 1)
            : const Duration(milliseconds: 100),
      );
      final elapsed = stats.elapsed;
      final presented = stats.presented;
      final delta = elapsed - _lastElapsed;
      setState(() {
        // frames 是捕获端计数；不能等 presented，纹理显示前还没有取帧回调。
        if (!stats.paused && _glassPaused) _glassPaused = false;
        _hasLiveFrame = stats.hasValidFrame;
        _fps = delta > 0 ? (presented - _lastPresented) / delta : 0;
        final luminance = stats.luminance;
        if (luminance > 0.62) _lightBackdrop = true;
        if (luminance < 0.42) _lightBackdrop = false;
      });
      if (const bool.fromEnvironment('LIVE_GLASS_METRICS')) {
        debugPrint(
          'LIVE_GLASS_METRICS ${jsonEncode({...stats.raw, 'rasterFrames': _renderedFrames, 'rasterFps': delta > 0 ? (_renderedFrames - _lastRenderedFrames) / delta : 0, 'textureFps': _fps, 'maxRasterMs': _maxRasterMs, 'rasterMs': _rasterSamples})}',
        );
      }
      _lastRenderedFrames = _renderedFrames;
      _maxRasterMs = 0;
      _rasterSamples.clear();
      _lastElapsed = elapsed;
      _lastPresented = presented;
    } catch (error) {
      debugPrint('Mini-window capture error: $error');
    } finally {
      _readingStats = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _glass.removeListener(_onGlassChanged);
    _glass.dispose();
    _refreshTimer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_recordTimings);
    _statsTimer?.cancel();
    _events?.cancel();
    _shader?.dispose();
    _liveShader?.dispose();
    _scene?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    if (!_useScene && _glass.mode == DesktopGlassMode.frosted) {
      _lightBackdrop = !g.isDark;
    }
    final i18n = ref.watch(i18nProvider);
    final live = ref.watch(liveRatesProvider);
    final compact = ref.watch(
      appSettingsProvider.select((s) => s.widgetCompact),
    );
    final controller = ref.read(appControllerProvider);

    final useLive =
        !_useScene &&
        !_glassSuspended &&
        !_glassPaused &&
        _hasLiveFrame &&
        _textureId != null &&
        _liveShader != null &&
        _glass.mode == DesktopGlassMode.realtime;
    return ClipRRect(
      borderRadius: BorderRadius.circular(_miniCornerRadius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (useLive)
            _DesktopGlassSurface(
              shader: _liveShader!,
              textureId: _textureId!,
              refraction: _refraction,
              chromatic: _chromatic,
            )
          else if (_useScene)
            CustomPaint(
              painter: _MiniGlassPainter(
                _shader,
                _scene,
                _refraction,
                _chromatic,
              ),
            )
          else
            ColoredBox(color: g.bgCanvas.withValues(alpha: 0.94)),
          if (useLive)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    Color(0x0A000000),
                    Color(0x14000000),
                    Color(0x1F000000),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => _startDragging(),
            child: Container(
              constraints: const BoxConstraints.expand(),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_miniCornerRadius),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.20),
                  width: 0.5,
                ),
              ),
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 12 : 20,
                vertical: compact ? 8 : 12,
              ),
              child: compact
                  ? _buildCompact(context, g, live, controller)
                  : _buildFull(context, g, i18n, live, controller),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompact(
    BuildContext context,
    GlassTheme g,
    LiveRates live,
    AppController controller,
  ) {
    final isActive = live.perSource.any((s) => s.active);
    return Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: isActive ? g.success : g.accentBlue,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${fmtTokens(live.tpm.round())}/m · ${fmtUsd(live.costToday)}',
            style: GlassTheme.tabularStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: _foreground,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: ref.read(i18nProvider).isZh ? '展开小窗' : 'Expand mini window',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          icon: Icon(Icons.unfold_more_rounded, size: 15, color: _secondary),
          onPressed: () => controller.setCompactWidget(false),
        ),
        IconButton(
          tooltip: ref.read(i18nProvider).isZh
              ? '返回主界面'
              : 'Back to main window',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          icon: Icon(Icons.open_in_full_rounded, size: 14, color: _secondary),
          onPressed: () => controller.setWidgetMode(false),
        ),
      ],
    );
  }

  Widget _buildFull(
    BuildContext context,
    GlassTheme g,
    AppI18n i18n,
    LiveRates live,
    AppController controller,
  ) {
    final isActive = live.perSource.any((s) => s.active);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: isActive ? g.success : g.accentBlue,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                'GLASSUSAGE LIVE',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.7,
                  color: _secondary,
                ),
              ),
            ),
            _action(
              Icons.wallpaper_outlined,
              i18n.isZh ? '切换测试背景 / 实时桌面' : 'Test background / live desktop',
              () {
                setState(() => _useScene = !_useScene);
                if (_useScene) {
                  _lightBackdrop = false;
                  _statsTimer?.cancel();
                  _statsTimer = null;
                  _textureId = null;
                  _hasLiveFrame = false;
                  _lastElapsed = 0;
                  _lastPresented = 0;
                  unawaited(_glass.disconnect());
                } else {
                  unawaited(_refresh());
                }
              },
            ),
            _action(
              ref.watch(appSettingsProvider).widgetAlwaysOnTop
                  ? Icons.push_pin_rounded
                  : Icons.push_pin_outlined,
              i18n.isZh ? '置顶' : 'Always on top',
              () => controller.patchSettings({
                'widgetAlwaysOnTop': !ref
                    .read(appSettingsProvider)
                    .widgetAlwaysOnTop,
              }),
            ),
            IconButton(
              tooltip: i18n.isZh ? '紧凑模式' : 'Compact mode',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              icon: Icon(
                Icons.unfold_less_rounded,
                size: 15,
                color: _secondary,
              ),
              onPressed: () => controller.setCompactWidget(true),
            ),
            IconButton(
              tooltip: i18n.isZh ? '返回主界面' : 'Back to main window',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              icon: Icon(
                Icons.open_in_full_rounded,
                size: 14,
                color: _secondary,
              ),
              onPressed: () => controller.setWidgetMode(false),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Odometer(
                  value: live.tpm,
                  color: _foreground,
                  formatter: (v) => fmtTokens(v.round()),
                  fontSize: 22,
                ),
                Text(
                  'Tokens / min',
                  style: TextStyle(fontSize: 10.5, color: _secondary),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Odometer(
                  value: live.rpm,
                  formatter: (v) => v.toStringAsFixed(1),
                  fontSize: 20,
                  color: _teal,
                ),
                Text(
                  'Requests / min',
                  style: TextStyle(fontSize: 10.5, color: _secondary),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Sparkline(
            values: live.spark60,
            color: g.accentBlue,
            height: 44,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${i18n.t('range.today')}: ${fmtTokens(live.tokensToday)}',
              style: GlassTheme.tabularStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: _secondary,
              ),
            ),
            Text(
              fmtUsd(live.costToday),
              style: GlassTheme.tabularStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: _teal,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _slider(
          i18n.isZh ? '折射' : 'Lens',
          _refraction,
          60,
          (value) => setState(() => _refraction = value),
          (value) => controller.patchSettings({'widgetRefraction': value}),
        ),
        _slider(
          i18n.isZh ? '色散' : 'RGB',
          _chromatic,
          4,
          (value) => setState(() => _chromatic = value),
          (value) => controller.patchSettings({'widgetChromatic': value}),
        ),
      ],
    );
  }

  Widget _action(IconData icon, String tooltip, VoidCallback action) =>
      IconButton(
        tooltip: tooltip,
        onPressed: action,
        icon: Icon(icon, size: 15, color: _secondary),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      );

  void _startDragging() {
    unawaited(DesktopWindowManager.instance.startDragging());
  }

  Widget _slider(
    String label,
    double value,
    double max,
    ValueChanged<double> change,
    ValueChanged<double> persist,
  ) => SizedBox(
    height: 28,
    child: Row(
      children: [
        SizedBox(
          width: 32,
          child: Text(label, style: TextStyle(fontSize: 10, color: _secondary)),
        ),
        Expanded(
          // 合并时保留无 OverlayPortal 的滑块：Material Slider 曾产生孤立 AX 节点，
          // 返回主界面时在 AccessibilityBridge 崩溃；此处仍保留滑块语义与交互。
          child: Semantics(
            label: label,
            child: CupertinoSlider(
              value: value,
              min: 0,
              max: max,
              activeColor: _foreground,
              thumbColor: _foreground,
              onChanged: _shader == null ? null : change,
              onChangeEnd: _shader == null ? null : persist,
            ),
          ),
        ),
        SizedBox(
          width: 26,
          child: Text(
            value.toStringAsFixed(1),
            style: TextStyle(fontSize: 10, color: _secondary),
          ),
        ),
      ],
    ),
  );
}

/// Filter the live texture directly, as in the initial Windows implementation.
/// The texture is the filter's child so native frame updates invalidate its
/// output without a Dart ticker or a cached sibling backdrop.
class _DesktopGlassSurface extends StatelessWidget {
  const _DesktopGlassSurface({
    required this.shader,
    required this.textureId,
    required this.refraction,
    required this.chromatic,
  });
  final ui.FragmentShader shader;
  final int textureId;
  final double refraction;
  final double chromatic;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final texture = Texture(
        textureId: textureId,
        filterQuality: FilterQuality.low,
      );
      // 两项都关闭时真正直出桌面纹理，避免“关了效果”仍经过模糊/着色器。
      if (refraction == 0 && chromatic == 0) return texture;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final size = constraints.biggest * dpr;
      final radius = (size.shortestSide / 2)
          .clamp(0.0, _miniCornerRadius * dpr)
          .toDouble();
      // u_size (0..1) and sampler are supplied by ImageFilter.shader. All shape
      // geometry is physical pixels, exactly once, as in the supplied experiment.
      final values = <double>[
        0,
        0,
        size.width,
        size.height,
        radius,
        radius,
        radius,
        radius,
        24 * dpr,
        -refraction * dpr,
        1,
        chromatic,
        1.25,
        0,
        1,
        0.52,
        0.65,
        0.95,
        0, // No blue tint on the live desktop.
        1,
        1,
        1,
        0, // No white surface overlay on the live desktop.
        0,
        0,
        0,
        0,
      ];
      for (var i = 0; i < values.length; i++) {
        shader.setFloat(i + 2, values[i]);
      }
      return ImageFiltered(
        key: ValueKey((refraction, chromatic, size)),
        imageFilter: ui.ImageFilter.shader(shader),
        // Keep the shader input window-sized; blur outsets expose a bright
        // strip along the right and bottom edges of the native material.
        child: texture,
      );
    },
  );
}

// Direct-image rendering is retained only for the explicitly selected test scene.
class _MiniGlassPainter extends CustomPainter {
  const _MiniGlassPainter(
    this.shader,
    this.image,
    this.refraction,
    this.chromatic,
  );
  final ui.FragmentShader? shader;
  final ui.Image? image;
  final double refraction;
  final double chromatic;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (shader != null && image != null) {
      final radius = (size.shortestSide / 2)
          .clamp(0.0, _miniCornerRadius)
          .toDouble();
      final values = <double>[
        size.width,
        size.height,
        0,
        0,
        size.width,
        size.height,
        radius,
        radius,
        radius,
        radius,
        24,
        -refraction,
        1,
        chromatic,
        1.25,
        0,
        1,
        0.52,
        0.65,
        0.95,
        0.06,
        1,
        1,
        1,
        0.13,
        0,
        0,
        0,
        0,
      ];
      for (var i = 0; i < values.length; i++) {
        shader!.setFloat(i, values[i]);
      }
      shader!.setImageSampler(0, image!);
      canvas.drawRect(rect, Paint()..shader = shader);
    } else if (image != null) {
      paintImage(canvas: canvas, rect: rect, image: image!, fit: BoxFit.fill);
    } else {
      const _MiniScenePainter().paint(canvas, size);
    }
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0x45101930), Color(0x70101930), Color(0x90101930)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_MiniGlassPainter old) =>
      old.shader != shader ||
      old.image != image ||
      old.refraction != refraction ||
      old.chromatic != chromatic;
}

class _MiniScenePainter extends CustomPainter {
  const _MiniScenePainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xff0b224b), Color(0xff4559a4), Color(0xff6d3054)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(Offset.zero & size),
    );
    for (var i = -2; i < 12; i++) {
      final x = i * 55.0;
      canvas.drawLine(
        Offset(x, -40),
        Offset(x - 140, size.height + 40),
        Paint()
          ..color =
              (i.isEven ? const Color(0xff9edbd0) : const Color(0xffe2a1b8))
                  .withValues(alpha: 0.4)
          ..strokeWidth = 18,
      );
    }
    canvas.drawCircle(
      Offset(size.width * .8, size.height * .35),
      65,
      Paint()..color = const Color(0x446fe8e4),
    );
  }

  @override
  bool shouldRepaint(_MiniScenePainter old) => false;
}
