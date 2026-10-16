import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Page;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/i18n/app_i18n.dart';
import '../../core/window/win32_bridge.dart';
import '../../data/isolate/usage_service_client.dart';
import '../../data/pricing/pricing_service.dart';
import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';

enum RangePreset {
  today,
  d7,
  d14,
  d30,
  d90,
  all;

  (int from, int to, String bucket) resolveBounds() {
    final now = DateTime.now();
    final endMs = now.millisecondsSinceEpoch;
    final startOfToday = DateTime(now.year, now.month, now.day);
    return switch (this) {
      RangePreset.today => (startOfToday.millisecondsSinceEpoch, endMs, 'hour'),
      RangePreset.d7 => (
        startOfToday.subtract(const Duration(days: 6)).millisecondsSinceEpoch,
        endMs,
        'day',
      ),
      RangePreset.d14 => (
        startOfToday.subtract(const Duration(days: 13)).millisecondsSinceEpoch,
        endMs,
        'day',
      ),
      RangePreset.d30 => (
        startOfToday.subtract(const Duration(days: 29)).millisecondsSinceEpoch,
        endMs,
        'day',
      ),
      RangePreset.d90 => (
        startOfToday.subtract(const Duration(days: 89)).millisecondsSinceEpoch,
        endMs,
        'day',
      ),
      RangePreset.all => (0, endMs, 'month'),
    };
  }
}

class AgentRollupSummary {
  final String source;
  final HealthStatus status;
  final int eventCount;
  final int instanceCount;

  const AgentRollupSummary({
    required this.source,
    required this.status,
    required this.eventCount,
    required this.instanceCount,
  });
}

String _resolveDefaultDataDir() {
  final appData =
      Platform.environment['APPDATA'] ??
      Platform.environment['LOCALAPPDATA'] ??
      Directory.systemTemp.path;
  final dir = Directory(p.join(appData, 'com.glassusage.desktop'));
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  return dir.path;
}

// ─── Fine-Grained UI State Providers (Anti-Jank Rule #5) ────────────────────

/// Whether the window is currently visible (used by TickerMode to pause animations when hidden).
final isWindowVisibleProvider = StateProvider<bool>((ref) => true);

/// Active navigation route: 'dashboard', 'usage', 'compare', 'agent:<source>', 'settings'.
final activeRouteProvider = StateProvider<String>((ref) => 'dashboard');

/// Whether the window is currently in MiniCard floating widget mode.
final isMiniCardModeProvider = StateProvider<bool>((ref) => false);

/// Currently selected time range preset.
final selectedRangeProvider = StateProvider<RangePreset>(
  (ref) => RangePreset.d7,
);

/// 1 Hz Live telemetry rates. Watched ONLY by Odometer, Sparkline, header badge, and MiniCardView.
final liveRatesProvider = StateProvider<LiveRates>((ref) => const LiveRates());

/// Current application settings.
final appSettingsProvider = StateProvider<AppSettings>((ref) => AppSettings());

/// Current overview statistics for selectedRangeProvider.
final overviewStatsProvider = StateProvider<OverviewStats?>((ref) => null);

/// Top models breakdown for selectedRangeProvider.
final modelStatsProvider = StateProvider<List<GroupStat>>((ref) => const []);

/// Top projects breakdown for selectedRangeProvider.
final projectStatsProvider = StateProvider<List<GroupStat>>((ref) => const []);

/// Provider breakdown for selectedRangeProvider.
final providerStatsProvider = StateProvider<List<GroupStat>>((ref) => const []);

/// Current time-series buckets for selectedRangeProvider.
final seriesPointsProvider = StateProvider<List<SeriesPoint>>(
  (ref) => const [],
);

/// Current per-source & per-instance health list.
final sourceHealthProvider = StateProvider<List<SourceHealth>>(
  (ref) => const [],
);

/// Rolled-up 10-agent status list derived from sourceHealthProvider.
final agentRollupProvider = Provider<List<AgentRollupSummary>>((ref) {
  final sources = ref.watch(sourceHealthProvider);
  return SourceIds.all.map((id) {
    final rows = sources.where((s) => s.source == id).toList();
    final status = rollupSourceStatus(rows);
    final events = rows.fold<int>(0, (sum, r) => sum + r.eventCount);
    return AgentRollupSummary(
      source: id,
      status: status,
      eventCount: events,
      instanceCount: rows.isEmpty ? 1 : rows.length,
    );
  }).toList();
});

