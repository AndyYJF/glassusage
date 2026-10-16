import 'dart:collection';
import 'dart:math' as math;

import '../../domain/models/usage_models.dart';

const int kLiveWindowMs = 60000;
const int kLiveActiveMs = 5 * 60000;

/// EMA smoothing factor: ~10s time constant at 1s tick rate (1 - exp(-1/10))
/// or 0.4 for fast response. We use 1 - exp(-1/10) per PLAN.md §4.3.
final double kEmaAlpha = 1.0 - math.exp(-1.0 / 10.0);

class _LiveEntry {
  final int tsMs;
  final int tokens;
  final String source;
  final bool isRequest;

  const _LiveEntry({
    required this.tsMs,
    required this.tokens,
    required this.source,
    required this.isRequest,
  });
}

/// Sliding-window RPM / TPM tracker with cached today's totals so the 1 Hz
/// live-tick never executes SQLite queries unless midnight rolls over.
class LiveTracker {
  final Set<String> _pollingSources;
  final Queue<_LiveEntry> _events = Queue<_LiveEntry>();
  final Map<String, int> _lastSeen = {};
  final Map<String, (double, double)> _smoothedPerSource = {};

  double _smoothedRpm = 0.0;
  double _smoothedTpm = 0.0;
  double _costToday = 0.0;
  int _tokensToday = 0;
  String _cachedTodayKey = '';
  bool _totalsDirty = true;

  LiveTracker({Iterable<String> pollingSources = const [SourceIds.cursor]})
      : _pollingSources = pollingSources.toSet();

  bool get totalsDirty => _totalsDirty;

  void markTotalsDirty() {
    _totalsDirty = true;
  }

  /// Checks whether local midnight has rolled over or totals were marked dirty.
  bool needsTodayRefresh(String currentDayKey) {
    return _totalsDirty || _cachedTodayKey != currentDayKey;
  }

  void setTodayTotals({
    required int tokens,
    required double cost,
    required String dayKey,
  }) {
    _tokensToday = tokens;
    _costToday = cost;
    _cachedTodayKey = dayKey;
    _totalsDirty = false;
  }

  void push(List<DeltaEvent> deltas) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final d in deltas) {
      if (d.tokens <= 0 && !d.isNewRequest) continue;
      final prev = _lastSeen[d.source];
      if (prev == null || d.tsMs > prev) {
        _lastSeen[d.source] = d.tsMs;
      }
      _events.addLast(
        _LiveEntry(
          tsMs: d.tsMs,
          tokens: d.tokens,
          source: d.source,
          isRequest: d.isNewRequest,
        ),
      );
    }

    final cutoff = now - kLiveWindowMs;
    while (_events.length > 20000 ||
        (_events.isNotEmpty && _events.first.tsMs < cutoff - kLiveWindowMs)) {
      _events.removeFirst();
    }
  }

  void warmUp(List<(int, String, int)> rows) {
    push(
      rows
          .map(
            (r) => DeltaEvent(
              source: r.$2,
              timestamp: r.$1,
              deltaTokens: r.$3,
              deltaEvents: 1,
            ),
          )
          .toList(),
    );
  }

  LiveRates tick({int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - kLiveWindowMs;

    while (_events.isNotEmpty && _events.first.tsMs < cutoff) {
      _events.removeFirst();
    }

    var requests = 0.0;
    var tokens = 0.0;
    final perSourceRaw = <String, (double, double)>{};
    final spark = List<int>.filled(60, 0);

    for (final e in _events) {
      if (e.tsMs > now + kLiveWindowMs) continue;
      if (e.isRequest) requests += 1.0;
      tokens += e.tokens.toDouble();
      final prev = perSourceRaw[e.source] ?? (0.0, 0.0);
      perSourceRaw[e.source] = (
        prev.$1 + (e.isRequest ? 1.0 : 0.0),
        prev.$2 + e.tokens.toDouble(),
      );

      final bucket = ((e.tsMs - cutoff) ~/ 1000).clamp(0, 59);
      spark[bucket] += e.tokens;
    }

    _smoothedRpm = _ema(_smoothedRpm, requests);
    _smoothedTpm = _ema(_smoothedTpm, tokens);

    final perSource = <LiveSource>[];
    for (final source in SourceIds.all) {
      final raw = perSourceRaw[source] ?? (0.0, 0.0);
      final cur = _smoothedPerSource[source] ?? (0.0, 0.0);
      final nextRpm = _ema(cur.$1, raw.$1);
      final nextTpm = _ema(cur.$2, raw.$2);
      _smoothedPerSource[source] = (nextRpm, nextTpm);

      final lastSeen = _lastSeen[source];
      final active = lastSeen != null && (now - lastSeen) < kLiveActiveMs;

      perSource.add(
        LiveSource(
          source: source,
          rpm: _round1(nextRpm),
          tpm: _round1(nextTpm),
          active: active,
          polling: _pollingSources.contains(source),
        ),
      );
    }

    return LiveRates(
      rpm: _round1(_smoothedRpm),
      tpm: _round1(_smoothedTpm),
      costToday: _costToday,
      tokensToday: _tokensToday,
      perSource: perSource,
      spark60: spark,
      budgetCostToday: _costToday,
      budgetTokensToday: _tokensToday,
    );
  }

  static double _ema(double prev, double next) {
    final v = prev + kEmaAlpha * (next - prev);
    return v.abs() < 0.05 ? 0.0 : v;
  }

  static double _round1(double v) => (v * 10.0).roundToDouble() / 10.0;
}
