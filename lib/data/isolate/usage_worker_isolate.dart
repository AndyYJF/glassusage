import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import '../../core/security/dpapi.dart';
import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../collectors/all_collectors.dart';
import '../collectors/collector_base.dart';
import '../collectors/cursor_collector.dart';
import '../database/app_database.dart';
import '../live/live_tracker.dart';
import '../pricing/pricing_service.dart';
import '../remote/remote_sync.dart';

class WorkerInitMessage {
  final SendPort mainSendPort;
  final String dataDir;

  const WorkerInitMessage({
    required this.mainSendPort,
    required this.dataDir,
  });
}

/// Entrypoint for the dedicated background worker Isolate that owns SQLite,
/// PricingService, SettingsStore, LiveTracker, all 10 Collectors, FileWatchers,
/// and Remote SSH sync.
void usageWorkerIsolateMain(WorkerInitMessage init) {
  final receivePort = ReceivePort();
  init.mainSendPort.send({'type': 'ready', 'port': receivePort.sendPort});

  final worker = _UsageWorkerEngine(
    dataDir: init.dataDir,
    emitToMain: (String event, Map<String, dynamic> payload) {
      init.mainSendPort.send({
        'type': 'event',
        'event': event,
        'payload': payload,
      });
    },
  );

  worker.start();

  receivePort.listen((dynamic raw) async {
    if (raw is! Map) return;
    final id = raw['id'] as int?;
    final method = raw['method'] as String?;
    final args = (raw['args'] as Map?)?.cast<String, dynamic>() ?? const {};
    if (id == null || method == null) return;

    try {
      final result = await worker.handleRpc(method, args);
      init.mainSendPort.send({
        'type': 'response',
        'id': id,
        'ok': true,
        'result': result,
      });
    } catch (e) {
      init.mainSendPort.send({
        'type': 'response',
        'id': id,
        'ok': false,
        'error': e.toString(),
      });
    }
  });
}

class _UsageWorkerEngine {
  final String dataDir;
  final void Function(String event, Map<String, dynamic> payload) emitToMain;

  late final AppDatabase store;
  late final PricingService pricing;
  late final SettingsStore settingsStore;
  late final LiveTracker live;

  /// 30-second TTL cache for `collector.detect()` paths (PLAN.md §3.2 #4).
  final Map<String, (int, List<String>)> _detectCache = {};
  static const int _kDetectTtlMs = 30000;

  /// Cached budget totals for today so 1 Hz live-tick never hits SQLite (PLAN.md §3.2 #3).
  int _cachedBudgetTokensToday = 0;
  double _cachedBudgetCostToday = 0.0;

  /// Once-per-day budget alert gate.
  String? _budgetAlertedCostDay;
  String? _budgetAlertedTokensDay;

  /// 150ms coalescing timers for `usage-updated` and `source-status` (PLAN.md §3.2 #5).
  Timer? _usageUpdatedDebounce;
  Map<String, dynamic>? _lastUsageUpdatedPayload;
  Timer? _sourceStatusDebounce;
  final Map<String, Map<String, dynamic>> _pendingSourceStatuses = {};

  /// File watchers & remote sync tracking.
  final List<StreamSubscription<WatchEvent>> _watchSubs = [];
  final Map<String, Timer> _watchDebounce = {};
  final Set<String> _runningRemoteSyncs = {};
  bool _scanBusy = false;

  _UsageWorkerEngine({
    required this.dataDir,
    required this.emitToMain,
  }) {
    Directory(dataDir).createSync(recursive: true);
    store = AppDatabase.open(dataDir);
    pricing = PricingService(dataDir);
    settingsStore = SettingsStore.load(dataDir);

    final polling = allCollectors()
        .where((c) => !c.isRealtime)
        .map((c) => c.id)
        .toList();
    live = LiveTracker(pollingSources: polling);

    final recent = store.recentEvents(AppDatabase.nowMs() - 120000);
    live.warmUp(recent);
    _refreshTodayTotals();
  }

