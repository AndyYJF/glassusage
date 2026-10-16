import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/format/app_format.dart';
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

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.34),
          color.withValues(alpha: 0.0),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawPath(fillPath, fillPaint);

    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, strokePaint);

    // Glowing endpoint dot
    canvas.drawCircle(
      last,
      3.0,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        !listEquals(oldDelegate.values, values);
  }
}

// ─── 2. Interactive UsageChart (Tokens / Cost Area & Bar Chart) ─────────────

class UsageChart extends StatefulWidget {
  const UsageChart({
    super.key,
    required this.points,
    this.showCost = false,
    this.accentColor,
    this.height = 220,
  });

  final List<SeriesPoint> points;
  final bool showCost;
  final Color? accentColor;
  final double height;

  @override
  State<UsageChart> createState() => _UsageChartState();
}

class _UsageChartState extends State<UsageChart> {
  int? _hoverIndex;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final color = widget.accentColor ?? g.accentBlue;
    final pts = widget.points;

    return RepaintBoundary(
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return MouseRegion(
              onHover: (evt) {
                if (pts.isEmpty || width <= 0) return;
                final ratio = (evt.localPosition.dx / width).clamp(0.0, 0.9999);
                final idx = (ratio * pts.length).floor();
                if (_hoverIndex != idx) {
                  setState(() => _hoverIndex = idx);
                }
              },
              onExit: (_) {
                if (_hoverIndex != null) {
                  setState(() => _hoverIndex = null);
                }
              },
              child: Stack(
                children: [
                  CustomPaint(
                    size: Size(width, widget.height),
                    painter: _UsageChartPainter(
                      points: pts,
                      showCost: widget.showCost,
                      color: color,
                      gridColor: g.glassBorder,
                      labelColor: g.textTertiary,
                      hoverIndex: _hoverIndex,
                    ),
                  ),
                  if (_hoverIndex != null &&
                      _hoverIndex! >= 0 &&
                      _hoverIndex! < pts.length)
                    _buildTooltip(
                      context,
                      pts[_hoverIndex!],
                      _hoverIndex!,
                      pts.length,
                      width,
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTooltip(
    BuildContext context,
    SeriesPoint pt,
    int index,
    int count,
    double totalWidth,
  ) {
    final g = GlassTheme.of(context);
    final xRatio = count <= 1 ? 0.5 : index / (count - 1);
    final left = (xRatio * (totalWidth - 190))
        .clamp(8.0, math.max(8.0, totalWidth - 198))
        .toDouble();

    return Positioned(
      top: 8,
      left: left,
      child: IgnorePointer(
        child: Container(
          width: 190,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            color: g.isDark
                ? const Color(0xEB141826)
                : const Color(0xF2FFFFFF),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: g.glassBorderStrong, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 12,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AppFormat.dateTime(pt.bucket),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: g.textSecondary,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    fmtTokens(pt.totalTokens),
                    style: GlassTheme.tabularStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: g.textPrimary,
                    ),
                  ),
                  Text(
                    fmtUsd(pt.costUsd),
                    style: GlassTheme.tabularStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: g.accentTeal,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                'In ${fmtTokens(pt.totals.inputTokens)} · Out ${fmtTokens(pt.totals.outputTokens)} · Cache ${fmtTokens(pt.totals.cacheReadTokens)}',
                style: GlassTheme.tabularStyle(
                  fontSize: 10,
                  color: g.textTertiary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UsageChartPainter extends CustomPainter {
  _UsageChartPainter({
    required this.points,
    required this.showCost,
    required this.color,
    required this.gridColor,
    required this.labelColor,
    required this.hoverIndex,
  });

  final List<SeriesPoint> points;
  final bool showCost;
  final Color color;
  final Color gridColor;
  final Color labelColor;
  final int? hoverIndex;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    const topPad = 14.0;
    const bottomPad = 24.0;
    final chartH = math.max(10.0, size.height - topPad - bottomPad);

    // Horizontal grid lines
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = topPad + (i / 3) * chartH;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (points.isEmpty) return;

    double valOf(SeriesPoint p) =>
        showCost ? p.costUsd : p.totalTokens.toDouble();

    final maxVal = points.fold<double>(
      showCost ? 0.01 : 1.0,
      (m, p) => math.max(m, valOf(p)),
    );

    final n = points.length;
    Offset ptOffset(int i) {
      final x = n <= 1 ? size.width / 2 : (i / (n - 1)) * size.width;
      final norm = (valOf(points[i]) / maxVal).clamp(0.0, 1.0);
      final y = topPad + chartH - norm * chartH;
      return Offset(x, y);
    }

    final linePath = Path();
    final areaPath = Path();

    final p0 = ptOffset(0);
    linePath.moveTo(p0.dx, p0.dy);
    areaPath.moveTo(p0.dx, topPad + chartH);
    areaPath.lineTo(p0.dx, p0.dy);

    for (var i = 1; i < n; i++) {
      final prev = ptOffset(i - 1);
      final curr = ptOffset(i);
      final midX = (prev.dx + curr.dx) / 2;
      linePath.cubicTo(midX, prev.dy, midX, curr.dy, curr.dx, curr.dy);
      areaPath.cubicTo(midX, prev.dy, midX, curr.dy, curr.dx, curr.dy);
    }

    final pLast = ptOffset(n - 1);
    areaPath.lineTo(pLast.dx, topPad + chartH);
    areaPath.close();

    canvas.drawPath(
      areaPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.32),
            color.withValues(alpha: 0.02),
          ],
        ).createShader(Rect.fromLTWH(0, topPad, size.width, chartH)),
    );

    canvas.drawPath(
      linePath,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );

    // X-axis labels (up to 6 evenly spaced labels)
    final step = math.max(1, (n / 6).ceil());
    for (var i = 0; i < n; i += step) {
      final pos = ptOffset(i);
      final tp = TextPainter(
        text: TextSpan(
          text: AppFormat.date(points[i].bucket),
          style: TextStyle(fontSize: 10.5, color: labelColor),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = (pos.dx - tp.width / 2)
          .clamp(0.0, math.max(0.0, size.width - tp.width))
          .toDouble();
      tp.paint(canvas, Offset(dx, topPad + chartH + 6));
    }

    // Hover indicator line & point
    if (hoverIndex != null && hoverIndex! >= 0 && hoverIndex! < n) {
      final hp = ptOffset(hoverIndex!);
      canvas.drawLine(
        Offset(hp.dx, topPad),
        Offset(hp.dx, topPad + chartH),
        Paint()
          ..color = color.withValues(alpha: 0.45)
          ..strokeWidth = 1.2,
      );
      canvas.drawCircle(hp, 4.5, Paint()..color = color);
      canvas.drawCircle(
        hp,
        2.2,
        Paint()..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _UsageChartPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.showCost != showCost ||
        oldDelegate.color != color ||
        oldDelegate.hoverIndex != hoverIndex;
  }
}

// ─── 3. CalendarHeatmap (GitHub-style Activity Grid) ────────────────────────

class CalendarHeatmap extends StatelessWidget {
  const CalendarHeatmap({
    super.key,
    required this.points,
    this.accentColor,
  });

  final List<CalendarPoint> points;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final color = accentColor ?? g.accentBlue;
    final maxTokens =
        points.fold<int>(1, (m, p) => p.tokens > m ? p.tokens : m);

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
                  color: pt.tokens <= 0
                      ? g.glassSurface
                      : color.withValues(
                          alpha: (0.18 + 0.82 * (pt.tokens / maxTokens))
                              .clamp(0.18, 1.0),
                        ),
                  borderRadius: BorderRadius.circular(3.5),
                  border: Border.all(
                    color: g.glassBorder,
                    width: 0.6,
                  ),
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
    final ratio = (item.share > 1.0 ? item.share / 100.0 : item.share)
        .clamp(0.0, 1.0);

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
