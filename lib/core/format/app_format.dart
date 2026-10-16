import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/usage_models.dart';

class AppFormat {
  static final NumberFormat _num = NumberFormat.decimalPattern('en_US');
  static final DateFormat _timeFmt = DateFormat('HH:mm');
  static final DateFormat _dateFmt = DateFormat('MMM d');
  static final DateFormat _dateTimeFmt = DateFormat('MMM d, HH:mm');

  /// Compact token counts: 1.2K, 45.3M. Full precision below 1000.
  static String tokens(num n) {
    final v = n.round();
    final abs = v.abs();
    if (abs < 1000) return v.toString();
    if (abs < 1000000) {
      return '${(v / 1000.0).toStringAsFixed(abs < 10000 ? 2 : 1)}K';
    }
    if (abs < 1000000000) {
      return '${(v / 1000000.0).toStringAsFixed(abs < 10000000 ? 2 : 1)}M';
    }
    return '${(v / 1000000000.0).toStringAsFixed(2)}B';
  }

  static String fullNumber(num n) => _num.format(n.round());

  static String usd(double? n) {
    if (n == null) return '—';
    final v = n.abs();
    if (v == 0) return r'$0.00';
    if (v < 0.01) return '\$${n.toStringAsFixed(4)}';
    if (v < 1) return '\$${n.toStringAsFixed(3)}';
    if (v < 1000) return '\$${n.toStringAsFixed(2)}';
    return '\$${_num.format(n.round())}';
  }

  static String percent(double n, [int digits = 0]) {
    return '${(n * 100.0).toStringAsFixed(digits)}%';
  }

  static String? unpricedNote(
    TokenBreakdown? b, {
    String Function(String kind, int count)? localize,
  }) {
    if (b == null || b.unpricedEvents <= 0) return null;
    final kind = b.unpricedEvents >= b.events ? 'none' : 'partial';
    if (localize != null) {
      return localize(kind, b.unpricedEvents);
    }
    if (kind == 'none') return 'no price for these models';
    return 'excludes ${fullNumber(b.unpricedEvents)} unpriced';
  }

  static String share(double n) {
    if (n <= 0) return '0%';
    if (n < 0.01) return '<1%';
    return '${(n * 100.0).round()}%';
  }

  static String rate(double n) {
    if (n == 0) return '0';
    if (n < 10) return n.toStringAsFixed(1);
    return tokens(n);
  }

  static String time(int ms) =>
      _timeFmt.format(DateTime.fromMillisecondsSinceEpoch(ms));

  static String date(int ms) =>
      _dateFmt.format(DateTime.fromMillisecondsSinceEpoch(ms));

  static String dateTime(int ms) =>
      _dateTimeFmt.format(DateTime.fromMillisecondsSinceEpoch(ms));

  static String relative(int? ms, {bool zh = false}) {
    if (ms == null || ms <= 0) return zh ? '从未' : 'never';
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    if (diff < 5000) return zh ? '刚刚' : 'just now';
    if (diff < 60000) {
      final s = (diff / 1000.0).round();
      return zh ? '$s秒前' : '${s}s ago';
    }
    if (diff < 3600000) {
      final m = (diff / 60000.0).round();
      return zh ? '$m分钟前' : '${m}m ago';
    }
    if (diff < 86400000) {
      final h = (diff / 3600000.0).round();
      return zh ? '$h小时前' : '${h}h ago';
    }
    final d = (diff / 86400000.0).round();
    return zh ? '$d天前' : '${d}d ago';
  }

  static double? delta(num current, num previous) {
    if (previous == 0) return current == 0 ? 0.0 : null;
    return (current - previous) / previous;
  }

  static String projectLabel(String? path) {
    if (path == null || path.trim().isEmpty) return '—';
    final base = p.basename(path.trim());
    return base.isEmpty ? path : base;
  }
}

String fmtTokens(num n) => AppFormat.tokens(n);
String fmtInt(num n) => AppFormat.fullNumber(n);
String fmtUsd(double? n) => AppFormat.usd(n);
String fmtPct(double n, [int digits = 1]) => AppFormat.percent(n, digits);
String fmtShare(double n) =>
    n > 1.0 ? '${n.toStringAsFixed(1)}%' : AppFormat.share(n);
String fmtRate(double n) => '${AppFormat.rate(n)}/s';
String fmtTimestamp(int ms) => AppFormat.dateTime(ms);
String fmtDelta(double? pct) {
  if (pct == null || pct.isNaN || pct.isInfinite) return '';
  final sign = pct >= 0 ? '+' : '';
  return '$sign${(pct * 100).toStringAsFixed(0)}%';
}

