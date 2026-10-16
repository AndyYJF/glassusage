import 'dart:io';

import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';

class SourceMeta {
  final String id;
  final String label;
  final String origin;
  final bool realtime;

  const SourceMeta({
    required this.id,
    required this.label,
    required this.origin,
    required this.realtime,
  });
}

const Map<String, SourceMeta> kSourceMeta = {
  SourceIds.claude: SourceMeta(
    id: SourceIds.claude,
    label: 'Claude Code',
    origin: '~/.claude/projects/**/*.jsonl',
    realtime: true,
  ),
  SourceIds.codex: SourceMeta(
    id: SourceIds.codex,
    label: 'Codex',
    origin: '~/.codex/sessions/**/*.jsonl',
    realtime: true,
  ),
  SourceIds.cursor: SourceMeta(
    id: SourceIds.cursor,
    label: 'Cursor',
    origin: 'Cursor dashboard API',
    realtime: false,
  ),
  SourceIds.antigravity: SourceMeta(
    id: SourceIds.antigravity,
    label: 'Antigravity',
    origin: 'Antigravity IDE + CLI databases',
    realtime: true,
  ),
  SourceIds.opencode: SourceMeta(
    id: SourceIds.opencode,
    label: 'OpenCode',
    origin: '~/.local/share/opencode storage',
    realtime: true,
  ),
  SourceIds.hermes: SourceMeta(
    id: SourceIds.hermes,
    label: 'Hermes Agent',
    origin: '~/.hermes/state.db',
    realtime: true,
  ),
  SourceIds.openclaw: SourceMeta(
    id: SourceIds.openclaw,
    label: 'OpenClaw',
    origin: '~/.openclaw databases and archives',
    realtime: true,
  ),
  SourceIds.pi: SourceMeta(
    id: SourceIds.pi,
    label: 'Pi',
    origin: '~/.pi/agent/sessions/**/*.jsonl',
    realtime: true,
  ),
  SourceIds.kimi: SourceMeta(
    id: SourceIds.kimi,
    label: 'Kimi Code',
    origin: '~/.kimi-code/sessions/**/wire.jsonl',
    realtime: true,
  ),
  SourceIds.dsh: SourceMeta(
    id: SourceIds.dsh,
    label: 'DeepSeek Harness',
    origin: '~/.dsh/sessions/**/session.vN.jsonl.zstd',
    realtime: true,
  ),
};

String sourceLabel(String id) => kSourceMeta[id]?.label ?? id;

HealthStatus rollupSourceStatus(List<SourceHealth> rows) {
  if (rows.isEmpty) return HealthStatus.missing;
  if (rows.any((r) => r.status == HealthStatus.error)) return HealthStatus.error;
  if (rows.any((r) => r.status == HealthStatus.live)) return HealthStatus.live;
  if (rows.any((r) => r.status == HealthStatus.polling)) {
    return HealthStatus.polling;
  }
  if (rows.any((r) => r.status == HealthStatus.disabled)) {
    return HealthStatus.disabled;
  }
  return HealthStatus.missing;
}

class AppI18n {
  final bool isZh;

  const AppI18n({required this.isZh});

  factory AppI18n.fromSettings(AppSettings settings) {
    if (settings.locale == LocaleMode.zh) return const AppI18n(isZh: true);
    if (settings.locale == LocaleMode.en) return const AppI18n(isZh: false);
    final sys = Platform.localeName.toLowerCase();
    return AppI18n(isZh: sys.startsWith('zh'));
  }

  String t(String key, [Map<String, Object?>? params]) {
    final map = isZh ? _zh : _en;
    var template = map[key] ?? _en[key] ?? key;
    if (params != null) {
      params.forEach((k, v) {
        template = template.replaceAll('{$k}', v?.toString() ?? '');
      });
    }
    return template;
  }

  String statusLabel(HealthStatus s) {
    return switch (s) {
      HealthStatus.live => t('status.live'),
      HealthStatus.polling => t('status.polling'),
      HealthStatus.missing => t('status.missing'),
      HealthStatus.error => t('status.error'),
      HealthStatus.disabled => t('status.disabled'),
    };
  }