  void start() {
    // Allow initial UI hydration RPCs (getSettings, getOverview, getSourceHealth)
    // to complete immediately (< 20ms) before running background scans & LiteLLM refresh.
    Timer(const Duration(milliseconds: 350), () async {
      _setupWatchers();
      await scanAll();
      unawaited(_syncCursorNow());
      try {
        store.reprice(pricing);
        await pricing.refresh();
        store.reprice(pricing);
      } catch (_) {}
    });

    // 1 Hz live-tick timer (uses cached today totals; zero SQLite queries unless midnight rolled over)
    Timer.periodic(const Duration(seconds: 1), (_) {
      final rates = getLiveRates();
      emitToMain('live-tick', rates.toJson());
    });

    // 60s safety poll for local sources
    Timer.periodic(const Duration(seconds: 60), (_) {
      unawaited(scanAll());
    });

    // 5-minute Cursor API poll
    Timer.periodic(const Duration(minutes: 5), (_) {
      unawaited(_syncCursorNow());
    });

    // 20-second remote scheduler check
    Timer.periodic(const Duration(seconds: 20), (_) {
      _tickRemoteScheduler();
    });
  }

  void _setupWatchers() {
    for (final sub in _watchSubs) {
      sub.cancel();
    }
    _watchSubs.clear();

    final settings = settingsStore.get();
    for (final collector in allCollectors()) {
      if (!settings.sourceEnabled(collector.id)) continue;
      final paths = collector.watchPaths(settings);
      for (final watchPath in paths) {
        if (!Directory(watchPath).existsSync()) continue;
        try {
          final watcher = DirectoryWatcher(watchPath);
          final sub = watcher.events.listen(
            (_) {
              _watchDebounce[collector.id]?.cancel();
              _watchDebounce[collector.id] = Timer(
                const Duration(milliseconds: 500),
                () => runScan(collector.id),
              );
            },
            onError: (_) {},
          );
          _watchSubs.add(sub);
        } catch (_) {}
      }
    }
  }

  void _emitUsageUpdated(String source, String instance, int added) {
    final prevAdded = (_lastUsageUpdatedPayload?['added'] as int?) ?? 0;
    _lastUsageUpdatedPayload = {
      'source': source,
      'instance': instance,
      'added': prevAdded + added,
    };
    _usageUpdatedDebounce?.cancel();
    _usageUpdatedDebounce = Timer(const Duration(milliseconds: 150), () {
      final payload = _lastUsageUpdatedPayload;
      _lastUsageUpdatedPayload = null;
      if (payload != null) {
        emitToMain('usage-updated', payload);
      }
    });
  }

  void _emitSourceStatus(
    String source,
    String instance,
    HealthStatus status,
    String? error,
  ) {
    _pendingSourceStatuses['$source:$instance'] = {
      'source': source,
      'instance': instance,
      'status': status.toJson(),
      'error': error,
    };
    _sourceStatusDebounce?.cancel();
    _sourceStatusDebounce = Timer(const Duration(milliseconds: 150), () {
      final values = _pendingSourceStatuses.values.toList();
      _pendingSourceStatuses.clear();
      if (values.isNotEmpty) {
        emitToMain('source-status', values.last);
      }
    });
  }

  List<String> _detectCached(
    Collector collector,
    AppSettings settings, {
    bool force = false,
  }) {
    final now = AppDatabase.nowMs();
    final cached = _detectCache[collector.id];
    if (!force && cached != null && (now - cached.$1) < _kDetectTtlMs) {
      return cached.$2;
    }
    final paths = collector.detect(settings);
    _detectCache[collector.id] = (now, paths);
    return paths;
  }

  void _invalidateDetectCache([String? source]) {
    if (source == null) {
      _detectCache.clear();
    } else {
      _detectCache.remove(source);
    }
  }

