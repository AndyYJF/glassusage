import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/app_format.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/theme/glass_theme.dart';
import '../providers/app_providers.dart';
import '../widgets/charts.dart';
import '../widgets/glass_widgets.dart';
import '../widgets/odometer.dart';

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  bool _showCostSeries = false;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final i18n = ref.watch(i18nProvider);
    final overview = ref.watch(overviewStatsProvider);
    final series = ref.watch(seriesPointsProvider);
    final models = ref.watch(modelStatsProvider);
    final projects = ref.watch(projectStatsProvider);
    final agentRollups = ref.watch(agentRollupProvider);

    final rangeTotals = overview?.range;
    final todayTotals = overview?.today;
    final yesterdayTotals = overview?.yesterday;
    final weekTotals = overview?.thisWeek;
    final lastWeekTotals = overview?.lastWeek;

    final todayDelta = AppFormat.delta(
      todayTotals?.totalTokens ?? 0,
      yesterdayTotals?.totalTokens ?? 0,
    );
    final weekDelta = AppFormat.delta(
      weekTotals?.totalTokens ?? 0,
      lastWeekTotals?.totalTokens ?? 0,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Live Telemetry Hero Card (isolated 1 Hz listener)
          const _LiveTelemetryBanner(),
          const SizedBox(height: 16),

          // 2. Four KPI Stat Tiles
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth > 820 ? 4 : 2;
              const spacing = 12.0;
              final itemW =
                  (constraints.maxWidth - spacing * (cols - 1)) / cols;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  SizedBox(
                    width: itemW,
                    child: StatTile(
                      label: i18n.t('dash.tokensRange'),
                      value: fmtTokens(rangeTotals?.totalTokens ?? 0),
                      deltaPct: todayDelta,
                      accentColor: g.accentBlue,
                      subtitle:
                          '${i18n.t('common.input')} ${fmtTokens(rangeTotals?.inputTokens ?? 0)} · ${i18n.t('common.output')} ${fmtTokens(rangeTotals?.outputTokens ?? 0)}',
                    ),
                  ),
                  SizedBox(
                    width: itemW,
                    child: StatTile(
                      label: i18n.t('dash.costRange'),
                      value: fmtUsd(rangeTotals?.costUsd ?? 0),
                      deltaPct: weekDelta,
                      accentColor: g.accentTeal,
                      subtitle:
                          '${fmtInt(rangeTotals?.events ?? 0)} ${i18n.t('common.events')}',
                    ),
                  ),
                  SizedBox(
                    width: itemW,
                    child: StatTile(
                      label: i18n.t('dash.cacheEfficiency'),
                      value: fmtPct(rangeTotals?.cacheHitRate ?? 0),
                      accentColor: g.accentPurple,
                      subtitle:
                          '${i18n.t('common.cacheRead')} ${fmtTokens(rangeTotals?.cacheReadTokens ?? 0)}',
                    ),
                  ),
                  SizedBox(
                    width: itemW,
                    child: StatTile(
                      label: i18n.t('dash.thisWeek'),
                      value: fmtTokens(weekTotals?.totalTokens ?? 0),
                      accentColor: g.accentPink,
                      subtitle:
                          '${fmtUsd(weekTotals?.costUsd ?? 0)} · ${i18n.t('common.cacheWrite')} ${fmtTokens(rangeTotals?.cacheWriteTokens ?? 0)}',
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),

          // 3. Time-Series Usage Chart Card
          GlassCard(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        i18n.t('dash.activityOverTime'),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: g.textPrimary,
                        ),
                      ),
                    ),
                    GlassSegmented<bool>(
                      value: _showCostSeries,
                      compact: true,
                      options: [
                        (false, i18n.t('common.tokens')),
                        (true, i18n.t('common.cost')),
                      ],
                      onChanged: (v) => setState(() => _showCostSeries = v),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                UsageChart(
                  bucket: ref.watch(selectedRangeProvider).resolveBounds().$3,
                  points: series,
                  showCost: _showCostSeries,
                  accentColor: _showCostSeries ? g.accentTeal : g.accentBlue,
                  height: 220,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 4. Breakdown Columns: By Agent / By Model / Top Projects
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth > 900 ? 3 : 1;
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            i18n.t('dash.byAgent'),
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: g.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ShareList(
                            emptyText: i18n.t('common.noData'),
                            items:
                                (overview?.perSource ?? const []).map((s) {
                                  final meta = kSourceMeta[s.key];
                                  return ShareListItemData(
                                    label: meta?.label ?? s.label,
                                    tokens: s.totalTokens,
                                    costUsd: s.costUsd,
                                    share: s.share,
                                    color: GlassTheme.sourceColor(s.key),
                                    onTap: () {
                                      ref
                                          .read(activeRouteProvider.notifier)
                                          .state = 'agent:${s.key}';
                                    },
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            i18n.t('dash.byModel'),
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: g.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ShareList(
                            emptyText: i18n.t('common.noData'),
                            items:
                                models.map((m) {
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            i18n.t('compare.byProject'),
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: g.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ShareList(
                            emptyText: i18n.t('common.noData'),
                            items:
                                projects.map((p) {
                                  return ShareListItemData(
                                    label: AppFormat.projectLabel(p.label),
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
          const SizedBox(height: 16),

          // 5. Agent Fleet Status Grid
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  i18n.t('dash.agentStatus'),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: g.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final cols =
                        constraints.maxWidth > 920
                            ? 5
                            : (constraints.maxWidth > 580 ? 3 : 2);
                    const spacing = 10.0;
                    final itemW =
                        (constraints.maxWidth - spacing * (cols - 1)) / cols;
                    return Wrap(
                      spacing: spacing,
                      runSpacing: spacing,
                      children: [
                        for (final agent in agentRollups)
                          SizedBox(
                            width: itemW,
                            child: GlassCard(
                              padding: const EdgeInsets.all(12),
                              borderRadius: 13,
                              onTap: () {
                                ref.read(activeRouteProvider.notifier).state =
                                    'agent:${agent.source}';
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: AgentBadge(
                                          sourceId: agent.source,
                                          fontSize: 12,
                                        ),
                                      ),
                                      StatusPill(
                                        status: agent.status,
                                        i18n: i18n,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${fmtInt(agent.eventCount)} ${i18n.t('common.events')}',
                                    style: GlassTheme.tabularStyle(
                                      fontSize: 11.5,
                                      color: g.textSecondary,
                                    ),
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
          ),
        ],
      ),
    );
  }
}

/// Narrowly scoped widget that watches `liveRatesProvider` at 1 Hz without
/// rebuilding the rest of `DashboardPage` (Anti-Jank Rule #5).
class _LiveTelemetryBanner extends ConsumerWidget {
  const _LiveTelemetryBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = GlassTheme.of(context);
    final i18n = ref.watch(i18nProvider);
    final live = ref.watch(liveRatesProvider);
    final activeSources =
        live.perSource.where((s) => s.active).map((s) => s.source).toList();

    return GlassCard(
      elevated: true,
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color:
                            activeSources.isNotEmpty ? g.success : g.accentBlue,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: (activeSources.isNotEmpty
                                    ? g.success
                                    : g.accentBlue)
                                .withValues(alpha: 0.6),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      i18n.t('dash.title').toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: g.textSecondary,
                      ),
                    ),
                    if (activeSources.isNotEmpty) ...[
                      const SizedBox(width: 10),
                      for (final src in activeSources.take(3))
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: AgentBadge(sourceId: src, fontSize: 11),
                        ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 28,
                  runSpacing: 10,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Odometer(
                          value: live.tpm,
                          formatter: (v) => fmtTokens(v.round()),
                          fontSize: 26,
                        ),
                        Text(
                          'Tokens / min',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: g.textTertiary,
                          ),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Odometer(
                          value: live.rpm,
                          formatter: (v) => v.toStringAsFixed(1),
                          fontSize: 26,
                          color: g.accentTeal,
                        ),
                        Text(
                          'Requests / min',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: g.textTertiary,
                          ),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${fmtTokens(live.tokensToday)} · ${fmtUsd(live.costToday)}',
                          style: GlassTheme.tabularStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: g.textPrimary,
                          ),
                        ),
                        Text(
                          i18n.t('dash.tokensToday'),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: g.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            flex: 2,
            child: Sparkline(
              values: live.spark60,
              color: g.accentBlue,
              height: 56,
            ),
          ),
        ],
      ),
    );
  }
}
