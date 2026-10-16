import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/format/app_format.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/theme/glass_theme.dart';
import '../../domain/models/usage_models.dart';

// ─── 1. Sparkline (60s Rolling Live Waveform) ───────────────────────────────

class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.color = const Color(0xFF5AC8FA),
    this.height = 42,
    this.strokeWidth = 1.8,
  });

  final List<int> values;
  final Color color;
  final double height;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _SparklinePainter(
            values: values,
            color: color,
            strokeWidth: strokeWidth,
          ),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.values,
    required this.color,
    required this.strokeWidth,
  });

  final List<int> values;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final pts = values.isEmpty ? const [0, 0] : values;
    final maxVal = pts.fold<int>(1, (m, v) => v > m ? v : m);
    final n = pts.length;

    final path = Path();
    final fillPath = Path();
    const padY = 4.0;
    final usableH = math.max(1.0, size.height - padY * 2);

    Offset pointAt(int i) {
      final x = n <= 1 ? size.width : (i / (n - 1)) * size.width;
      final norm = (pts[i] / maxVal).clamp(0.0, 1.0);
      final y = size.height - padY - norm * usableH;
      return Offset(x, y);
    }

    final first = pointAt(0);
    path.moveTo(first.dx, first.dy);
    fillPath.moveTo(first.dx, size.height);
    fillPath.lineTo(first.dx, first.dy);

    for (var i = 1; i < n; i++) {
      final prev = pointAt(i - 1);
      final curr = pointAt(i);
      final midX = (prev.dx + curr.dx) / 2;
      path.cubicTo(midX, prev.dy, midX, curr.dy, curr.dx, curr.dy);
      fillPath.cubicTo(midX, prev.dy, midX, curr.dy, curr.dx, curr.dy);
    }

    final last = pointAt(n - 1);
    fillPath.lineTo(last.dx, size.height);
    fillPath.close();

    final fillPaint =
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: 0.34),
              color.withValues(alpha: 0.0),
            ],
          ).createShader(Offset.zero & size);
    canvas.drawPath(fillPath, fillPaint);

    final strokePaint =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, strokePaint);

    // Glowing endpoint dot
    canvas.drawCircle(last, 3.0, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        !listEquals(oldDelegate.values, values);
  }
}

// ─── 2. Interactive UsageChart (Multi-Series Stacked Area & Curve Chart) ────

enum UsageChartColorMode { source, palette }

class _PivotedBucket {
  final int bucket;
  final Map<String, double> values;
  final double total;
  final TokenBreakdown breakdown;

  const _PivotedBucket({
    required this.bucket,
    required this.values,
    required this.total,
    required this.breakdown,
  });
}

class UsageChart extends StatefulWidget {
  const UsageChart({
    super.key,
    required this.points,
    this.showCost = false,
    this.colorBy = UsageChartColorMode.source,
    this.accentColor,
    this.height = 240,
    this.bucket = 'day',
    this.i18n = const AppI18n(isZh: false),
  });

  final List<SeriesPoint> points;
  final bool showCost;
  final UsageChartColorMode colorBy;
  final Color? accentColor;
  final double height;

  /// Explicit query granularity: never infer it from sparse data points.
  final String bucket;
  final AppI18n i18n;

  @override
  State<UsageChart> createState() => _UsageChartState();
}

class _UsageChartState extends State<UsageChart> {
  int? _hoverIndex;
  final _tooltipController = OverlayPortalController();
  final _plotKey = GlobalKey();

  static const List<Color> _palette = [
    Color(0xFF0A84FF), // Blue
    Color(0xFF5AC8FA), // Teal
    Color(0xFFBF5AF2), // Purple
    Color(0xFFFF9F0A), // Amber
    Color(0xFF30D158), // Green
    Color(0xFFFF375F), // Pink
    Color(0xFF5E5CE6), // Indigo
    Color(0xFFFF6B6B), // Coral
  ];

