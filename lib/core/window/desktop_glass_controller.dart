import 'package:desktop_glass/desktop_glass.dart';
import 'package:flutter/foundation.dart';

enum DesktopGlassMode { connecting, realtime, frosted }

/// Scoped to one mini-window view. A late completion can only stop its own ID.
class DesktopGlassController extends ChangeNotifier {
  DesktopGlassController({this.backend = const DesktopGlass()});
  final DesktopGlass backend;
  DesktopGlassMode mode = DesktopGlassMode.connecting;
  GlassSession? session;
  GlassStats? currentStats;
  String? reason;
  bool _disposed = false;
  int _generation = 0;
  bool _connecting = false;

  Future<void> connect({required bool shaderSupported}) async {
    if (_disposed || _connecting || session != null) return;
    final generation = ++_generation;
    _connecting = true;
    mode = DesktopGlassMode.connecting;
    reason = null;
    notifyListeners();
    try {
      final capability = await backend.capabilities();
      if (_disposed || generation != _generation) return;
      if (!capability.realtimeCapture || !capability.selfExclusion) {
        reason = capability.reason ?? 'platformUnsupported';
        mode = DesktopGlassMode.frosted;
      } else if (!shaderSupported) {
        reason = 'shaderUnsupported';
        mode = DesktopGlassMode.frosted;
      } else {
        final started = await backend.start();
        if (_disposed || generation != _generation) {
          await backend.stop(started.id);
          return;
        }
        session = started;
        mode = DesktopGlassMode.realtime;
      }
    } catch (error) {
      if (!_disposed && generation == _generation) {
        reason = '$error';
        mode = DesktopGlassMode.frosted;
      }
    } finally {
      if (!_disposed && generation == _generation) {
        _connecting = false;
        notifyListeners();
      }
    }
  }

  Future<GlassStats?> refreshStats() async {
    final owned = session;
    if (_disposed || owned == null) return null;
    try {
      final stats = await backend.stats(owned.id);
      if (_disposed || session?.id != owned.id) return null;
      currentStats = stats;
      if (stats == null) session = null;
      if (stats == null) {
        reason = 'sessionEnded';
        mode = DesktopGlassMode.frosted;
      } else if (!stats.hasValidFrame) {
        reason = stats.captureState;
        mode = stats.captureState == 'failed'
            ? DesktopGlassMode.frosted
            : DesktopGlassMode.connecting;
      } else if (stats.error != null) {
        reason = stats.error;
        mode = DesktopGlassMode.frosted;
      } else {
        reason = null;
        mode = DesktopGlassMode.realtime;
      }
      notifyListeners();
      return stats;
    } catch (error) {
      if (!_disposed && session?.id == owned.id) {
        reason = '$error';
        mode = DesktopGlassMode.frosted;
        notifyListeners();
      }
      return null;
    }
  }

  Future<void> reconnect({required bool shaderSupported}) async {
    if (_disposed || _connecting) return;
    final generation = ++_generation;
    final owned = session;
    session = null;
    currentStats = null;
    mode = DesktopGlassMode.connecting;
    reason = null;
    notifyListeners();
    if (owned != null) {
      try {
        await backend.stop(owned.id);
      } catch (_) {
        // start() replaces any native session that survived this best-effort stop.
      }
    }
    if (_disposed || generation != _generation) return;
    await connect(shaderSupported: shaderSupported);
  }

  Future<void> setPaused(bool paused) async {
    final owned = session;
    if (_disposed || owned == null) return;
    try {
      if (paused) {
        await backend.pause(owned.id);
      } else {
        await backend.resume(owned.id);
      }
    } catch (error) {
      if (!_disposed && session?.id == owned.id) {
        reason = '$error';
        mode = DesktopGlassMode.frosted;
        notifyListeners();
      }
    }
  }

  Future<void> disconnect() async {
    ++_generation;
    _connecting = false;
    final owned = session;
    session = null;
    currentStats = null;
    if (owned != null) await backend.stop(owned.id);
  }

  @override
  void dispose() {
    _disposed = true;
    // Destruction of a view must never send an unscoped global stop command.
    disconnect().catchError((Object _) {});
    super.dispose();
  }
}
