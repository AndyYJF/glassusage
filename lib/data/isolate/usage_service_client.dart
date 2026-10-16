import 'dart:async';
import 'dart:isolate';

import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../pricing/pricing_service.dart';
import 'usage_worker_isolate.dart';

class BudgetAlertEvent {
  final String kind;
  final double value;
  final double limit;
  final String day;
  final List<String> sources;

  const BudgetAlertEvent({
    required this.kind,
    required this.value,
    required this.limit,
    required this.day,
    required this.sources,
  });

  factory BudgetAlertEvent.fromJson(Map<String, dynamic> json) {
    return BudgetAlertEvent(
      kind: json['kind'] as String? ?? 'cost',
      value: (json['value'] as num?)?.toDouble() ?? 0.0,
      limit: (json['limit'] as num?)?.toDouble() ?? 0.0,
      day: json['day'] as String? ?? '',
      sources: (json['sources'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
    );
  }
}

/// UI-side client that communicates with the background [usageWorkerIsolateMain]
/// over `SendPort` / `ReceivePort` so the UI thread never blocks on SQLite,
/// file scanning, or network calls.
class UsageServiceClient {
  final String dataDir;

  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _workerPort;
  final Completer<SendPort> _readyCompleter = Completer<SendPort>();

  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};

  final StreamController<LiveRates> _liveTickController =
      StreamController<LiveRates>.broadcast();
  final StreamController<Map<String, dynamic>> _usageUpdatedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> _sourceStatusController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<BudgetAlertEvent> _budgetAlertController =
      StreamController<BudgetAlertEvent>.broadcast();

  Stream<LiveRates> get onLiveTick => _liveTickController.stream;
  Stream<Map<String, dynamic>> get onUsageUpdated =>
      _usageUpdatedController.stream;
  Stream<Map<String, dynamic>> get onSourceStatus =>
      _sourceStatusController.stream;
  Stream<BudgetAlertEvent> get onBudgetAlert => _budgetAlertController.stream;

  UsageServiceClient({required this.dataDir});

  Future<void> start() async {
    if (_isolate != null) return;
    final receivePort = ReceivePort();
    _receivePort = receivePort;

    receivePort.listen((dynamic msg) {
      if (msg is! Map) return;
      final type = msg['type'] as String?;
      if (type == 'ready') {
        final port = msg['port'] as SendPort;
        _workerPort = port;
        if (!_readyCompleter.isCompleted) {
          _readyCompleter.complete(port);
        }
      } else if (type == 'response') {
        final id = msg['id'] as int?;
        if (id == null) return;
        final completer = _pending.remove(id);
        if (completer == null) return;
        if (msg['ok'] == true) {
          completer.complete(msg['result']);
        } else {
          completer.completeError(
            StateError(msg['error']?.toString() ?? 'Worker RPC error'),
          );
        }
      } else if (type == 'event') {
        final event = msg['event'] as String?;
        final payload =
            (msg['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
        switch (event) {
          case 'live-tick':
            _liveTickController.add(LiveRates.fromJson(payload));
            break;
          case 'usage-updated':
            _usageUpdatedController.add(payload);
            break;
          case 'source-status':
            _sourceStatusController.add(payload);
            break;
          case 'budget-alert':
            _budgetAlertController.add(BudgetAlertEvent.fromJson(payload));
            break;
        }
      }
    });

    _isolate = await Isolate.spawn<WorkerInitMessage>(
      usageWorkerIsolateMain,
      WorkerInitMessage(
        mainSendPort: receivePort.sendPort,
        dataDir: dataDir,
      ),
      debugName: 'GlassUsageWorkerIsolate',
    );
    await _readyCompleter.future;
  }

  Future<dynamic> _call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    final port = _workerPort ?? await _readyCompleter.future;
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    port.send({
      'id': id,
      'method': method,
      'args': args,
    });
    return completer.future;
  }

  Future<OverviewStats> getOverview(int from, int to) async {
    final res = await _call('get_overview', {'from': from, 'to': to});
    return OverviewStats.fromJson((res as Map).cast<String, dynamic>());
  }

  Future<AgentStats> getAgentStats(
    String source,
    int from,
    int to, {
    String? instance,
  }) async {
    final res = await _call('get_agent_stats', {
      'source': source,
      'from': from,
      'to': to,
      'instance': instance,
    });
    return AgentStats.fromJson((res as Map).cast<String, dynamic>());
  }

  Future<List<SeriesPoint>> getTimeseries({
    required int from,
    required int to,
    required String bucket,
    required String groupBy,
    String? source,
  }) async {
    final res = await _call('get_timeseries', {
      'from': from,
      'to': to,
      'bucket': bucket,
      'groupBy': groupBy,
      'source': source,
    });
    return (res as List)
        .map((e) => SeriesPoint.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<Page<UsageRow>> getUsageLog(
    UsageFilter filter,
    int page,
    int pageSize,
  ) async {
    final res = await _call('get_usage_log', {
      'filter': filter.toJson(),
      'page': page,
      'pageSize': pageSize,
    });
    return Page.fromJson(
      (res as Map).cast<String, dynamic>(),
      UsageRow.fromJson,
    );
  }

  Future<List<GroupStat>> getProviderStats(UsageFilter filter) async {
    final res = await _call('get_provider_stats', {'filter': filter.toJson()});
    return (res as List)
        .map((e) => GroupStat.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<List<GroupStat>> getModelStats(UsageFilter filter) async {
    final res = await _call('get_model_stats', {'filter': filter.toJson()});
    return (res as List)
        .map((e) => GroupStat.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<List<GroupStat>> getGroupStats(
    String groupBy,
    UsageFilter filter,
  ) async {
    final res = await _call('get_group_stats', {
      'groupBy': groupBy,
      'filter': filter.toJson(),
    });
    return (res as List)
        .map((e) => GroupStat.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<List<SourceHealth>> getSourceHealth() async {
    final res = await _call('get_source_health');
    return (res as List)
        .map((e) => SourceHealth.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<FilterOptions> getFilterOptions() async {
    final res = await _call('get_filter_options');
    return FilterOptions.fromJson((res as Map).cast<String, dynamic>());
  }

  Future<List<SourceHealth>> rescanSource(String source) async {
    final res = await _call('rescan_source', {'source': source});
    return (res as List)
        .map((e) => SourceHealth.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<List<SourceHealth>> rescanAll() async {
    final res = await _call('rescan_all');
    return (res as List)
        .map((e) => SourceHealth.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<void> setCursorCookie(String cookie) async {
    await _call('set_cursor_cookie', {'cookie': cookie});
  }

  Future<CursorStatus> getCursorStatus() async {
    final res = await _call('get_cursor_status');
    return CursorStatus.fromJson((res as Map).cast<String, dynamic>());
  }

  Future<List<SourceHealth>> syncCursorNow() async {
    final res = await _call('sync_cursor_now');
    return (res as List)
        .map((e) => SourceHealth.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<AppSettings> getSettings() async {
    final res = await _call('get_settings');
    return AppSettings.fromJson((res as Map).cast<String, dynamic>());
  }

  Future<void> setSettings(AppSettings settings) async {
    await _call('set_settings', {'settings': settings.toJson()});
  }

  Future<PricingInfo> getPricingInfo() async {
    final res = (await _call('get_pricing_info') as Map).cast<String, dynamic>();
    final rawOv = (res['overrides'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PricingInfo(
      modelCount: (res['modelCount'] as num?)?.toInt() ?? 0,
      source: res['source'] as String? ?? 'builtin',
      overrides: rawOv.map(
        (k, v) => MapEntry(k, ModelPrice.fromJson((v as Map).cast<String, dynamic>())),
      ),
    );
  }

  Future<PricingInfo> setPricingOverrides(
    Map<String, ModelPrice> overrides,
  ) async {
    final res = (await _call('set_pricing_overrides', {
      'overrides': overrides.map((k, v) => MapEntry(k, v.toJson())),
    }) as Map)
        .cast<String, dynamic>();
    final rawOv = (res['overrides'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PricingInfo(
      modelCount: (res['modelCount'] as num?)?.toInt() ?? 0,
      source: res['source'] as String? ?? 'builtin',
      overrides: rawOv.map(
        (k, v) => MapEntry(k, ModelPrice.fromJson((v as Map).cast<String, dynamic>())),
      ),
    );
  }

  Future<PricingInfo> removePricingOverride(String model) async {
    final res = (await _call('remove_pricing_override', {'model': model}) as Map)
        .cast<String, dynamic>();
    final rawOv = (res['overrides'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PricingInfo(
      modelCount: (res['modelCount'] as num?)?.toInt() ?? 0,
      source: res['source'] as String? ?? 'builtin',
      overrides: rawOv.map(
        (k, v) => MapEntry(k, ModelPrice.fromJson((v as Map).cast<String, dynamic>())),
      ),
    );
  }

  Future<int> refreshPricing() async {
    final res = await _call('refresh_pricing');
    return (res as num).toInt();
  }

  Future<String> exportCsv(UsageFilter filter, {String? path}) async {
    final res = await _call('export_csv', {
      'filter': filter.toJson(),
      'path': path,
    });
    return res as String;
  }

  Future<String> exportJson(UsageFilter filter, {String? path}) async {
    final res = await _call('export_json', {
      'filter': filter.toJson(),
      'path': path,
    });
    return res as String;
  }

  Future<String> exportMonthlyReport(UsageFilter filter, {String? path}) async {
    final res = await _call('export_monthly_report', {
      'filter': filter.toJson(),
      'path': path,
    });
    return res as String;
  }

  Future<List<RemoteInstance>> listRemoteInstances() async {
    final res = await _call('list_remote_instances');
    return (res as List)
        .map((e) => RemoteInstance.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<List<RemoteInstance>> upsertRemoteInstance(
    RemoteInstanceInput input,
  ) async {
    final res = await _call('upsert_remote_instance', {
      'input': input.toJson(),
    });
    return (res as List)
        .map((e) => RemoteInstance.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<List<RemoteInstance>> deleteRemoteInstance(
    String name,
    bool purgeData,
  ) async {
    final res = await _call('delete_remote_instance', {
      'name': name,
      'purgeData': purgeData,
    });
    return (res as List)
        .map((e) => RemoteInstance.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<TestReport> testRemoteInstance(RemoteInstanceInput input) async {
    final res = await _call('test_remote_instance', {'input': input.toJson()});
    return TestReport.fromJson((res as Map).cast<String, dynamic>());
  }

  Future<int> syncRemoteInstance(String name) async {
    final res = await _call('sync_remote_instance', {'name': name});
    return (res as num).toInt();
  }

  Future<LiveRates> getLiveRates() async {
    final res = await _call('get_live_rates');
    return LiveRates.fromJson((res as Map).cast<String, dynamic>());
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    _liveTickController.close();
    _usageUpdatedController.close();
    _sourceStatusController.close();
    _budgetAlertController.close();
  }
}