  Color _colorForKey(String key, int index, GlassTheme g) {
    if (widget.colorBy == UsageChartColorMode.source) {
      if (kSourceMeta.containsKey(key)) {
        return GlassTheme.sourceColor(key);
      }
      if (widget.accentColor != null && index == 0) {
        return widget.accentColor!;
      }
    }
    return _palette[index % _palette.length];
  }

  String _labelForKey(String key) {
    if (widget.colorBy == UsageChartColorMode.source) {
      return kSourceMeta[key]?.label ?? key;
    }
    return key;
  }

  (List<_PivotedBucket>, List<String>) _pivotData() {
    final byBucket = <int, Map<String, double>>{};
    final keyTotals = <String, double>{};
    final breakdowns = <int, TokenBreakdown>{};

    for (final p in widget.points) {
      final v = widget.showCost ? p.costUsd : p.totalTokens.toDouble();
      final k = p.key.isEmpty ? 'unknown' : p.key;
      keyTotals[k] = (keyTotals[k] ?? 0.0) + v;
      final row = byBucket.putIfAbsent(p.bucket, () => <String, double>{});
      row[k] = (row[k] ?? 0.0) + v;
      final a = breakdowns[p.bucket] ?? const TokenBreakdown();
      final b = p.totals;
      breakdowns[p.bucket] = TokenBreakdown(
        inputTokens: a.inputTokens + b.inputTokens,
        outputTokens: a.outputTokens + b.outputTokens,
        cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens,
        cacheWriteTokens: a.cacheWriteTokens + b.cacheWriteTokens,
        reasoningTokens: a.reasoningTokens + b.reasoningTokens,
        totalTokens: a.totalTokens + b.totalTokens,
        costUsd: a.costUsd + b.costUsd,
        events: a.events + b.events,
        unpricedEvents: a.unpricedEvents + b.unpricedEvents,
      );
    }

    final keys =
        keyTotals.keys.toList()
          ..sort((a, b) => (keyTotals[b] ?? 0).compareTo(keyTotals[a] ?? 0));

    final sortedBuckets = byBucket.keys.toList()..sort();
    final rows = <_PivotedBucket>[];
    for (final b in sortedBuckets) {
      final raw = byBucket[b]!;
      final values = <String, double>{};
      var total = 0.0;
      for (final k in keys) {
        final v = raw[k] ?? 0.0;
        values[k] = v;
        total += v;
      }
      rows.add(
        _PivotedBucket(
          bucket: b,
          values: values,
          total: total,
          breakdown: breakdowns[b]!,
        ),
      );
    }

    return (rows, keys);
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final (rows, keys) = _pivotData();
    final keyColors = <String, Color>{
      for (var i = 0; i < keys.length; i++)
        keys[i]: _colorForKey(keys[i], i, g),
    };

    if (rows.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Text(
            'No usage recorded in this range',
            style: TextStyle(fontSize: 12.5, color: g.textTertiary),
          ),
        ),
      );
    }

    const leftPad = 50.0;

    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (keys.isNotEmpty) ...[
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                for (final k in keys.take(8))
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: keyColors[k],
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _labelForKey(k),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: g.textSecondary,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          SizedBox(
            height: widget.height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final plotW = math.max(1.0, width - leftPad);
                return OverlayPortal(
                  controller: _tooltipController,
                  overlayChildBuilder: (overlayContext) {
                    final index = _hoverIndex;
                    if (index == null || index >= rows.length) {
                      return const SizedBox.shrink();
                    }
                    final plot =
                        _plotKey.currentContext!.findRenderObject()
                            as RenderBox;
                    final overlay =
                        Overlay.of(context).context.findRenderObject()
                            as RenderBox;
                    final x =
                        leftPad +
                        (rows.length <= 1
                            ? plotW / 2
                            : index / (rows.length - 1) * plotW);
                    final anchor = overlay.globalToLocal(
                      plot.localToGlobal(Offset(x, 6)),
                    );
                    return IgnorePointer(
                      child: CustomSingleChildLayout(
                        delegate: _ChartTooltipPosition(anchor),
                        child: _buildTooltip(
                          context,
                          rows[index],
                          keys,
                          keyColors,
                        ),
                      ),
                    );
                  },
                  child: MouseRegion(
                    key: _plotKey,
                    onHover: (evt) {
                      if (rows.isEmpty || plotW <= 0) return;
                      final relX = (evt.localPosition.dx - leftPad).clamp(
                        0.0,
                        plotW - 0.001,
                      );
                      final idx =
                          rows.length <= 1
                              ? 0
                              : ((relX / plotW) * (rows.length - 1))
                                  .round()
                                  .clamp(0, rows.length - 1);
                      if (_hoverIndex != idx) {
                        setState(() => _hoverIndex = idx);
                      }
                      if (!_tooltipController.isShowing) {
                        _tooltipController.show();
                      }
                    },
                    onExit: (_) {
                      _tooltipController.hide();
                      if (_hoverIndex != null) {
                        setState(() => _hoverIndex = null);
                      }
                    },
                    child: Stack(
                      children: [
                        CustomPaint(
                          size: Size(width, widget.height),
                          painter: _UsageChartPainter(
                            rows: rows,
                            keys: keys,
                            keyColors: keyColors,
                            showCost: widget.showCost,
                            bucket: widget.bucket,
                            leftPad: leftPad,
                            gridColor: g.glassBorder,
                            labelColor: g.textTertiary,
                            hoverIndex: _hoverIndex,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTooltip(
    BuildContext context,
    _PivotedBucket row,
    List<String> keys,
    Map<String, Color> keyColors,
  ) {
    final g = GlassTheme.of(context);
    final i18n = widget.i18n;
    final totals = row.breakdown;
    final activeEntries = <MapEntry<String, double>>[
      for (final k in keys)
        if ((row.values[k] ?? 0) > 0) MapEntry(k, row.values[k]!),
    ]..sort((a, b) => b.value.compareTo(a.value));
    String fmtVal(double v) =>
        widget.showCost ? '\$${v.toStringAsFixed(6)}' : fmtInt(v.round());
    final unpricedNote = AppFormat.unpricedNote(
      totals,
      localize:
          (kind, count) => i18n.t(
            kind == 'none' ? 'common.unpricedNone' : 'common.unpricedPartial',
            {'count': fmtInt(count)},
          ),
    );
    final cost =
        totals.events > 0 && totals.unpricedEvents >= totals.events
            ? '—'
            : '\$${totals.costUsd.toStringAsFixed(6)}';

    Widget detail(
      String label,
      String value,
      Color color, {
      bool strong = false,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: g.textSecondary,
                  fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              value,
              style: GlassTheme.tabularStyle(
                fontSize: 12,
                color: strong ? g.textPrimary : color,
                fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      key: const ValueKey('usage-chart-tooltip'),
      width: 300,
      decoration: BoxDecoration(
        color: g.isDark ? const Color(0xF0141826) : const Color(0xF5FFFFFF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: g.glassBorderStrong, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 14,
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.bucket == 'hour'
                    ? AppFormat.dateTime(row.bucket)
                    : chartBucketLabel(row.bucket, widget.bucket),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: g.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              for (final entry in activeEntries.take(8))
                detail(
                  _labelForKey(entry.key),
                  fmtVal(entry.value),
                  keyColors[entry.key] ?? g.accentBlue,
                ),
              if (activeEntries.isNotEmpty) ...[
                const SizedBox(height: 5),
                Divider(height: 1, color: g.glassBorder),
                const SizedBox(height: 5),
              ],
              detail(
                i18n.t('common.input'),
                fmtInt(totals.inputTokens),
                const Color(0xFF0A84FF),
              ),
              detail(
                i18n.t('common.output'),
                fmtInt(totals.outputTokens),
                const Color(0xFF30D158),
              ),
              detail(
                i18n.t('common.cacheCreate'),
                fmtInt(totals.cacheWriteTokens),
                const Color(0xFFFF9F0A),
              ),
              detail(
                i18n.t('common.cacheRead'),
                fmtInt(totals.cacheReadTokens),
                const Color(0xFFBF5AF2),
              ),
              detail(i18n.t('common.cost'), cost, const Color(0xFFFF375F)),
              if (unpricedNote != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3, bottom: 3),
                  child: Text(
                    unpricedNote,
                    style: TextStyle(fontSize: 10.5, color: g.textTertiary),
                  ),
                ),
              const SizedBox(height: 5),
              Divider(height: 1, color: g.glassBorder),
              const SizedBox(height: 5),
              detail(
                i18n.t('common.total'),
                fmtInt(totals.totalTokens),
                g.textPrimary,
                strong: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Measure the complete card before positioning it in the overlay, rather
/// than clipping a taller tooltip to the 220px chart or a viewport edge.
class _ChartTooltipPosition extends SingleChildLayoutDelegate {
  const _ChartTooltipPosition(this.anchor);
  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(0, math.min(300, constraints.maxWidth - 16)),
        maxHeight: math.max(0, constraints.maxHeight - 16),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final right = anchor.dx + 14;
    final left =
        right + childSize.width <= size.width - 8
            ? right
            : anchor.dx - childSize.width - 14;
    return Offset(
      left.clamp(8.0, math.max(8.0, size.width - childSize.width - 8)),
      anchor.dy.clamp(8.0, math.max(8.0, size.height - childSize.height - 8)),
    );
  }

  @override
  bool shouldRelayout(_ChartTooltipPosition oldDelegate) =>
      oldDelegate.anchor != anchor;
}

class _UsageChartPainter extends CustomPainter {
  _UsageChartPainter({
    required this.rows,
    required this.keys,
    required this.keyColors,
    required this.showCost,
    required this.leftPad,
    required this.gridColor,
    required this.labelColor,
    required this.hoverIndex,
    required this.bucket,
  });

  final List<_PivotedBucket> rows;
  final List<String> keys;
  final Map<String, Color> keyColors;
  final bool showCost;
  final double leftPad;
  final Color gridColor;
  final Color labelColor;
  final int? hoverIndex;
  final String bucket;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= leftPad || size.height <= 0) return;

    const topPad = 12.0;
    const bottomPad = 24.0;
    final chartH = math.max(10.0, size.height - topPad - bottomPad);
    final plotW = math.max(10.0, size.width - leftPad);

    final maxVal = rows.fold<double>(
      showCost ? 0.01 : 1.0,
      (m, r) => math.max(m, r.total),
    );

    // Horizontal grid lines + Y-axis labels
    final gridPaint =
        Paint()
          ..color = gridColor
          ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final ratio = i / 3;
      final y = topPad + ratio * chartH;
      canvas.drawLine(Offset(leftPad, y), Offset(size.width, y), gridPaint);

      final tickVal = maxVal * (1.0 - ratio);
      final tickText = showCost ? fmtUsd(tickVal) : fmtTokens(tickVal.round());
      final tp = TextPainter(
        text: TextSpan(
          text: tickText,
          style: TextStyle(fontSize: 10, color: labelColor),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(math.max(0, leftPad - tp.width - 6), y - tp.height / 2),
      );
    }

    if (rows.isEmpty || keys.isEmpty) return;

    final n = rows.length;
    double xAt(int i) => leftPad + (n <= 1 ? plotW / 2 : (i / (n - 1)) * plotW);
    double yForVal(double v) =>
        topPad + chartH - (v / maxVal).clamp(0.0, 1.0) * chartH;

    // Compute cumulative stacked values per bucket
    final cumulative = List<List<double>>.generate(
      n,
      (_) => List<double>.filled(keys.length + 1, 0.0),
    );
    for (var i = 0; i < n; i++) {
      var sum = 0.0;
      for (var kIdx = 0; kIdx < keys.length; kIdx++) {
        sum += rows[i].values[keys[kIdx]] ?? 0.0;
        cumulative[i][kIdx + 1] = sum;
      }
    }

    // Draw each series stacked band (bottom-to-top) and its top curve stroke
    for (var kIdx = 0; kIdx < keys.length; kIdx++) {
      final key = keys[kIdx];
      final color = keyColors[key] ?? const Color(0xFF0A84FF);

      // Check if this series has any non-zero data
      var hasNonZero = false;
      for (var i = 0; i < n; i++) {
        if ((rows[i].values[key] ?? 0.0) > 0) {
          hasNonZero = true;
          break;
        }
      }
      if (!hasNonZero) continue;

      final topPoints = <Offset>[
        for (var i = 0; i < n; i++)
          Offset(xAt(i), yForVal(cumulative[i][kIdx + 1])),
      ];
      final bottomPoints = <Offset>[
        for (var i = 0; i < n; i++)
          Offset(xAt(i), yForVal(cumulative[i][kIdx])),
      ];

      // A moveTo-only path has no stroke or area. Sparse ranges with one
      // occupied bucket must still display their data without hovering.
      if (n == 1) {
        canvas.drawLine(
          bottomPoints.first,
          topPoints.first,
          Paint()
            ..color = color.withValues(alpha: 0.35)
            ..strokeWidth = 8,
        );
        canvas.drawCircle(topPoints.first, 4, Paint()..color = color);
      }

      final linePath = Path()..moveTo(topPoints[0].dx, topPoints[0].dy);
      final areaPath =
          Path()
            ..moveTo(bottomPoints[0].dx, bottomPoints[0].dy)
            ..lineTo(topPoints[0].dx, topPoints[0].dy);

      for (var i = 1; i < n; i++) {
        final prev = topPoints[i - 1];
        final curr = topPoints[i];
        final midX = (prev.dx + curr.dx) / 2;
        linePath.cubicTo(midX, prev.dy, midX, curr.dy, curr.dx, curr.dy);
        areaPath.cubicTo(midX, prev.dy, midX, curr.dy, curr.dx, curr.dy);
      }

      areaPath.lineTo(bottomPoints[n - 1].dx, bottomPoints[n - 1].dy);
      for (var i = n - 2; i >= 0; i--) {
        final next = bottomPoints[i + 1];
        final curr = bottomPoints[i];
        final midX = (next.dx + curr.dx) / 2;
        areaPath.cubicTo(midX, next.dy, midX, curr.dy, curr.dx, curr.dy);
      }
      areaPath.close();

      canvas.drawPath(
        areaPath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: 0.42),
              color.withValues(alpha: 0.06),
            ],
          ).createShader(Rect.fromLTWH(leftPad, topPad, plotW, chartH)),
      );

      canvas.drawPath(
        linePath,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // X-axis labels (up to 6 evenly spaced labels)
    final step = math.max(1, (n / 6).ceil());
    for (var i = 0; i < n; i += step) {
      final x = xAt(i);
      final tp = TextPainter(
        text: TextSpan(
          text: chartBucketLabel(rows[i].bucket, bucket),
          style: TextStyle(fontSize: 10.5, color: labelColor),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx =
          (x - tp.width / 2)
              .clamp(leftPad, math.max(leftPad, size.width - tp.width))
              .toDouble();
      tp.paint(canvas, Offset(dx, topPad + chartH + 6));
    }

    // Hover indicator line & active series points
    if (hoverIndex != null && hoverIndex! >= 0 && hoverIndex! < n) {
      final hi = hoverIndex!;
      final hx = xAt(hi);
      canvas.drawLine(
        Offset(hx, topPad),
        Offset(hx, topPad + chartH),
        Paint()
          ..color = labelColor.withValues(alpha: 0.45)
          ..strokeWidth = 1.2,
      );
      for (var kIdx = 0; kIdx < keys.length; kIdx++) {
        final key = keys[kIdx];
        if ((rows[hi].values[key] ?? 0.0) <= 0) continue;
        final color = keyColors[key] ?? const Color(0xFF0A84FF);
        final hy = yForVal(cumulative[hi][kIdx + 1]);
        canvas.drawCircle(Offset(hx, hy), 4.2, Paint()..color = color);
        canvas.drawCircle(Offset(hx, hy), 2.0, Paint()..color = Colors.white);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _UsageChartPainter oldDelegate) {
    return oldDelegate.rows != rows ||
        oldDelegate.keys != keys ||
        oldDelegate.showCost != showCost ||
        oldDelegate.bucket != bucket ||
        !mapEquals(oldDelegate.keyColors, keyColors) ||
        oldDelegate.hoverIndex != hoverIndex;
  }
}

String chartBucketLabel(int timestamp, String bucket) {
  if (bucket == 'hour') return AppFormat.time(timestamp);
  if (bucket == 'month') {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}';
  }
  return AppFormat.date(timestamp);
}

// ─── 3. CalendarHeatmap (GitHub-style Activity Grid) ────────────────────────

class CalendarHeatmap extends StatelessWidget {
  const CalendarHeatmap({super.key, required this.points, this.accentColor});

  final List<CalendarPoint> points;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final color = accentColor ?? g.accentBlue;
    final maxTokens = points.fold<int>(
      1,
      (m, p) => p.tokens > m ? p.tokens : m,
    );

    final displayPoints =
        points.length > 182 ? points.sublist(points.length - 182) : points;

    return RepaintBoundary(
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final pt in displayPoints)
            Tooltip(
              message: '${pt.day}: ${fmtTokens(pt.tokens)} tokens',
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color:
                      pt.tokens <= 0
                          ? g.glassSurface
                          : color.withValues(
                            alpha: (0.18 + 0.82 * (pt.tokens / maxTokens))
                                .clamp(0.18, 1.0),
                          ),
                  borderRadius: BorderRadius.circular(3.5),
                  border: Border.all(color: g.glassBorder, width: 0.6),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── 4. ShareList (Ranked Breakdown List) ───────────────────────────────────

class ShareListItemData {
  const ShareListItemData({
    required this.label,
    required this.tokens,
    required this.costUsd,
    required this.share,
    this.color,
    this.subtitle,
    this.onTap,
  });

  final String label;
  final int tokens;
  final double costUsd;
  final double share;
  final Color? color;
  final String? subtitle;
  final VoidCallback? onTap;
}

class ShareList extends StatelessWidget {
  const ShareList({
    super.key,
    required this.items,
    required this.emptyText,
    this.maxItems = 8,
  });

  final List<ShareListItemData> items;
  final String emptyText;
  final int maxItems;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            emptyText,
            style: TextStyle(fontSize: 12.5, color: g.textTertiary),
          ),
        ),
      );
    }

    final slice = items.take(maxItems).toList();
    return Column(
      children: [
        for (var i = 0; i < slice.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _ShareRow(item: slice[i]),
        ],
      ],
    );
  }
}

class _ShareRow extends StatelessWidget {
  const _ShareRow({required this.item});

  final ShareListItemData item;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final barColor = item.color ?? g.accentBlue;
    final ratio = (item.share > 1.0 ? item.share / 100.0 : item.share).clamp(
      0.0,
      1.0,
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: barColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: g.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              fmtTokens(item.tokens),
              style: GlassTheme.tabularStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: g.textPrimary,
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 58,
              child: Text(
                fmtUsd(item.costUsd),
                textAlign: TextAlign.right,
                style: GlassTheme.tabularStyle(
                  fontSize: 12,
                  color: g.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 44,
              child: Text(
                fmtShare(item.share),
                textAlign: TextAlign.right,
                style: GlassTheme.tabularStyle(
                  fontSize: 11.5,
                  color: g.textTertiary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 5,
            backgroundColor: g.glassSurface,
            valueColor: AlwaysStoppedAnimation<Color>(barColor),
          ),
        ),
      ],
    );

    if (item.onTap != null) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: item.onTap,
          child: content,
        ),
      );
    }
    return content;
  }
}
