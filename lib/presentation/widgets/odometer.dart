import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/glass_theme.dart';
import '../providers/app_providers.dart';

/// Smooth animated numeric display wrapped in [RepaintBoundary] and
/// gated by [TickerMode] (Anti-Jank Rule #4).
class Odometer extends ConsumerWidget {
  const Odometer({
    super.key,
    required this.value,
    required this.formatter,
    this.fontSize = 26,
    this.fontWeight = FontWeight.w700,
    this.color,
    this.duration = const Duration(milliseconds: 360),
  });

  final double value;
  final String Function(double) formatter;
  final double fontSize;
  final FontWeight fontWeight;
  final Color? color;
  final Duration duration;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = GlassTheme.of(context);
    final isVisible = ref.watch(isWindowVisibleProvider);
    final animatedBg =
        ref.watch(appSettingsProvider.select((s) => s.animatedBackground));

    if (!isVisible || !animatedBg) {
      return Text(
        formatter(value),
        style: GlassTheme.tabularStyle(
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color ?? g.textPrimary,
          letterSpacing: -0.5,
        ),
      );
    }

    return RepaintBoundary(
      child: TickerMode(
        enabled: isVisible,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: value),
          duration: duration,
          curve: Curves.easeOutCubic,
          builder: (context, animatedVal, _) {
            return Text(
              formatter(animatedVal),
              style: GlassTheme.tabularStyle(
                fontSize: fontSize,
                fontWeight: fontWeight,
                color: color ?? g.textPrimary,
                letterSpacing: -0.5,
              ),
            );
          },
        ),
      ),
    );
  }
}