  static const Map<String, String> _en = {
    // Navigation
    'nav.overview': 'Overview',
    'nav.dashboard': 'Dashboard',
    'nav.usage': 'Usage Log',
    'nav.compare': 'Compare',
    'nav.agents': 'Agents',
    'nav.settings': 'Settings',
    'nav.miniCard': 'Mini Card',

    // Common
    'common.tokens': 'Tokens',
    'common.cost': 'Cost',
    'common.events': 'Requests',
    'common.input': 'Input',
    'common.output': 'Output',
    'common.cacheRead': 'Cache Read',
    'common.cacheWrite': 'Cache Write',
    'common.reasoning': 'Reasoning',
    'common.cacheHit': 'Cache Hit',
    'common.vsYesterday': 'vs yesterday',
    'common.vsLastWeek': 'vs last week',
    'common.inThisRange': 'in selected range',
    'common.allTime': 'all time',
    'common.rescan': 'Rescan',
    'common.rescanAll': 'Rescan All',
    'common.save': 'Save',
    'common.cancel': 'Cancel',
    'common.delete': 'Delete',
    'common.edit': 'Edit',
    'common.add': 'Add',
    'common.close': 'Close',
    'common.search': 'Search model, project, session...',
    'common.noData': 'No usage data in this time range',
    'common.unpricedNone': 'no price for these models',
    'common.unpricedPartial': 'excludes {count} unpriced',

    // Status
    'status.live': 'Live',
    'status.polling': 'Polling',
    'status.missing': 'Not found',
    'status.error': 'Error',
    'status.disabled': 'Disabled',

    // Ranges
    'range.today': 'Today',
    'range.7d': '7D',
    'range.14d': '14D',
    'range.30d': '30D',
    'range.90d': '90D',
    'range.all': 'All',

    // Dashboard
    'dash.title': 'Token Usage Overview',
    'dash.subtitle': 'Real-time local & remote AI coding agent telemetry',
    'dash.tokensToday': 'Tokens Today',
    'dash.costToday': 'Est. Cost Today',
    'dash.tokensRange': 'Tokens in Range',
    'dash.costRange': 'Est. Cost in Range',
    'dash.thisWeek': 'This Week',
    'dash.cacheEfficiency': 'Cache Hit Rate',
    'dash.activityOverTime': 'Usage Over Time',
    'dash.byAgent': 'By Agent',
    'dash.byModel': 'Top Models',
    'dash.agentStatus': 'Agent Collectors',
    'dash.rescanning': 'Rescanning all sources...',

    // Usage Log
    'usage.title': 'Usage Log',
    'usage.subtitle': 'Inspect, filter, and export individual model calls',
    'usage.allAgents': 'All Agents',
    'usage.allInstances': 'All Instances',
    'usage.allModels': 'All Models',
    'usage.unpricedOnly': 'Unpriced only',
    'usage.exportCsv': 'Export CSV',
    'usage.exportJson': 'Export JSON',
    'usage.exportMonthly': 'Monthly Report',
    'usage.exportedTo': 'Exported to {path}',
    'usage.colTime': 'Time',
    'usage.colAgent': 'Agent',
    'usage.colModel': 'Model',
    'usage.colProject': 'Project',
    'usage.colInput': 'Input',
    'usage.colOutput': 'Output',
    'usage.colCache': 'Cache R/W',
    'usage.colCost': 'Cost',

    // Compare
    'compare.title': 'Compare Agents & Models',
    'compare.subtitle': 'Cross-agent token efficiency, cache hit rate, and model mix',
    'compare.byProvider': 'By Provider',
    'compare.byProject': 'By Project',
    'compare.byInstance': 'By Instance',
    'compare.costPer1k': 'Cost / 1M Tokens',

    // Agent Detail
    'agent.activity26w': '26-Week Activity',
    'agent.topModels': 'Models Used',
    'agent.topProjects': 'Projects',
    'agent.instances': 'Instances',
    'agent.detectedPaths': 'Detected Paths',

    // Settings
    'settings.title': 'Settings',
    'settings.subtitle': 'Customize Liquid Glass appearance, collectors, remote SSH, and pricing',
    'settings.appearance': 'Appearance & Liquid Glass',
    'settings.theme': 'Color Theme',
    'settings.themeSystem': 'System',
    'settings.themeDark': 'Dark',
    'settings.themeLight': 'Light',
    'settings.language': 'Language',
    'settings.material': 'Window Backdrop Material',
    'settings.materialAcrylic': 'Acrylic',
    'settings.materialMica': 'Mica',
    'settings.materialCss': 'Pure Glass',
    'settings.refraction': 'Lens Refraction Strength',
    'settings.animatedBg': 'Animated Mesh Underlay',
    'settings.behavior': 'Desktop & Widget Behavior',
    'settings.autostart': 'Launch at Windows startup',
    'settings.startMinimized': 'Start minimized to system tray',
    'settings.widgetCompact': 'Compact Mini Card mode',
    'settings.widgetAlwaysOnTop': 'Keep Mini Card always on top',
    'settings.shortcut': 'Mini Card Global Shortcut',
    'settings.budget': 'Daily Budget Alerts',
    'settings.budgetEnabled': 'Enable daily budget toast alerts',
    'settings.dailyCostCap': 'Daily Cost Cap (USD)',
    'settings.dailyTokenCap': 'Daily Token Cap',
    'settings.sources': 'Local Agent Collectors',
    'settings.customPath': 'Custom data path override',
    'settings.cursor': 'Cursor Cloud Integration',
    'settings.cursorDesc': 'Encrypted with Windows DPAPI. Paste WorkosCursorSessionToken or Bearer token.',
    'settings.cursorPlaceholder': 'Paste Cursor session cookie or token...',
    'settings.remote': 'Remote SSH Instances (Hermes / OpenClaw)',
    'settings.addRemote': 'Add Remote Host',
    'settings.testConn': 'Test Connection',
    'settings.syncNow': 'Sync Now',
    'settings.pricing': 'LiteLLM Pricing & Overrides',
    'settings.refreshPricing': 'Refresh from LiteLLM',
    'settings.addOverride': 'Add Price Override',
    'settings.openDataDir': 'Open Data Folder',
  };

