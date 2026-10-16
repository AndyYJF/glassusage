import 'package:flutter/material.dart' hide Page;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/app_format.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/theme/glass_theme.dart';
import '../../domain/models/usage_models.dart';
import '../providers/app_providers.dart';
import '../widgets/charts.dart';
import '../widgets/glass_widgets.dart';

class AgentDetailPage extends ConsumerStatefulWidget {
  const AgentDetailPage({
    super.key,
    required this.sourceId,
  });

  final String sourceId;

  @override
  ConsumerState<AgentDetailPage> createState() => _AgentDetailPageState();
}

class _AgentDetailPageState extends ConsumerState<AgentDetailPage> {
  String? _selectedInstance;
  AgentStats? _stats;
  List<UsageRow> _recentEvents = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAgentData());
  }

  @override
  void didUpdateWidget(covariant AgentDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceId != widget.sourceId) {
      _selectedInstance = null;
      _loadAgentData();
    }
  }

  Future<void> _loadAgentData() async {
    final controller = ref.read(appControllerProvider);
    final client = controller.client;
    if (client == null || !mounted) return;
    setState(() => _loading = true);
    try {
      final preset = ref.read(selectedRangeProvider);
      final (from, to, _) = preset.resolveBounds();
      final results = await Future.wait([
        controller.getAgentStats(widget.sourceId),
        controller.queryUsageLog(
          UsageFilter(
            from: from,
            to: to,
            sources: [widget.sourceId],
            instances:
                _selectedInstance == null ? null : [_selectedInstance!],
          ),
          0,
          25,
        ),
      ]);
      if (mounted) {
        setState(() {
          _stats = results[0] as AgentStats;
          _recentEvents = (results[1] as Page<UsageRow>).rows;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final i18n = ref.watch(i18nProvider);
    final allSources = ref.watch(sourceHealthProvider);

    ref.listen(selectedRangeProvider, (_, _) => _loadAgentData());

    final meta = kSourceMeta[widget.sourceId];
    final brandColor = GlassTheme.sourceColor(widget.sourceId);

    final instancesForAgent =
        allSources.where((h) => h.source == widget.sourceId).toList();

    final totals = _stats?.totals ?? const TokenBreakdown();

    final agentRollup = ref
        .watch(agentRollupProvider)
        .where((r) => r.source == widget.sourceId)
        .firstOrNull;

    final badgeCode = (meta?.label ?? widget.sourceId)
        .substring(
            0, (meta?.label ?? widget.sourceId).length >= 2 ? 2 : 1)
        .toUpperCase();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Agent Hero Header
          GlassCard(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: brandColor.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: brandColor.withValues(alpha: 0.45),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    badgeCode,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: brandColor,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            meta?.label ?? widget.sourceId,
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: g.textPrimary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          if (agentRollup != null)
                            StatusPill(
                              status: agentRollup.status,
                              i18n: i18n,
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        meta?.origin ?? '',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: g.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (instancesForAgent.length > 1)
                  GlassSegmented<String?>(
                    value: _selectedInstance,
                    compact: true,
                    options: [
                      (null, i18n.t('usage.allInstances')),
                      for (final inst in instancesForAgent)
                        (inst.instance, inst.instance),
                    ],
                    onChanged: (val) {
                      setState(() => _selectedInstance = val);
                      _loadAgentData();
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 2. Scoped KPI StatTiles
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth > 800 ? 4 : 2;
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
                      value: fmtTokens(totals.totalTokens),
                      accentColor: brandColor,
                      subtitle:
                          'In ${fmtTokens(totals.inputTokens)} · Out ${fmtTokens(totals.outputTokens)}',
                    ),
                  ),
                  SizedBox(
                    width: itemW,
                    child: StatTile(
                      label: i18n.t('dash.costRange'),
                      value: fmtUsd(totals.costUsd),
                      accentColor: g.accentTeal,
                      subtitle:
                          '${fmtInt(totals.events)} ${i18n.t('common.events')}',
                    ),
                  ),
                  SizedBox(
                    width: itemW,
                    child: StatTile(
                      label: i18n.t('dash.cacheEfficiency'),
                      value: fmtPct(totals.cacheHitRate),
                      accentColor: g.accentPurple,
                      subtitle: 'Read ${fmtTokens(totals.cacheReadTokens)}',
                    ),
                  ),
                  SizedBox(
                    width: itemW,
                    child: StatTile(
                      label: i18n.t('agent.instances'),
                      value: fmtInt(
                        instancesForAgent.isEmpty
                            ? 1
                            : instancesForAgent.length,
                      ),
                      accentColor: g.accentAmber,
                      subtitle: instancesForAgent.isEmpty
                          ? 'local'
                          : instancesForAgent
                              .map((e) => e.instance)
                              .join(', '),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),

          // 3. Instances & Models Breakdown
          LayoutBuilder(
            builder: (context, constraints) {
              final cols = constraints.maxWidth > 820 ? 2 : 1;
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
                            i18n.t('agent.instances'),
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: g.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          for (final inst in instancesForAgent) ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          inst.instance,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                            color: g.textPrimary,
                                          ),
                                        ),
                                        Text(
                                          inst.detectedPaths.isNotEmpty
                                              ? inst.detectedPaths.first
                                              : (meta?.origin ?? ''),
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: g.textTertiary,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${fmtInt(inst.eventCount)} ev',
                                    style: GlassTheme.tabularStyle(
                                      fontSize: 11.5,
                                      color: g.textSecondary,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  StatusPill(
                                    status: inst.status,
                                    i18n: i18n,
                                  ),
                                ],
                              ),
                            ),
                          ],
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
                            i18n.t('agent.topModels'),
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: g.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ShareList(
                            emptyText: i18n.t('common.noData'),
                            items: (_stats?.perModel ?? const []).map((m) {
                              return ShareListItemData(
                                label: m.label,
                                tokens: m.totalTokens,
                                costUsd: m.costUsd,
                                share: m.share,
                                color: brandColor,
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

          // 4. Activity Heatmap
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  i18n.t('agent.activity26w'),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: g.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                CalendarHeatmap(
                  points: _stats?.calendar ?? const [],
                  accentColor: brandColor,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 5. Recent Events for this Agent
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  i18n.t('usage.title'),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: g.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_recentEvents.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
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
                      for (final ev in _recentEvents)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 130,
                                child: Text(
                                  fmtTimestamp(ev.tsMs),
                                  style: GlassTheme.tabularStyle(
                                    fontSize: 11.5,
                                    color: g.textSecondary,
                                  ),
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  ev.modelNorm.isNotEmpty
                                      ? ev.modelNorm
                                      : ev.model,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: g.textPrimary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  AppFormat.projectLabel(ev.project),
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: g.textSecondary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              SizedBox(
                                width: 85,
                                child: Text(
                                  fmtTokens(ev.totalTokens),
                                  textAlign: TextAlign.right,
                                  style: GlassTheme.tabularStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: g.textPrimary,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 70,
                                child: Text(
                                  fmtUsd(ev.costUsd),
                                  textAlign: TextAlign.right,
                                  style: GlassTheme.tabularStyle(
                                    fontSize: 12,
                                    color: g.accentTeal,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
