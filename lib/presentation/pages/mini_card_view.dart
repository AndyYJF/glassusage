import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/app_format.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/window/win32_bridge.dart';
import '../../domain/models/usage_models.dart';
import '../providers/app_providers.dart';
import '../widgets/charts.dart';
import '../widgets/odometer.dart';

class MiniCardView extends ConsumerWidget {
  const MiniCardView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = GlassTheme.of(context);
    final i18n = ref.watch(i18nProvider);
    final live = ref.watch(liveRatesProvider);
    final compact =
        ref.watch(appSettingsProvider.select((s) => s.widgetCompact));
    final controller = ref.read(appControllerProvider);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) {
        Win32Bridge.instance.startDragging(snapAfterDrag: true);
      },
      child: Container(
        decoration: BoxDecoration(
          color: g.bgCanvas.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: g.glassBorderStrong, width: 1),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 14,
          vertical: compact ? 8 : 12,
        ),
        child: compact
            ? _buildCompact(context, g, live, controller)
            : _buildFull(context, g, i18n, live, controller),
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
              color: g.textPrimary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          icon: Icon(
            Icons.unfold_more_rounded,
            size: 15,
            color: g.textSecondary,
          ),
          onPressed: () => controller.setCompactWidget(false),
        ),
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          icon: Icon(
            Icons.open_in_full_rounded,
            size: 14,
            color: g.textSecondary,
          ),
          onPressed: () => controller.setWidgetMode(false),
        ),
      ],
    );
  }

  Widget _buildFull(
    BuildContext context,
    GlassTheme g,
    dynamic i18n,
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
                  color: g.textSecondary,
                ),
              ),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              icon: Icon(
                Icons.unfold_less_rounded,
                size: 15,
                color: g.textSecondary,
              ),
              onPressed: () => controller.setCompactWidget(true),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              icon: Icon(
                Icons.open_in_full_rounded,
                size: 14,
                color: g.textSecondary,
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
                  formatter: (v) => fmtTokens(v.round()),
                  fontSize: 22,
                ),
                Text(
                  'Tokens / min',
                  style: TextStyle(fontSize: 10.5, color: g.textTertiary),
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
                  color: g.accentTeal,
                ),
                Text(
                  'Requests / min',
                  style: TextStyle(fontSize: 10.5, color: g.textTertiary),
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
                color: g.textSecondary,
              ),
            ),
            Text(
              fmtUsd(live.costToday),
              style: GlassTheme.tabularStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: g.accentTeal,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