/// Available filter dropdown options (source, provider, modelNorm, instance).
final filterOptionsProvider = StateProvider<FilterOptions>(
  (ref) => const FilterOptions(),
);

/// Configured remote SSH instances.
final remoteInstancesProvider = StateProvider<List<RemoteInstance>>(
  (ref) => const [],
);

/// Pricing catalog metadata and user overrides.
final pricingInfoProvider = StateProvider<PricingInfo?>((ref) => null);

/// Cursor API token status.
final cursorStatusProvider = StateProvider<CursorStatus>(
  (ref) => const CursorStatus(hasAccessToken: false, hasCookie: false),
);

/// Application data directory path.
final dataDirProvider = StateProvider<String>(
  (ref) => _resolveDefaultDataDir(),
);

/// Whether a manual/initial scan is currently in progress.
final isRescanningProvider = StateProvider<bool>((ref) => false);

/// Whether the first-launch onboarding modal should be displayed.
final showOnboardingProvider = StateProvider<bool>((ref) => false);

/// Resolved I18n dictionary based on appSettingsProvider.locale.
final i18nProvider = Provider<AppI18n>((ref) {
  final settings = ref.watch(appSettingsProvider);
  return AppI18n.fromSettings(settings);
});

/// AppController singleton provider.
final appControllerProvider = Provider<AppController>((ref) {
  final controller = AppController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

class AppController {
  AppController(this.ref);

  final Ref ref;
  UsageServiceClient? _client;
  StreamSubscription<LiveRates>? _liveSub;
  StreamSubscription<Map<String, dynamic>>? _usageUpdatedSub;
  StreamSubscription<Map<String, dynamic>>? _sourceStatusSub;
  StreamSubscription<String>? _win32EventSub;
  bool _initialized = false;
  int _rangeRequest = 0;

  UsageServiceClient? get client => _client;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    _win32EventSub = Win32Bridge.instance.events.listen(_handleWin32Event);

    final dataDir = ref.read(dataDirProvider);
    final client = UsageServiceClient(dataDir: dataDir);
    await client.start();
    _client = client;

    // 1. Load initial settings, cursor status, remotes, pricing
    final results = await Future.wait([
      client.getSettings(),
      client.getCursorStatus(),
      client.listRemoteInstances(),
      client.getPricingInfo(),
    ]);

    final settings = results[0] as AppSettings;
    final cursorStatus = results[1] as CursorStatus;
    final remotes = results[2] as List<RemoteInstance>;
    final pricing = results[3] as PricingInfo;

    ref.read(appSettingsProvider.notifier).state = settings;
    ref.read(cursorStatusProvider.notifier).state = cursorStatus;
    ref.read(remoteInstancesProvider.notifier).state = remotes;
    ref.read(pricingInfoProvider.notifier).state = pricing;

    if (!settings.firstRunDone) {
      ref.read(showOnboardingProvider.notifier).state = true;
    }

    _applyWindowAppearance(settings);

    // 2. Subscribe to background isolate streams
    _liveSub = client.onLiveTick.listen((rates) {
      if (ref.read(isWindowVisibleProvider)) {
        ref.read(liveRatesProvider.notifier).state = rates;
      }
    });

    _sourceStatusSub = client.onSourceStatus.listen((_) {
      refreshSourcesAndRemotes();
    });

    _usageUpdatedSub = client.onUsageUpdated.listen((_) {
      refreshRangeData();
    });

    // 3. Load initial overview, timeseries, sources, filters, live rates
    await Future.wait([
      refreshRangeData(),
      refreshSourcesAndRemotes(),
      client.getLiveRates().then((rates) {
        ref.read(liveRatesProvider.notifier).state = rates;
      }),
    ]);
  }

  void _handleWin32Event(String event) {
    switch (event) {
      case 'window:hidden':
        ref.read(isWindowVisibleProvider.notifier).state = false;
        break;
      case 'window:visible':
        ref.read(isWindowVisibleProvider.notifier).state = true;
        refreshRangeData();
        break;
      case 'tray:open':
        ref.read(isWindowVisibleProvider.notifier).state = true;
        if (ref.read(isMiniCardModeProvider)) {
          setWidgetMode(false);
        }
        refreshRangeData();
        break;
      case 'tray:widget':
        ref.read(isWindowVisibleProvider.notifier).state = true;
        setWidgetMode(!ref.read(isMiniCardModeProvider));
        break;
      case 'tray:rescan':
        rescanNow();
        break;
      case 'hotkey:toggle':
        ref.read(isWindowVisibleProvider.notifier).state = true;
        setWidgetMode(!ref.read(isMiniCardModeProvider));
        break;
    }
  }

  void _applyWindowAppearance(AppSettings settings) {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final isDark = switch (settings.theme) {
      ThemeModeSetting.dark => true,
      ThemeModeSetting.light => false,
      ThemeModeSetting.system => brightness == Brightness.dark,
    };
    Win32Bridge.instance.applyMaterial(settings.material, isDark: isDark);
  }

  Future<void> refreshRangeData() async {
    final client = _client;
    if (client == null) return;
    final request = ++_rangeRequest;
    final preset = ref.read(selectedRangeProvider);
    final (from, to, bucket) = preset.resolveBounds();
    final filter = UsageFilter(from: from, to: to);

    final results = await Future.wait([
      client.getOverview(from, to),
      client.getTimeseries(
        from: from,
        to: to,
        bucket: bucket,
        groupBy: 'source',
      ),
      client.getModelStats(filter),
      client.getGroupStats('project', filter),
      client.getProviderStats(filter),
      client.getFilterOptions(),
    ]);

    if (request != _rangeRequest ||
        _client != client ||
        preset != ref.read(selectedRangeProvider)) {
      return;
    }
    ref.read(overviewStatsProvider.notifier).state =
        results[0] as OverviewStats;
    ref.read(seriesPointsProvider.notifier).state =
        results[1] as List<SeriesPoint>;
    ref.read(modelStatsProvider.notifier).state = results[2] as List<GroupStat>;
    ref.read(projectStatsProvider.notifier).state =
        results[3] as List<GroupStat>;
    ref.read(providerStatsProvider.notifier).state =
        results[4] as List<GroupStat>;
    ref.read(filterOptionsProvider.notifier).state =
        results[5] as FilterOptions;
  }

  Future<void> refreshSourcesAndRemotes() async {
    final client = _client;
    if (client == null) return;
    final results = await Future.wait([
      client.getSourceHealth(),
      client.listRemoteInstances(),
    ]);
    ref.read(sourceHealthProvider.notifier).state =
        results[0] as List<SourceHealth>;
    ref.read(remoteInstancesProvider.notifier).state =
        results[1] as List<RemoteInstance>;
  }

  Future<void> setRange(RangePreset preset) async {
    if (ref.read(selectedRangeProvider) == preset) return;
    ref.read(selectedRangeProvider.notifier).state = preset;
    await refreshRangeData();
  }

  Future<void> rescanNow() async {
    final client = _client;
    if (client == null || ref.read(isRescanningProvider)) return;
    ref.read(isRescanningProvider.notifier).state = true;
    try {
      final health = await client.rescanAll();
      ref.read(sourceHealthProvider.notifier).state = health;
      await refreshRangeData();
    } finally {
      ref.read(isRescanningProvider.notifier).state = false;
    }
  }

  Future<void> patchSettings(Map<String, dynamic> patch) async {
    final prev = ref.read(appSettingsProvider);
    final next = prev.copyWithPatch(patch);
    ref.read(appSettingsProvider.notifier).state = next;
    _applyWindowAppearance(next);

    if (prev.autostart != next.autostart) {
      await Win32Bridge.instance.setAutostart(next.autostart);
    }
    if ((prev.widgetCompact != next.widgetCompact ||
            prev.widgetAlwaysOnTop != next.widgetAlwaysOnTop) &&
        ref.read(isMiniCardModeProvider)) {
      Win32Bridge.instance.setWidgetMode(
        true,
        compact: next.widgetCompact,
        alwaysOnTop: next.widgetAlwaysOnTop,
      );
    }

    final client = _client;
    if (client != null) {
      await client.setSettings(next);
    }
  }

  void setWidgetMode(bool enabled) {
    final cur = ref.read(appSettingsProvider);
    ref.read(isMiniCardModeProvider.notifier).state = enabled;
    Win32Bridge.instance.setWidgetMode(
      enabled,
      compact: cur.widgetCompact,
      alwaysOnTop: cur.widgetAlwaysOnTop,
    );
  }

  Future<void> setCompactWidget(bool compact) async {
    await patchSettings({'widgetCompact': compact});
  }

  Future<void> completeOnboarding() async {
    ref.read(showOnboardingProvider.notifier).state = false;
    await patchSettings({'firstRunDone': true});
  }

  Future<void> saveCursorToken(String token) async {
    final client = _client;
    if (client == null) return;
    await client.setCursorCookie(token);
    await client.syncCursorNow();
    final status = await client.getCursorStatus();
    ref.read(cursorStatusProvider.notifier).state = status;
    await Future.wait([refreshRangeData(), refreshSourcesAndRemotes()]);
  }

  Future<void> refreshPricing() async {
    final client = _client;
    if (client == null) return;
    await client.refreshPricing();
    final info = await client.getPricingInfo();
    ref.read(pricingInfoProvider.notifier).state = info;
    await refreshRangeData();
  }

  Future<void> savePricingOverride(
    String pattern,
    ModelPrice overridePrice,
  ) async {
    final client = _client;
    if (client == null) return;
    final current = ref.read(pricingInfoProvider)?.overrides ?? {};
    final nextOverrides = Map<String, ModelPrice>.from(current)
      ..[pattern] = overridePrice;
    final info = await client.setPricingOverrides(nextOverrides);
    ref.read(pricingInfoProvider.notifier).state = info;
    await refreshRangeData();
  }

  Future<void> deletePricingOverride(String pattern) async {
    final client = _client;
    if (client == null) return;
    final info = await client.removePricingOverride(pattern);
    ref.read(pricingInfoProvider.notifier).state = info;
    await refreshRangeData();
  }

  Future<void> upsertRemoteInstance(RemoteInstanceInput input) async {
    final client = _client;
    if (client == null) return;
    final updated = await client.upsertRemoteInstance(input);
    ref.read(remoteInstancesProvider.notifier).state = updated;
    await refreshSourcesAndRemotes();
    unawaited(syncRemoteInstance(input.name.trim()).catchError((_) => 0));
  }

  Future<void> deleteRemoteInstance(
    String name, {
    bool purgeData = true,
  }) async {
    final client = _client;
    if (client == null) return;
    final updated = await client.deleteRemoteInstance(name, purgeData);
    ref.read(remoteInstancesProvider.notifier).state = updated;
    await Future.wait([refreshRangeData(), refreshSourcesAndRemotes()]);
  }

  Future<int> syncRemoteInstance(String name) async {
    final client = _client!;
    final count = await client.syncRemoteInstance(name);
    await Future.wait([refreshRangeData(), refreshSourcesAndRemotes()]);
    return count;
  }

  Future<TestReport> testRemoteInstance(RemoteInstanceInput input) async {
    final client = _client!;
    return client.testRemoteInstance(input);
  }

  Future<Page<UsageRow>> queryUsageLog(
    UsageFilter filter,
    int page,
    int pageSize,
  ) async {
    final client = _client;
    if (client == null) {
      return Page(rows: const [], total: 0, page: page, pageSize: pageSize);
    }
    return client.getUsageLog(filter, page, pageSize);
  }

  Future<AgentStats> getAgentStats(String source, {String? instance}) async {
    final client = _client!;
    final (from, to, _) = ref.read(selectedRangeProvider).resolveBounds();
    return client.getAgentStats(source, from, to, instance: instance);
  }

  Future<List<SeriesPoint>> getAgentTimeseries(
    String source, {
    String? instance,
  }) async {
    final client = _client!;
    final (from, to, bucket) = ref.read(selectedRangeProvider).resolveBounds();
    return client.getTimeseries(
      from: from,
      to: to,
      bucket: bucket,
      groupBy: 'model_norm',
      source: source,
      instance: instance,
    );
  }

  Future<String> exportData({
    required UsageFilter filter,
    required String format,
    String? path,
  }) async {
    final client = _client!;
    return switch (format) {
      'json' => client.exportJson(filter, path: path),
      'monthly' => client.exportMonthlyReport(filter, path: path),
      _ => client.exportCsv(filter, path: path),
    };
  }

  void dispose() {
    _rangeRequest++;
    _liveSub?.cancel();
    _usageUpdatedSub?.cancel();
    _sourceStatusSub?.cancel();
    _win32EventSub?.cancel();
    _client?.dispose();
  }
}