  void _refreshTodayTotals() {
    final todayKey = AppDatabase.dayKeyLocal(AppDatabase.nowMs());
    final (from, to) = AppDatabase.dayBounds(0);
    final t = store.sumRollupDays(todayKey, todayKey);
    live.setTodayTotals(
      tokens: t.totalTokens,
      cost: t.costUsd,
      dayKey: todayKey,
    );

    final settings = settingsStore.get();
    final bt = store.sumRangeSources(
      from,
      to,
      settings.budgetAlertSources,
    );
    _cachedBudgetTokensToday = bt.totalTokens;
    _cachedBudgetCostToday = bt.costUsd;
  }

  void _checkBudgetAlerts() {
    final settings = settingsStore.get();
    if (!settings.budgetAlertsEnabled) return;
    final day = AppDatabase.dayKeyLocal(AppDatabase.nowMs());
    final sources = settings.budgetAlertSources;

    if (settings.dailyCostBudget > 0.0 &&
        _cachedBudgetCostToday >= settings.dailyCostBudget &&
        _budgetAlertedCostDay != day) {
      _budgetAlertedCostDay = day;
      emitToMain('budget-alert', {
        'kind': 'cost',
        'value': _cachedBudgetCostToday,
        'limit': settings.dailyCostBudget,
        'day': day,
        'sources': sources,
      });
    }

    if (settings.dailyTokenBudget > 0 &&
        _cachedBudgetTokensToday >= settings.dailyTokenBudget &&
        _budgetAlertedTokensDay != day) {
      _budgetAlertedTokensDay = day;
      emitToMain('budget-alert', {
        'kind': 'tokens',
        'value': _cachedBudgetTokensToday.toDouble(),
        'limit': settings.dailyTokenBudget.toDouble(),
        'day': day,
        'sources': sources,
      });
    }
  }

  LiveRates getLiveRates() {
    final todayKey = AppDatabase.dayKeyLocal(AppDatabase.nowMs());
    if (live.needsTodayRefresh(todayKey)) {
      _refreshTodayTotals();
    }
    final base = live.tick();
    return base.copyWith(
      budgetCostToday: _cachedBudgetCostToday,
      budgetTokensToday: _cachedBudgetTokensToday,
    );
  }

  void runScan(
    String sourceId, {
    String? rootOverride,
    List<PendingScanState>? extraStates,
  }) {
    if (_scanBusy) return;
    final collector = collectorById(sourceId);
    if (collector == null) return;
    final settings = settingsStore.get();
    if (!settings.sourceEnabled(sourceId)) return;

    _scanBusy = true;
    try {
      const instance = kLocalInstance;
      final ctx = ScanCtx(
        store: store,
        pricing: pricing,
        settings: settings,
        instance: instance,
        rootOverride: rootOverride,
      );
      final report = collector.scan(ctx);
      _detectCache[sourceId] = (AppDatabase.nowMs(), report.detectedPaths);
      final states = <PendingScanState>[
        ...?extraStates,
        ...report.states,
      ];
      final outcome = store.ingestScan(
        report.events,
        collector.writeMode,
        states,
      );
      live.push(outcome.deltas);
      store.recordStatus(
        sourceId,
        instance,
        report.filesSeen,
        report.skipped,
        report.detectedPaths,
        null,
      );

      if (outcome.changed > 0) {
        live.markTotalsDirty();
        _refreshTodayTotals();
        _checkBudgetAlerts();
        _emitUsageUpdated(sourceId, instance, outcome.changed);
      }

      final status = report.detectedPaths.isEmpty
          ? HealthStatus.missing
          : (collector.isRealtime ? HealthStatus.live : HealthStatus.polling);
      _emitSourceStatus(sourceId, instance, status, null);
    } catch (e) {
      final msg = e.toString();
      store.recordStatus(sourceId, kLocalInstance, 0, 0, const [], msg);
      _emitSourceStatus(sourceId, kLocalInstance, HealthStatus.error, msg);
    } finally {
      _scanBusy = false;
    }
  }

