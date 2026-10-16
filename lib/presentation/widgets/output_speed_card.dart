import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/app_format.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/theme/glass_theme.dart';
import '../../domain/models/output_speed.dart';
import '../providers/app_providers.dart';
import 'glass_widgets.dart';

/// Isolated live subscriber: the completed-result clock does not rebuild the
/// dashboard charts or change when the historical range selector changes.
class OutputSpeedCard extends ConsumerWidget {
  const OutputSpeedCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = GlassTheme.of(context);
    final i18n = ref.watch(i18nProvider);
    final samples = ref.watch(
      liveRatesProvider.select((rates) => rates.outputSpeeds),
    );
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.speed_rounded, size: 18, color: g.accentTeal),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  i18n.t('speed.title'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: g.textPrimary,
                  ),
                ),
              ),
              Tooltip(
                message: i18n.t('speed.explanation'),
                child: Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: g.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            i18n.t('speed.subtitle'),
            style: TextStyle(fontSize: 11.5, color: g.textTertiary),
          ),
          const SizedBox(height: 12),
          if (samples.isEmpty)
            Text(
              i18n.t('speed.waiting'),
              style: TextStyle(fontSize: 12, color: g.textSecondary),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 760 ? 2 : 1;
                final width =
                    (constraints.maxWidth - 12 * (columns - 1)) / columns;
                return Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    for (final sample in samples)
                      SizedBox(
                        width: width,
                        child: _OutputSpeedRow(sample: sample, i18n: i18n),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

class _OutputSpeedRow extends StatelessWidget {
  const _OutputSpeedRow({required this.sample, required this.i18n});
  final OutputSpeedSample sample;
  final AppI18n i18n;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final speed = sample.tokensPerSecond;
    final value =
        speed == null
            ? '—'
            : speed < 0.1
            ? '<0.1'
            : speed.toStringAsFixed(1);
    final scope = i18n.t(
      sample.scope == OutputTimingScope.turn ? 'speed.turn' : 'speed.response',
    );
    final source = kSourceMeta[sample.source]?.label ?? sample.source;
    final relative = AppFormat.relative(sample.completedAtMs, zh: i18n.isZh);
    final duration = sample.durationMs;
    final detail =
        speed == null
            ? i18n.t('speed.unavailable')
            : '${fmtInt(sample.outputTokens)} token · ${(duration! / 1000).toStringAsFixed(1)} s';
    return Tooltip(
      message:
          '${AppFormat.dateTime(sample.completedAtMs)}\n$scope\n${i18n.t('speed.explanation')}',
      child: Container(
        key: ValueKey('output-speed-${sample.source}-${sample.model}'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: g.glassSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: g.glassBorder),
        ),
        child: Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: GlassTheme.sourceColor(sample.source),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              flex: 6,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sample.model,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: g.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$source · $scope · $relative',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: g.textTertiary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      speed == null ? value : '$value token/s',
                      style: GlassTheme.tabularStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: speed == null ? g.textTertiary : g.accentTeal,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 10.5, color: g.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
