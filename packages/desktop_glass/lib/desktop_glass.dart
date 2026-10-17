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

class GlassSession {
  const GlassSession({required this.id, required this.textureId});
  final int id;
  final int textureId;
}

class GlassStats {
  GlassStats(Map<String, dynamic> data)
    : frames = (data['frames'] as num?)?.toInt() ?? 0,
      presented = (data['presented'] as num?)?.toInt() ?? 0,
      changes = (data['changes'] as num?)?.toInt() ?? 0,
      elapsed = (data['elapsed'] as num?)?.toDouble() ?? 0,
      luminance = (data['luminance'] as num?)?.toDouble() ?? 0,
      paused = data['paused'] == true,
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
    if (targetFps < 1 || targetFps > 60) {
      throw ArgumentError.value(
        targetFps,
        'targetFps',
        'Must be between 1 and 60',
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
