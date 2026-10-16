import 'dart:io';

import 'package:flutter/material.dart' hide Page;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/format/app_format.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/theme/glass_theme.dart';
import '../../core/window/desktop_window_manager.dart';
import '../../domain/models/usage_models.dart';
import '../providers/app_providers.dart';
import '../widgets/glass_widgets.dart';

class UsagePage extends ConsumerStatefulWidget {
  const UsagePage({super.key});

  @override
  ConsumerState<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends ConsumerState<UsagePage> {
  static const int _pageSize = 50;

  String? _selectedSource;
  String? _selectedInstance;
  String? _selectedModel;
  bool _unpricedOnly = false;
  final TextEditingController _searchController = TextEditingController();

  int _pageIndex = 0;
  bool _loading = false;
  String? _statusMessage;
  Page<UsageRow> _page = const Page(
    rows: [],
    total: 0,
    page: 0,
    pageSize: _pageSize,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadEvents());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  UsageFilter _buildFilter() {
    final preset = ref.read(selectedRangeProvider);
    final (from, to, _) = preset.resolveBounds();
    final q = _searchController.text.trim();
    return UsageFilter(
      from: from,
      to: to,
      sources: _selectedSource == null ? null : [_selectedSource!],
      instances: _selectedInstance == null ? null : [_selectedInstance!],
      models: _selectedModel == null ? null : [_selectedModel!],
      search: q.isEmpty ? null : q,
      unpricedOnly: _unpricedOnly ? true : null,
    );
  }

  Future<void> _loadEvents({bool resetPage = false}) async {
    if (resetPage) _pageIndex = 0;
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final page = await ref.read(appControllerProvider).queryUsageLog(
            _buildFilter(),
            _pageIndex,
            _pageSize,
          );
      if (mounted) {
        setState(() {
          _page = page;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleExport(String format) async {
    try {
      final dataDir = ref.read(dataDirProvider);
      final ext = format == 'json' ? 'json' : 'csv';
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outPath = p.join(
        dataDir.isNotEmpty ? dataDir : Directory.systemTemp.path,
        'glassusage-$format-$ts.$ext',
      );
      final savedPath = await ref.read(appControllerProvider).exportData(
            filter: _buildFilter(),
            format: format,
            path: outPath,
          );
      if (mounted) {
        final i18n = ref.read(i18nProvider);
        setState(
          () => _statusMessage =
              i18n.t('usage.exportedTo', {'path': savedPath}),
        );
      }
      await DesktopWindowManager.instance.openDataDir(p.dirname(savedPath));
    } catch (e) {
      if (mounted) {
        setState(() => _statusMessage = 'Export failed: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final i18n = ref.watch(i18nProvider);
    final filters = ref.watch(filterOptionsProvider);

    // Reload when global range changes
    ref.listen(selectedRangeProvider, (_, _) => _loadEvents(resetPage: true));
    ref.listen(overviewStatsProvider, (_, _) => _loadEvents());

    final totalPages =
        _page.total == 0 ? 1 : ((_page.total + _pageSize - 1) ~/ _pageSize);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Filter & Export Bar
          GlassCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _FilterDropdown(
                      label: i18n.t('usage.allAgents'),
                      value: _selectedSource,
                      items: [
                        for (final s in filters.source)
                          (s, kSourceMeta[s]?.label ?? s),
                      ],
                      onChanged: (v) {
                        setState(() => _selectedSource = v);
                        _loadEvents(resetPage: true);
                      },
                    ),
                    _FilterDropdown(
                      label: i18n.t('usage.allInstances'),
                      value: _selectedInstance,
                      items: [
                        for (final inst in filters.instance) (inst, inst),
                      ],
                      onChanged: (v) {
                        setState(() => _selectedInstance = v);
                        _loadEvents(resetPage: true);
                      },
                    ),
                    _FilterDropdown(
                      label: i18n.t('usage.allModels'),
                      value: _selectedModel,
                      items: [for (final m in filters.modelNorm) (m, m)],
                      onChanged: (v) {
                        setState(() => _selectedModel = v);
                        _loadEvents(resetPage: true);
                      },
                    ),
                    SizedBox(
                      width: 220,
                      height: 33,
                      child: TextField(
                        controller: _searchController,
                        onSubmitted: (_) => _loadEvents(resetPage: true),
                        style: TextStyle(fontSize: 12, color: g.textPrimary),
                        decoration: InputDecoration(
                          hintText: i18n.t('common.search'),
                          hintStyle:
                              TextStyle(fontSize: 12, color: g.textTertiary),
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            size: 15,
                            color: g.textTertiary,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 0,
                          ),
                          filled: true,
                          fillColor: g.glassSurface,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide: BorderSide(color: g.glassBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide: BorderSide(color: g.accentBlue),
                          ),
                        ),
                      ),
                    ),
                    GlassButton(
                      label: i18n.t('usage.unpricedOnly'),
                      compact: true,
                      variant: _unpricedOnly
                          ? GlassButtonVariant.primary
                          : GlassButtonVariant.secondary,
                      onPressed: () {
                        setState(() => _unpricedOnly = !_unpricedOnly);
                        _loadEvents(resetPage: true);
                      },
                    ),
                    GlassButton(
                      label: i18n.t('usage.exportCsv'),
                      icon: Icons.download_rounded,
                      compact: true,
                      onPressed: () => _handleExport('csv'),
                    ),
                    GlassButton(
                      label: i18n.t('usage.exportJson'),
                      icon: Icons.data_object_rounded,
                      compact: true,
                      onPressed: () => _handleExport('json'),
                    ),
                    GlassButton(
                      label: i18n.t('usage.exportMonthly'),
                      icon: Icons.calendar_month_rounded,
                      compact: true,
                      onPressed: () => _handleExport('monthly'),
                    ),
                  ],
                ),
                if (_statusMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _statusMessage!,
                    style: TextStyle(fontSize: 11.5, color: g.accentTeal),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 2. Filtered Summary Strip + Pagination Controls
          Row(
            children: [
              Text(
                '${fmtInt(_page.total)} ${i18n.t('common.events')}',
                style: GlassTheme.tabularStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: g.textSecondary,
                ),
              ),
              const Spacer(),
              GlassButton(
                label: '←',
                compact: true,
                onPressed: _pageIndex > 0
                    ? () {
                        setState(() => _pageIndex--);
                        _loadEvents();
                      }
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '${_pageIndex + 1} / $totalPages',
                  style: GlassTheme.tabularStyle(
                    fontSize: 12,
                    color: g.textSecondary,
                  ),
                ),
              ),
              GlassButton(
                label: '→',
                compact: true,
                onPressed: (_pageIndex + 1) < totalPages
                    ? () {
                        setState(() => _pageIndex++);
                        _loadEvents();
                      }
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 10),

          // 3. Virtualized Event Table (ListView.builder — zero BackdropFilter on rows)
          Expanded(
            child: GlassCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  // Header row
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: g.glassBorder),
                      ),
                    ),
                    child: Row(
                      children: [
                        _HeaderCell(i18n.t('usage.colTime'), flex: 2),
                        _HeaderCell(i18n.t('usage.colAgent'), flex: 2),
                        _HeaderCell(i18n.t('usage.colModel'), flex: 3),
                        _HeaderCell(i18n.t('usage.colProject'), flex: 2),
                        _HeaderCell(
                          i18n.t('usage.colInput'),
                          flex: 1,
                          alignRight: true,
                        ),
                        _HeaderCell(
                          i18n.t('usage.colOutput'),
                          flex: 1,
                          alignRight: true,
                        ),
                        _HeaderCell(
                          i18n.t('usage.colCache'),
                          flex: 1,
                          alignRight: true,
                        ),
                        _HeaderCell(
                          i18n.t('common.tokens'),
                          flex: 1,
                          alignRight: true,
                        ),
                        _HeaderCell(
                          i18n.t('usage.colCost'),
                          flex: 1,
                          alignRight: true,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _page.rows.isEmpty
                            ? Center(
                                child: Text(
                                  i18n.t('common.noData'),
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: g.textTertiary,
                                  ),
                                ),
                              )
                            : ListView.builder(
                                itemCount: _page.rows.length,
                                itemExtent: 40,
                                itemBuilder: (context, index) {
                                  final ev = _page.rows[index];
                                  return _EventRow(event: ev);
                                },
                              ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell(
    this.text, {
    required this.flex,
    this.alignRight = false,
  });

  final String text;
  final int flex;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    return Expanded(
      flex: flex,
      child: Text(
        text.toUpperCase(),
        textAlign: alignRight ? TextAlign.right : TextAlign.left,
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

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final UsageRow event;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    final cacheTokens = event.cacheReadTokens + event.cacheWriteTokens;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: g.glassBorder.withValues(alpha: 0.4),
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              fmtTimestamp(event.tsMs),
              style: GlassTheme.tabularStyle(
                fontSize: 11.5,
                color: g.textSecondary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: AgentBadge(
              sourceId: event.source,
              instanceLabel: event.instance,
              fontSize: 11.5,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              event.modelNorm.isNotEmpty ? event.modelNorm : event.model,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: g.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              AppFormat.projectLabel(event.project),
              style: TextStyle(fontSize: 11.5, color: g.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              fmtTokens(event.inputTokens),
              textAlign: TextAlign.right,
              style: GlassTheme.tabularStyle(
                fontSize: 11.5,
                color: g.textSecondary,
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              fmtTokens(event.outputTokens),
              textAlign: TextAlign.right,
              style: GlassTheme.tabularStyle(
                fontSize: 11.5,
                color: g.textSecondary,
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              fmtTokens(cacheTokens),
              textAlign: TextAlign.right,
              style: GlassTheme.tabularStyle(
                fontSize: 11.5,
                color: g.textTertiary,
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              fmtTokens(event.totalTokens),
              textAlign: TextAlign.right,
              style: GlassTheme.tabularStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: g.textPrimary,
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(
              fmtUsd(event.costUsd),
              textAlign: TextAlign.right,
              style: GlassTheme.tabularStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: event.unpriced ? g.textTertiary : g.accentTeal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final List<(String, String)> items;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final g = GlassTheme.of(context);
    return Container(
      height: 33,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: g.glassSurface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: g.glassBorder),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: items.any((it) => it.$1 == value) ? value : null,
          hint: Text(
            label,
            style: TextStyle(fontSize: 12, color: g.textSecondary),
          ),
          dropdownColor:
              g.isDark ? const Color(0xFF151928) : const Color(0xFFF6F8FC),
          icon: Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 16,
            color: g.textSecondary,
          ),
          style: TextStyle(fontSize: 12, color: g.textPrimary),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text(label),
            ),
            for (final (id, name) in items)
              DropdownMenuItem<String?>(
                value: id,
                child: Text(name),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}