  Future<void> scanAll() async {
    for (final collector in allCollectors()) {
      runScan(collector.id);
      await Future<void>.delayed(Duration.zero);
    }
  }

  String? _getCursorCookie() {
    final file = File(p.join(dataDir, 'cursor-token.bin'));
    if (!file.existsSync()) return null;
    try {
      return Dpapi.unprotectStr(file.readAsBytesSync());
    } catch (_) {
      return null;
    }
  }

  void _setCursorCookie(String token) {
    final file = File(p.join(dataDir, 'cursor-token.bin'));
    final cleaned = CursorCollector.normalizeCredential(token);
    if (cleaned.isEmpty) {
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
      return;
    }
    file.writeAsBytesSync(Dpapi.protectStr(cleaned), flush: true);
  }

  Future<void> _syncCursorNow() async {
    final settings = settingsStore.get();
    final token = CursorCollector.accessToken(settings);
    final cookie = _getCursorCookie();
    if (token == null && cookie == null) {
      CursorCollector.setError(
        'No Cursor credential found. Sign in to Cursor, or paste a session token in Settings.',
      );
      _emitSourceStatus(
        SourceIds.cursor,
        kLocalInstance,
        HealthStatus.missing,
        CursorCollector.takeError(),
      );
      return;
    }

    const key = 'api:usage-events';
    final state = store.getScanState(SourceIds.cursor, kLocalInstance, key);
    final now = AppDatabase.nowMs();
    final start = (state != null && (state.offset - 5 * 60000) > 0)
        ? (state.offset - 5 * 60000)
        : (now - 30 * 24 * 3600 * 1000);

    try {
      final events = await CursorCollector.fetchUsageEvents(
        token: token,
        pasted: cookie,
        startMs: start,
        endMs: now,
        instance: kLocalInstance,
      );
      CursorCollector.setError(null);
      CursorCollector.stashEvents(events);
      final pending = PendingScanState(
        source: SourceIds.cursor,
        instance: kLocalInstance,
        key: key,
        state: ScanState(
          offset: now,
          mtimeMs: now,
          extra: events.length.toString(),
        ),
      );
      runScan(SourceIds.cursor, extraStates: [pending]);
    } catch (e) {
      final msg = 'Cursor account API unavailable: $e';
      CursorCollector.setError(msg);
      store.recordStatus(SourceIds.cursor, kLocalInstance, 0, 0, const [], msg);
      _emitSourceStatus(
        SourceIds.cursor,
        kLocalInstance,
        HealthStatus.error,
        msg,
      );
    }
  }

  List<SourceHealth> getSourceHealth() {
    final settings = settingsStore.get();
    final detectedBySource = <String, List<String>>{};
    final realtimeSources = <String>{};
    for (final c in allCollectors()) {
      detectedBySource[c.id] = _detectCached(c, settings);
      if (c.isRealtime) realtimeSources.add(c.id);
    }
    return store.sourceHealth(
      settings: settings,
      detectedPathsBySource: detectedBySource,
      realtimeSources: realtimeSources,
    );
  }

  void _tickRemoteScheduler() {
    final instances = store.listRemote().where((i) => i.enabled);
    for (final inst in instances) {
      if (_runningRemoteSyncs.contains(inst.name)) continue;
      _runningRemoteSyncs.add(inst.name);
      Future(() async {
        try {
          await syncRemoteInstance(
            dataDir: dataDir,
            store: store,
            pricing: pricing,
            settings: settingsStore.get(),
            live: live,
            name: inst.name,
            onStatus: _emitSourceStatus,
            onUpdated: (src, instance, added) {
              _refreshTodayTotals();
              _checkBudgetAlerts();
              _emitUsageUpdated(src, instance, added);
            },
          );
        } catch (_) {
        } finally {
          _runningRemoteSyncs.remove(inst.name);
        }
      });
    }
  }

