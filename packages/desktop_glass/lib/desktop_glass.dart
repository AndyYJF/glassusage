import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class GlassCapabilities {
  const GlassCapabilities({
    required this.realtimeCapture,
    required this.selfExclusion,
    required this.requiresPermission,
    this.reason,
  });
  final bool realtimeCapture;
  final bool selfExclusion;
  final bool requiresPermission;
  final String? reason;
}

/// 原生捕获会话及其纹理坐标元数据。
///
/// 当前 macOS 和 Windows 均在原生输出小窗区域，并返回 `displayMapped=false`。
/// 可选坐标字段仅描述纹理布局，不应被用来恢复 Dart 逐帧查询窗口位置的路径。
class GlassSession {
  const GlassSession({
    required this.id,
    required this.textureId,
    this.textureOriginX = 0,
    this.textureOriginY = 0,
    this.textureScale = 1,
    this.textureWidth = 0,
    this.textureHeight = 0,
    this.displayMapped = false,
  });
  final int id;
  final int textureId;

  /// Where the capture texture's (0,0) sits, in global top-left logical
  /// points (window_manager's coordinate space), and how many texture pixels
  /// one logical point covers. Only meaningful when [displayMapped] is true;
  /// otherwise the texture matches the window exactly.
  final double textureOriginX;
  final double textureOriginY;
  final double textureScale;

  /// Capture texture size in logical points (the display size when
  /// [displayMapped] is true).
  final double textureWidth;
  final double textureHeight;

  /// Whether the texture covers a display region and must be cropped using
  /// the texture origin/scale above.
  final bool displayMapped;
}

/// 原生会话的低频诊断快照。
///
/// [frames] 是捕获输出数，[presented] 是取纹理回调数；后者可能重复读取，
/// 两者都不能单独证明屏幕显示帧率或拖动位置已同步。
class GlassStats {
  GlassStats(Map<String, dynamic> data)
    : frames = (data['frames'] as num?)?.toInt() ?? 0,
      presented = (data['presented'] as num?)?.toInt() ?? 0,
      changes = (data['changes'] as num?)?.toInt() ?? 0,
      elapsed = (data['elapsed'] as num?)?.toDouble() ?? 0,
      luminance = (data['luminance'] as num?)?.toDouble() ?? 0,
      paused = data['paused'] == true,
      hasValidFrame =
          data['hasValidFrame'] as bool? ??
          ((data['frames'] as num?)?.toInt() ?? 0) > 0,
      captureState = data['captureState'] as String? ?? 'unknown',
      recoveryEpoch = (data['recoveryEpoch'] as num?)?.toInt() ?? 0,
      lastFrameAgeMs = (data['lastFrameAgeMs'] as num?)?.toDouble(),
      textureOriginX = (data['textureOriginX'] as num?)?.toDouble() ?? 0,
      textureOriginY = (data['textureOriginY'] as num?)?.toDouble() ?? 0,
      textureScale = (data['textureScale'] as num?)?.toDouble() ?? 1,
      textureWidth = (data['textureWidth'] as num?)?.toDouble() ?? 0,
      textureHeight = (data['textureHeight'] as num?)?.toDouble() ?? 0,
      displayMapped = data['displayMapped'] == true,
      error = (data['error'] as String?)?.isEmpty == false
          ? data['error'] as String
          : null,
      raw = Map.unmodifiable(data);
  final int frames;
  final int presented;
  final int changes;
  final double elapsed;
  final double luminance;
  final bool paused;
  final bool hasValidFrame;
  final String captureState;
  final int recoveryEpoch;
  final double? lastFrameAgeMs;
  final double textureOriginX;
  final double textureOriginY;
  final double textureScale;
  final double textureWidth;
  final double textureHeight;
  final bool displayMapped;
  final String? error;
  final Map<String, dynamic> raw;
}

/// Control messages only. Frames are owned by the platform texture registrar.
class DesktopGlass {
  const DesktopGlass();
  static const _channel = MethodChannel('glassusage/desktop_glass');

  Future<GlassCapabilities> capabilities() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.windows &&
            defaultTargetPlatform != TargetPlatform.macOS)) {
      return const GlassCapabilities(
        realtimeCapture: false,
        selfExclusion: false,
        requiresPermission: false,
        reason: 'platformUnsupported',
      );
    }
    try {
      final data =
          await _channel.invokeMapMethod<String, dynamic>('capabilities') ?? {};
      return GlassCapabilities(
        realtimeCapture: data['realtimeCapture'] == true,
        selfExclusion: data['selfExclusion'] == true,
        requiresPermission: data['requiresPermission'] == true,
        reason: data['reason'] as String?,
      );
    } on MissingPluginException {
      return const GlassCapabilities(
        realtimeCapture: false,
        selfExclusion: false,
        requiresPermission: false,
        reason: 'pluginUnavailable',
      );
    }
  }

  Future<GlassSession> start({int targetFps = 60}) async {
    final maxFps = defaultTargetPlatform == TargetPlatform.windows ? 240 : 60;
    if (targetFps < 1 || targetFps > maxFps) {
      throw ArgumentError.value(
        targetFps,
        'targetFps',
        'Must be between 1 and $maxFps',
      );
    }
    final data = await _channel.invokeMapMethod<String, dynamic>('start', {
      'targetFps': targetFps,
    });
    if (data == null ||
        data['sessionId'] is! int ||
        data['textureId'] is! int) {
      throw StateError('The platform returned no desktop texture session');
    }
    return GlassSession(
      id: data['sessionId'] as int,
      textureId: data['textureId'] as int,
      textureOriginX: (data['textureOriginX'] as num?)?.toDouble() ?? 0,
      textureOriginY: (data['textureOriginY'] as num?)?.toDouble() ?? 0,
      textureScale: (data['textureScale'] as num?)?.toDouble() ?? 1,
      textureWidth: (data['textureWidth'] as num?)?.toDouble() ?? 0,
      textureHeight: (data['textureHeight'] as num?)?.toDouble() ?? 0,
      displayMapped: data['displayMapped'] == true,
    );
  }

  Future<void> pause(int sessionId) => _control('pause', sessionId);
  Future<void> resume(int sessionId) => _control('resume', sessionId);
  Future<void> stop(int sessionId) => _control('stop', sessionId);
  Future<void> _control(String method, int sessionId) =>
      _channel.invokeMethod<void>(method, {'sessionId': sessionId});

  Future<GlassStats?> stats(int sessionId) async {
    final data = await _channel.invokeMapMethod<String, dynamic>('stats', {
      'sessionId': sessionId,
    });
    return data == null || data['active'] != true ? null : GlassStats(data);
  }
}
