import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/app_format.dart';
import '../../core/theme/glass_theme.dart';
import '../../domain/models/usage_models.dart';
import '../providers/app_providers.dart';
import '../widgets/charts.dart';
import '../widgets/glass_widgets.dart';

class ComparePage extends ConsumerWidget {
  const ComparePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = GlassTheme.of(context);
    final i18n = ref.watch(i18nProvider);
    final overview = ref.watch(overviewStatsProvider);
    final sources = overview?.perSource ?? const [];
    final models = ref.watch(modelStatsProvider);
    final providers = ref.watch(providerStatsProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Stacked Distribution Bar Card
          GlassCard(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  i18n.t('compare.title'),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: g.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  i18n.t('compare.subtitle'),
                  style: TextStyle(fontSize: 12.5, color: g.textSecondary),
                ),
                const SizedBox(height: 16),
                if (sources.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Text(
                        i18n.t('common.noData'),
                        style: TextStyle(fontSize: 13, color: g.textTertiary),
                      ),
                    ),
                  )
                else ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      height: 14,
                      child: Row(
                        children: [
                          for (final s in sources)
                            if (s.totalTokens > 0)
                              Expanded(
                                flex: (s.share * 1000).round().clamp(1, 1000),
                                child: Container(
                                  color: GlassTheme.sourceColor(s.key),
                                ),
                              ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      for (final s in sources)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AgentBadge(
                              sourceId: s.key,
                              fontSize: 12,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              fmtShare(s.share),
                              style: GlassTheme.tabularStyle(
                                fontSize: 12,
                                color: g.textSecondary,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 2. Side-by-Side Agent & Instance Efficiency Matrix
          GlassCard(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  i18n.t('dash.byAgent'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: g.textPrimary,
                  ),
                ),
                const SizedBox(height: 14),
                if (sources.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: Text(
                        i18n.t('common.noData'),
                        style: TextStyle(fontSize: 12.5, color: g.textTertiary),
                      ),
                    ),
                  )
                else
                  Column(
                    children: [
                      Row(
                        children: [
                          _ColHeader(i18n.t('usage.colAgent'), flex: 3),
                          _ColHeader(
                            i18n.t('common.tokens'),
                            flex: 2,
                            right: true,
                          ),
                          _ColHeader(
                            i18n.t('common.cost'),
                            flex: 2,
                            right: true,
                          ),
                          _ColHeader(
                            i18n.t('compare.costPer1k'),
                            flex: 2,
                            right: true,
                          ),
                          _ColHeader(
                            i18n.t('common.cacheHit'),
                            flex: 2,
                            right: true,
                          ),
                          _ColHeader(
                            i18n.t('common.events'),
                            flex: 2,
                            right: true,
                          ),
                        ],
                      ),
                      const Divider(height: 18),
                      for (final s in sources) ...[
                        _SourceCompareRow(
                          stat: s,
                          onTap: () {
                            ref.read(activeRouteProvider.notifier).state =
                                'agent:${s.key}';
                          },
                        ),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 3. Model & Provider Leaderboards
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth > 860 ? 2 : 1;
              const spacing = 12.0;
              final itemW =
                  (constraints.maxWidth - spacing * (cols - 1)) / cols;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  SizedBox(
                    width: itemW,
                    child: GlassCard(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            i18n.t('dash.byModel'),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: g.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ShareList(
                            maxItems: 10,
                            emptyText: i18n.t('common.noData'),
                            items: models.map((m) {
                              return ShareListItemData(
                                label: m.label,
                                tokens: m.totalTokens,
                                costUsd: m.costUsd,
                                share: m.share,
                                color: g.accentBlue,
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: itemW,
                    child: GlassCard(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            i18n.t('compare.byProvider'),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: g.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ShareList(
                            maxItems: 10,
                            emptyText: i18n.t('common.noData'),
                            items: providers.map((p) {
                              return ShareListItemData(
                                label: p.label,
                                tokens: p.totalTokens,
                                costUsd: p.costUsd,
                                share: p.share,
                                color: g.accentPurple,
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
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

class _ColHeader extends StatelessWidget {
  const _ColHeader(this.label, {required this.flex, this.right = false});

  final String label;
  final int flex;
  final bool right;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    return Expanded(
      flex: flex,
      child: Text(
        label.toUpperCase(),
        textAlign: right ? TextAlign.right : TextAlign.left,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: g.textTertiary,
        ),
      ),
    );
  }
}

class _SourceCompareRow extends StatelessWidget {
  const _SourceCompareRow({
    required this.stat,
    required this.onTap,
  });

  final GroupStat stat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final costPerM = stat.totalTokens > 0
        ? stat.costUsd / (stat.totalTokens / 1e6)
        : 0.0;
    final cacheEff = stat.totals.cacheHitRate;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: AgentBadge(
                  sourceId: stat.key,
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  fmtTokens(stat.totalTokens),
                  textAlign: TextAlign.right,
                  style: GlassTheme.tabularStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: g.textPrimary,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  fmtUsd(stat.costUsd),
                  textAlign: TextAlign.right,
                  style: GlassTheme.tabularStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: g.accentTeal,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  fmtUsd(costPerM),
                  textAlign: TextAlign.right,
                  style: GlassTheme.tabularStyle(
                    fontSize: 12,
                    color: g.textSecondary,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  fmtPct(cacheEff),
                  textAlign: TextAlign.right,
                  style: GlassTheme.tabularStyle(
                    fontSize: 12,
                    color: g.textSecondary,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  fmtInt(stat.events),
                  textAlign: TextAlign.right,
                  style: GlassTheme.tabularStyle(
                    fontSize: 12,
                    color: g.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