  Map<String, dynamic> _pricingInfoJson() {
    final info = pricing.info;
    return {
      'modelCount': info.modelCount,
      'source': info.source,
      'overrides': info.overrides.map((k, v) => MapEntry(k, v.toJson())),
    };
  }

  Future<dynamic> handleRpc(String method, Map<String, dynamic> args) async {
    switch (method) {
      case 'get_overview':
        final from = (args['from'] as num?)?.toInt() ?? 0;
        final to = (args['to'] as num?)?.toInt() ?? AppDatabase.nowMs();
        return store.overview(from, to).toJson();

      case 'get_agent_stats':
        final source = args['source'] as String? ?? SourceIds.claude;
        final from = (args['from'] as num?)?.toInt() ?? 0;
        final to = (args['to'] as num?)?.toInt() ?? AppDatabase.nowMs();
        return store.agentStats(source, from, to).toJson();

      case 'get_timeseries':
        final from = (args['from'] as num?)?.toInt() ?? 0;
        final to = (args['to'] as num?)?.toInt() ?? AppDatabase.nowMs();
        final bucket = args['bucket'] as String? ?? 'day';
        final groupBy = args['groupBy'] as String? ?? 'source';
        final source = args['source'] as String?;
        return store
            .timeseries(
              fromMs: from,
              toMs: to,
              bucket: bucket,
              groupBy: groupBy,
              source: source,
            )
            .map((p) => p.toJson())
            .toList();

      case 'get_usage_log':
        final filter = UsageFilter.fromJson(
          (args['filter'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
        final page = (args['page'] as num?)?.toInt() ?? 0;
        final pageSize = (args['pageSize'] as num?)?.toInt() ?? 50;
        return store
            .usageLog(filter, page, pageSize)
            .toJson((r) => r.toJson());

      case 'get_provider_stats':
        final filter = UsageFilter.fromJson(
          (args['filter'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
        return store
            .groupStats('provider', filter)
            .map((g) => g.toJson())
            .toList();

      case 'get_model_stats':
        final filter = UsageFilter.fromJson(
          (args['filter'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
        return store
            .groupStats('model_norm', filter)
            .map((g) => g.toJson())
            .toList();

      case 'get_group_stats':
        final groupBy = args['groupBy'] as String? ?? 'model';
        final filter = UsageFilter.fromJson(
          (args['filter'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
        return store
            .groupStats(groupBy, filter)
            .map((g) => g.toJson())
            .toList();

      case 'get_source_health':
        return getSourceHealth().map((h) => h.toJson()).toList();

      case 'get_filter_options':
        return store.filterOptions().toJson();

      case 'rescan_source':
        final source = args['source'] as String;
        _invalidateDetectCache(source);
        if (source == SourceIds.cursor) {
          await _syncCursorNow();
        } else {
          runScan(source);
        }
        return getSourceHealth().map((h) => h.toJson()).toList();

      case 'rescan_all':
        _invalidateDetectCache();
        await scanAll();
        await _syncCursorNow();
        return getSourceHealth().map((h) => h.toJson()).toList();

      case 'set_cursor_cookie':
        final cookie = args['cookie'] as String? ?? '';
        _setCursorCookie(cookie);
        await _syncCursorNow();
        return null;

      case 'get_cursor_status':
        final settings = settingsStore.get();
        return CursorStatus(
          hasAccessToken: CursorCollector.accessToken(settings) != null,
          hasCookie: _getCursorCookie() != null,
        ).toJson();

      case 'sync_cursor_now':
        await _syncCursorNow();
        return getSourceHealth().map((h) => h.toJson()).toList();

      case 'get_settings':
        return settingsStore.get().toJson();

      case 'set_settings':
        final next = AppSettings.fromJson(
          (args['settings'] as Map).cast<String, dynamic>(),
        );
        settingsStore.set(next);
        _invalidateDetectCache();
        _budgetAlertedCostDay = null;
        _budgetAlertedTokensDay = null;
        _refreshTodayTotals();
        _checkBudgetAlerts();
        _setupWatchers();
        return null;

      case 'get_pricing_info':
        return _pricingInfoJson();

      case 'set_pricing_overrides':
        final raw = (args['overrides'] as Map).cast<String, dynamic>();
        final overrides = <String, ModelPrice>{};
        raw.forEach((k, v) {
          if (v is Map) {
            overrides[k] = ModelPrice.fromJson(v.cast<String, dynamic>());
          }
        });
        pricing.setOverrides(overrides);
        store.reprice(pricing);
        _refreshTodayTotals();
        return _pricingInfoJson();

      case 'remove_pricing_override':
        final model = args['model'] as String;
        pricing.removeOverride(model);
        store.reprice(pricing);
        _refreshTodayTotals();
        return _pricingInfoJson();

      case 'refresh_pricing':
        final count = await pricing.refresh();
        store.reprice(pricing);
        _refreshTodayTotals();
        return count;

      case 'export_csv':
        final filter = UsageFilter.fromJson(
          (args['filter'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
        final outPath = args['path'] as String? ??
            p.join(dataDir, 'exports', 'glassusage-${AppDatabase.nowMs()}.csv');
        return store.exportCsv(filter, outPath);

      case 'export_json':
        final filter = UsageFilter.fromJson(
          (args['filter'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
        final outPath = args['path'] as String? ??
            p.join(dataDir, 'exports', 'glassusage-${AppDatabase.nowMs()}.json');
        return store.exportJson(filter, outPath);

      case 'export_monthly_report':
        final filter = UsageFilter.fromJson(
          (args['filter'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
        final outPath = args['path'] as String? ??
            p.join(
              dataDir,
              'exports',
              'glassusage-monthly-${AppDatabase.nowMs()}.json',
            );
        return store.exportMonthlyReport(filter, outPath);

      case 'list_remote_instances':
        return store.listRemote().map((r) => r.toJson()).toList();

      case 'upsert_remote_instance':
        final input = RemoteInstanceInput.fromJson(
          (args['input'] as Map).cast<String, dynamic>(),
        );
        input.validate();
        final secret = (input.password != null && input.password!.isNotEmpty)
            ? Dpapi.protectStr(input.password!)
            : null;
        final inst = input.toInstance(
          hasExistingSecret: store.remoteSecret(input.name) != null,
        );
        store.upsertRemote(inst, secret);
        return store.listRemote().map((r) => r.toJson()).toList();

      case 'delete_remote_instance':
        final name = args['name'] as String;
        final purgeData = args['purgeData'] as bool? ?? false;
        store.deleteRemote(name, purgeEvents: purgeData);
        final snap = Directory(p.join(dataDir, 'remote', name));
        if (snap.existsSync()) {
          try {
            snap.deleteSync(recursive: true);
          } catch (_) {}
        }
        return store.listRemote().map((r) => r.toJson()).toList();

      case 'test_remote_instance':
        final input = RemoteInstanceInput.fromJson(
          (args['input'] as Map).cast<String, dynamic>(),
        );
        final report = await testRemoteInstance(
          dataDir: dataDir,
          store: store,
          pricing: pricing,
          settings: settingsStore.get(),
          input: input,
        );
        return report.toJson();

      case 'sync_remote_instance':
        final name = args['name'] as String;
        return await syncRemoteInstance(
          dataDir: dataDir,
          store: store,
          pricing: pricing,
          settings: settingsStore.get(),
          live: live,
          name: name,
          onStatus: _emitSourceStatus,
          onUpdated: (src, instance, added) {
            _refreshTodayTotals();
            _checkBudgetAlerts();
            _emitUsageUpdated(src, instance, added);
          },
        );

      case 'get_live_rates':
        return getLiveRates().toJson();

      default:
        throw UnsupportedError('Unknown worker RPC method: $method');
    }
  }
}