  static const Map<String, String> _zh = {
    // Navigation
    'nav.overview': '概览',
    'nav.dashboard': '仪表盘',
    'nav.usage': '调用明细',
    'nav.compare': '多维对比',
    'nav.agents': '智能体',
    'nav.settings': '设置',
    'nav.miniCard': '迷你浮窗',

    // Common
    'common.tokens': 'Token 数',
    'common.cost': '费用',
    'common.events': '请求次数',
    'common.input': '输入',
    'common.output': '输出',
    'common.cacheRead': '缓存命中',
    'common.cacheWrite': '缓存写入',
    'common.reasoning': '推理思考',
    'common.cacheHit': '缓存命中率',
    'common.vsYesterday': '较昨日',
    'common.vsLastWeek': '较上周',
    'common.inThisRange': '当前时间段',
    'common.allTime': '全部累计',
    'common.rescan': '重新扫描',
    'common.rescanAll': '全部重扫',
    'common.save': '保存',
    'common.cancel': '取消',
    'common.delete': '删除',
    'common.edit': '编辑',
    'common.add': '添加',
    'common.close': '关闭',
    'common.search': '搜索模型、项目、会话 ID...',
    'common.noData': '当前时间范围内暂无 Token 消耗记录',
    'common.unpricedNone': '暂无对应模型定价',
    'common.unpricedPartial': '不含 {count} 条未定价请求',

    // Status
    'status.live': '实时监听',
    'status.polling': '定时轮询',
    'status.missing': '未检测到',
    'status.error': '异常',
    'status.disabled': '已禁用',

    // Ranges
    'range.today': '今日',
    'range.7d': '近 7 天',
    'range.14d': '近 14 天',
    'range.30d': '近 30 天',
    'range.90d': '近 90 天',
    'range.all': '全部',

    // Dashboard
    'dash.title': 'Token 实时监控总览',
    'dash.subtitle': '本地与远程 AI 编程助手 Token 消耗与成本分析',
    'dash.tokensToday': '今日 Token 消耗',
    'dash.costToday': '今日预估费用',
    'dash.tokensRange': '区间 Token 消耗',
    'dash.costRange': '区间预估费用',
    'dash.thisWeek': '本周累计',
    'dash.cacheEfficiency': '缓存命中率',
    'dash.activityOverTime': '消耗趋势',
    'dash.byAgent': '按智能体分布',
    'dash.byModel': '热门模型排行',
    'dash.agentStatus': '采集器状态',
    'dash.rescanning': '正在后台扫描所有数据源...',

    // Usage Log
    'usage.title': '调用日志明细',
    'usage.subtitle': '按智能体、模型、实例检索与导出原始请求记录',
    'usage.allAgents': '全部智能体',
    'usage.allInstances': '全部实例',
    'usage.allModels': '全部模型',
    'usage.unpricedOnly': '仅看未定价',
    'usage.exportCsv': '导出 CSV',
    'usage.exportJson': '导出 JSON',
    'usage.exportMonthly': '导出月报',
    'usage.exportedTo': '已导出至 {path}',
    'usage.colTime': '时间',
    'usage.colAgent': '智能体',
    'usage.colModel': '模型',
    'usage.colProject': '项目',
    'usage.colInput': '输入',
    'usage.colOutput': '输出',
    'usage.colCache': '缓存读/写',
    'usage.colCost': '费用',

    // Compare
    'compare.title': '多智能体横评对比',
    'compare.subtitle': '对比各工具 Token 成本效率、缓存复用率与模型分布',
    'compare.byProvider': '按供应商',
    'compare.byProject': '按项目',
    'compare.byInstance': '按实例',
    'compare.costPer1k': '每百万 Token 均价',

    // Agent Detail
    'agent.activity26w': '近 26 周活跃热力图',
    'agent.topModels': '常用模型',
    'agent.topProjects': '活跃项目',
    'agent.instances': '实例分布',
    'agent.detectedPaths': '数据目录',

    // Settings
    'settings.title': '系统设置',
    'settings.subtitle': '配置液态玻璃视觉效果、采集目录、远程 SSH 同步与模型定价',
    'settings.appearance': '外观与液态玻璃效果',
    'settings.theme': '主题模式',
    'settings.themeSystem': '跟随系统',
    'settings.themeDark': '深色',
    'settings.themeLight': '浅色',
    'settings.language': '界面语言',
    'settings.material': '窗口背景材质',
    'settings.materialAcrylic': '亚克力 (Acrylic)',
    'settings.materialMica': '云母 (Mica)',
    'settings.materialCss': '纯色玻璃 (Glass)',
    'settings.refraction': '边缘折射强度',
    'settings.animatedBg': '动态流光背景底衬',
    'settings.behavior': '桌面与迷你浮窗行为',
    'settings.autostart': '开机自动启动',
    'settings.startMinimized': '启动时最小化到系统托盘',
    'settings.widgetCompact': '迷你浮窗使用紧凑胶囊模式',
    'settings.widgetAlwaysOnTop': '迷你浮窗始终置顶',
    'settings.shortcut': '迷你浮窗全局快捷键',
    'settings.budget': '每日预算提醒',
    'settings.budgetEnabled': '启用每日预算超额提醒',
    'settings.dailyCostCap': '每日费用上限 (USD)',
    'settings.dailyTokenCap': '每日 Token 上限',
    'settings.sources': '本地智能体数据源',
    'settings.customPath': '自定义数据路径（留空使用默认）',
    'settings.cursor': 'Cursor 云端账单接入',
    'settings.cursorDesc': '使用 Windows DPAPI 加密存储，支持粘贴 WorkosCursorSessionToken 或 Bearer Token。',
    'settings.cursorPlaceholder': '粘贴 Cursor Session Cookie 或 Token...',
    'settings.remote': '远程 SSH 实例同步 (Hermes / OpenClaw)',
    'settings.addRemote': '添加远程主机',
    'settings.testConn': '测试连接',
    'settings.syncNow': '立即同步',
    'settings.pricing': 'LiteLLM 模型价格表与自定义覆盖',
    'settings.refreshPricing': '从 LiteLLM 更新价格表',
    'settings.addOverride': '添加自定义价格',
    'settings.openDataDir': '打开数据目录',
  };
}
