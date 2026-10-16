import '../../domain/models/output_speed.dart';
import '../../domain/models/usage_models.dart';

/// Latest completed result per source/model. No history replay, polling input,
/// log-arrival interval calculations or 1 Hz database reads.
class OutputSpeedTracker {
  OutputSpeedTracker({int? startedAtMs})
    : startedAtMs = startedAtMs ?? DateTime.now().millisecondsSinceEpoch;

  final int startedAtMs;
  final _latest = <(String, String), OutputSpeedSample>{};
  final _seen = <(String, String, String, String), (int, int?, int)>{};

  void observe(
    Iterable<OutputSpeedSample> samples, {
    required String source,
    required String instance,
    required bool isRealtime,
    int? nowMs,
  }) {
    if (!isRealtime ||
        source == SourceIds.cursor ||
        instance != kLocalInstance) {
      return;
    }
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    for (final sample in samples) {
      if (sample.source != source ||
          sample.instance != instance ||
          sample.outputTokens <= 0 ||
          sample.completedAtMs < startedAtMs ||
          sample.completedAtMs > now + 1000 ||
          sample.completedAtMs < now - 1800000) {
        continue;
      }
      final id = (source, instance, sample.model, sample.requestId);
      final fingerprint = (
        sample.outputTokens,
        sample.durationMs,
        sample.completedAtMs,
      );
      if (_seen[id] == fingerprint) continue;
      _seen.remove(id);
      _seen[id] = fingerprint;
      while (_seen.length > 2048) {
        _seen.remove(_seen.keys.first);
      }
      final key = (source, sample.model);
      final previous = _latest[key];
      if (previous != null && previous.completedAtMs > sample.completedAtMs) {
        continue;
      }
      _latest[key] = sample;
    }
    snapshot(nowMs: now);
  }

  List<OutputSpeedSample> snapshot({int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    _latest.removeWhere((_, sample) => sample.completedAtMs < now - 1800000);
    final entries =
        _latest.entries.toList()..sort(
          (a, b) => b.value.completedAtMs.compareTo(a.value.completedAtMs),
        );
    for (final entry in entries.skip(12)) {
      _latest.remove(entry.key);
    }
    return entries.take(12).map((entry) => entry.value).toList(growable: false);
  }
}
