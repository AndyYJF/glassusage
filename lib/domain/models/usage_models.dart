/// Normalized domain models shared across collectors, SQLite store, background Isolate, and UI.
library;

class SourceIds {
  static const String claude = 'claude';
  static const String codex = 'codex';
  static const String cursor = 'cursor';
  static const String antigravity = 'antigravity';
  static const String opencode = 'opencode';
  static const String hermes = 'hermes';
  static const String openclaw = 'openclaw';
  static const String pi = 'pi';
  static const String kimi = 'kimi';
  static const String dsh = 'dsh';

  static const List<String> all = [
    claude,
    codex,
    cursor,
    antigravity,
    opencode,
    hermes,
    openclaw,
    pi,
    kimi,
    dsh,
  ];
}

class SurfaceIds {
  static const String cli = 'cli';
  static const String desktop = 'desktop';
  static const String ide = 'ide';
  static const String cloud = 'cloud';
}

const String kLocalInstance = 'local';

class UsageEvent {
  String source;
  String surface;
  String instance;
  String sessionId;
  String? project;
  String model;
  String modelNorm;
  String? provider;
  int timestamp;
  int inputTokens;
  int outputTokens;
  int cacheReadTokens;
  int cacheWriteTokens;
  int reasoningTokens;
  double? costUsd;
  String dedupKey;

  UsageEvent({
    required this.source,
    required this.surface,
    required this.instance,
    required this.dedupKey,
    this.sessionId = '',
    this.project,
    this.model = '',
    this.modelNorm = '',
    this.provider,
    this.timestamp = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
    this.costUsd,
  });

  /// Billable token total. `reasoningTokens` is a subset of `outputTokens` across all
  /// sources, so it is never added to the total.
  int get totalTokens =>
      inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens;

  bool get isEmpty => totalTokens == 0;

  UsageEvent copyWith({
    String? source,
    String? surface,
    String? instance,
    String? sessionId,
    String? project,
    String? model,
    String? modelNorm,
    String? provider,
    int? timestamp,
    int? inputTokens,
    int? outputTokens,
    int? cacheReadTokens,
    int? cacheWriteTokens,
    int? reasoningTokens,
    double? costUsd,
    String? dedupKey,
  }) {
    return UsageEvent(
      source: source ?? this.source,
      surface: surface ?? this.surface,
      instance: instance ?? this.instance,
      sessionId: sessionId ?? this.sessionId,
      project: project ?? this.project,
      model: model ?? this.model,
      modelNorm: modelNorm ?? this.modelNorm,
      provider: provider ?? this.provider,
      timestamp: timestamp ?? this.timestamp,
      inputTokens: inputTokens ?? this.inputTokens,
      outputTokens: outputTokens ?? this.outputTokens,
      cacheReadTokens: cacheReadTokens ?? this.cacheReadTokens,
      cacheWriteTokens: cacheWriteTokens ?? this.cacheWriteTokens,
      reasoningTokens: reasoningTokens ?? this.reasoningTokens,
      costUsd: costUsd ?? this.costUsd,
      dedupKey: dedupKey ?? this.dedupKey,
    );
  }
}

class ScanState {
  final int offset;
  final int mtimeMs;
  final String? extra;

  const ScanState({
    this.offset = 0,
    this.mtimeMs = 0,
    this.extra,
  });
}

class PendingScanState {
  final String source;
  final String instance;
  final String key;
  final ScanState state;

  const PendingScanState({
    required this.source,
    required this.instance,
    required this.key,
    required this.state,
  });
}

enum HealthStatus {
  live,
  polling,
  missing,
  error,
  disabled;

  String toJson() => name;

  static HealthStatus fromJson(String? raw) {
    return HealthStatus.values.firstWhere(
      (e) => e.name == raw?.toLowerCase(),
      orElse: () => HealthStatus.missing,
    );
  }
}

class SourceHealth {
  final String source;
  final String instance;
  final HealthStatus status;
  final List<String> detectedPaths;
  final int fileCount;
  final int eventCount;
  final int? lastScanMs;
  final int? lastEventMs;
  final String? lastError;
  final int skippedRows;

  const SourceHealth({
    required this.source,
    required this.instance,
    required this.status,
    this.detectedPaths = const [],
    this.fileCount = 0,
    this.eventCount = 0,
    this.lastScanMs,
    this.lastEventMs,
    this.lastError,
    this.skippedRows = 0,
  });

  SourceHealth copyWith({
    HealthStatus? status,
    List<String>? detectedPaths,
    int? fileCount,
    int? eventCount,
    int? lastScanMs,
    int? lastEventMs,
    String? lastError,
    int? skippedRows,
  }) {
    return SourceHealth(
      source: source,
      instance: instance,
      status: status ?? this.status,
      detectedPaths: detectedPaths ?? this.detectedPaths,
      fileCount: fileCount ?? this.fileCount,
      eventCount: eventCount ?? this.eventCount,
      lastScanMs: lastScanMs ?? this.lastScanMs,
      lastEventMs: lastEventMs ?? this.lastEventMs,
      lastError: lastError ?? this.lastError,
      skippedRows: skippedRows ?? this.skippedRows,
    );
  }

  Map<String, dynamic> toJson() => {
        'source': source,
        'instance': instance,
        'status': status.toJson(),
        'detectedPaths': detectedPaths,
        'fileCount': fileCount,
        'eventCount': eventCount,
        'lastScanMs': lastScanMs,
        'lastEventMs': lastEventMs,
        'lastError': lastError,
        'skippedRows': skippedRows,
      };

  factory SourceHealth.fromJson(Map<String, dynamic> json) => SourceHealth(
        source: json['source'] as String? ?? '',
        instance: json['instance'] as String? ?? kLocalInstance,
        status: HealthStatus.fromJson(json['status'] as String?),
        detectedPaths: (json['detectedPaths'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        fileCount: (json['fileCount'] as num?)?.toInt() ?? 0,
        eventCount: (json['eventCount'] as num?)?.toInt() ?? 0,
        lastScanMs: (json['lastScanMs'] as num?)?.toInt(),
        lastEventMs: (json['lastEventMs'] as num?)?.toInt(),
        lastError: json['lastError'] as String?,
        skippedRows: (json['skippedRows'] as num?)?.toInt() ?? 0,
      );
}

class TokenBreakdown {
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int reasoningTokens;
  final int totalTokens;
  final double costUsd;
  final int events;
  final int unpricedEvents;

  const TokenBreakdown({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
    this.totalTokens = 0,
    this.costUsd = 0.0,
    this.events = 0,
    this.unpricedEvents = 0,
  });

  double get cacheHitRate {
    final denom = inputTokens + cacheReadTokens + cacheWriteTokens;
    return denom == 0 ? 0.0 : cacheReadTokens / denom;
  }

  Map<String, dynamic> toJson() => {
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'cacheReadTokens': cacheReadTokens,
        'cacheWriteTokens': cacheWriteTokens,
        'reasoningTokens': reasoningTokens,
        'totalTokens': totalTokens,
        'costUsd': costUsd,
        'events': events,
        'unpricedEvents': unpricedEvents,
      };

  factory TokenBreakdown.fromJson(Map<String, dynamic> json) {
    final inp = (json['inputTokens'] as num?)?.toInt() ?? 0;
    final outp = (json['outputTokens'] as num?)?.toInt() ?? 0;
    final cr = (json['cacheReadTokens'] as num?)?.toInt() ?? 0;
    final cw = (json['cacheWriteTokens'] as num?)?.toInt() ?? 0;
    return TokenBreakdown(
      inputTokens: inp,
      outputTokens: outp,
      cacheReadTokens: cr,
      cacheWriteTokens: cw,
      reasoningTokens: (json['reasoningTokens'] as num?)?.toInt() ?? 0,
      totalTokens:
          (json['totalTokens'] as num?)?.toInt() ?? (inp + outp + cr + cw),
      costUsd: (json['costUsd'] as num?)?.toDouble() ?? 0.0,
      events: (json['events'] as num?)?.toInt() ?? 0,
      unpricedEvents: (json['unpricedEvents'] as num?)?.toInt() ?? 0,
    );
  }
}

class TimeRange {
  final int from;
  final int to;

  const TimeRange({required this.from, required this.to});
}

class SeriesPoint {
  final int bucket;
  final String key;
  final TokenBreakdown totals;

  const SeriesPoint({
    required this.bucket,
    required this.key,
    required this.totals,
  });

  int get totalTokens => totals.totalTokens;
  double get costUsd => totals.costUsd;

  Map<String, dynamic> toJson() => {
        'bucket': bucket,
        'key': key,
        ...totals.toJson(),
      };

  factory SeriesPoint.fromJson(Map<String, dynamic> json) => SeriesPoint(
        bucket: (json['bucket'] as num?)?.toInt() ?? 0,
        key: json['key'] as String? ?? 'total',
        totals: TokenBreakdown.fromJson(json),
      );
}

class UsageRow {
  final int id;
  final int tsMs;
  final String source;
  final String surface;
  final String instance;
  final String? provider;
  final String model;
  final String modelNorm;
  final String? project;
  final String sessionId;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int reasoningTokens;
  final double? costUsd;
  final bool unpriced;

  const UsageRow({
    required this.id,
    required this.tsMs,
    required this.source,
    required this.surface,
    required this.instance,
    this.provider,
    required this.model,
    required this.modelNorm,
    this.project,
    required this.sessionId,
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
    required this.reasoningTokens,
    this.costUsd,
    required this.unpriced,
  });

  int get totalTokens =>
      inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens;

  Map<String, dynamic> toJson() => {
        'id': id,
        'tsMs': tsMs,
        'source': source,
        'surface': surface,
        'instance': instance,
        'provider': provider,
        'model': model,
        'modelNorm': modelNorm,
        'project': project,
        'sessionId': sessionId,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'cacheReadTokens': cacheReadTokens,
        'cacheWriteTokens': cacheWriteTokens,
        'reasoningTokens': reasoningTokens,
        'costUsd': costUsd,
        'unpriced': unpriced,
      };

  factory UsageRow.fromJson(Map<String, dynamic> json) => UsageRow(
        id: (json['id'] as num?)?.toInt() ?? 0,
        tsMs: (json['tsMs'] as num?)?.toInt() ?? 0,
        source: json['source'] as String? ?? '',
        surface: json['surface'] as String? ?? '',
        instance: json['instance'] as String? ?? kLocalInstance,
        provider: json['provider'] as String?,
        model: json['model'] as String? ?? '',
        modelNorm: json['modelNorm'] as String? ?? '',
        project: json['project'] as String?,
        sessionId: json['sessionId'] as String? ?? '',
        inputTokens: (json['inputTokens'] as num?)?.toInt() ?? 0,
        outputTokens: (json['outputTokens'] as num?)?.toInt() ?? 0,
        cacheReadTokens: (json['cacheReadTokens'] as num?)?.toInt() ?? 0,
        cacheWriteTokens: (json['cacheWriteTokens'] as num?)?.toInt() ?? 0,
        reasoningTokens: (json['reasoningTokens'] as num?)?.toInt() ?? 0,
        costUsd: (json['costUsd'] as num?)?.toDouble(),
        unpriced: json['unpriced'] as bool? ?? (json['costUsd'] == null),
      );
}

class UsageFilter {
  final int? from;
  final int? to;
  final List<String>? sources;
  final List<String>? instances;
  final List<String>? providers;
  final List<String>? models;
  final String? search;
  final bool? unpricedOnly;

  const UsageFilter({
    this.from,
    this.to,
    this.sources,
    this.instances,
    this.providers,
    this.models,
    this.search,
    this.unpricedOnly,
  });

  UsageFilter copyWith({
    int? from,
    int? to,
    List<String>? sources,
    List<String>? instances,
    List<String>? providers,
    List<String>? models,
    String? search,
    bool? unpricedOnly,
    bool clearSources = false,
    bool clearInstances = false,
    bool clearProviders = false,
    bool clearModels = false,
    bool clearSearch = false,
    bool clearUnpriced = false,
  }) {
    return UsageFilter(
      from: from ?? this.from,
      to: to ?? this.to,
      sources: clearSources ? null : (sources ?? this.sources),
      instances: clearInstances ? null : (instances ?? this.instances),
      providers: clearProviders ? null : (providers ?? this.providers),
      models: clearModels ? null : (models ?? this.models),
      search: clearSearch ? null : (search ?? this.search),
      unpricedOnly: clearUnpriced ? null : (unpricedOnly ?? this.unpricedOnly),
    );
  }

  Map<String, dynamic> toJson() => {
        'from': from,
        'to': to,
        'sources': sources,
        'instances': instances,
        'providers': providers,
        'models': models,
        'search': search,
        'unpricedOnly': unpricedOnly,
      };

  factory UsageFilter.fromJson(Map<String, dynamic> json) => UsageFilter(
        from: (json['from'] as num?)?.toInt(),
        to: (json['to'] as num?)?.toInt(),
        sources: (json['sources'] as List?)?.map((e) => e.toString()).toList(),
        instances:
            (json['instances'] as List?)?.map((e) => e.toString()).toList(),
        providers:
            (json['providers'] as List?)?.map((e) => e.toString()).toList(),
        models: (json['models'] as List?)?.map((e) => e.toString()).toList(),
        search: json['search'] as String?,
        unpricedOnly: json['unpricedOnly'] as bool?,
      );
}

class GroupStat {
  final String key;
  final String label;
  final TokenBreakdown totals;
  final double share;
  final bool unpriced;

  const GroupStat({
    required this.key,
    required this.label,
    required this.totals,
    required this.share,
    required this.unpriced,
  });

  int get totalTokens => totals.totalTokens;
  double get costUsd => totals.costUsd;
  int get events => totals.events;

  GroupStat copyWith({String? label}) => GroupStat(
        key: key,
        label: label ?? this.label,
        totals: totals,
        share: share,
        unpriced: unpriced,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        ...totals.toJson(),
        'share': share,
        'unpriced': unpriced,
      };

  factory GroupStat.fromJson(Map<String, dynamic> json) => GroupStat(
        key: json['key'] as String? ?? '',
        label: json['label'] as String? ?? '',
        totals: TokenBreakdown.fromJson(json),
        share: (json['share'] as num?)?.toDouble() ?? 0.0,
        unpriced: json['unpriced'] as bool? ?? false,
      );
}

class MonthlyStat {
  final String month;
  final TokenBreakdown totals;
  final List<GroupStat> bySource;

  const MonthlyStat({
    required this.month,
    required this.totals,
    required this.bySource,
  });

  Map<String, dynamic> toJson() => {
        'month': month,
        ...totals.toJson(),
        'bySource': bySource.map((s) => s.toJson()).toList(),
      };
}

class Page<T> {
  final List<T> rows;
  final int total;
  final int page;
  final int pageSize;

  const Page({
    required this.rows,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  Map<String, dynamic> toJson(Map<String, dynamic> Function(T) itemToJson) => {
        'rows': rows.map(itemToJson).toList(),
        'total': total,
        'page': page,
        'pageSize': pageSize,
      };

  factory Page.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) itemFromJson,
  ) {
    return Page(
      rows: (json['rows'] as List? ?? const [])
          .map((e) => itemFromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      total: (json['total'] as num?)?.toInt() ?? 0,
      page: (json['page'] as num?)?.toInt() ?? 0,
      pageSize: (json['pageSize'] as num?)?.toInt() ?? 50,
    );
  }
}

class OverviewStats {
  final TokenBreakdown today;
  final TokenBreakdown yesterday;
  final TokenBreakdown thisWeek;
  final TokenBreakdown lastWeek;
  final TokenBreakdown range;
  final List<GroupStat> perSource;

  const OverviewStats({
    required this.today,
    required this.yesterday,
    required this.thisWeek,
    required this.lastWeek,
    required this.range,
    required this.perSource,
  });

  Map<String, dynamic> toJson() => {
        'today': today.toJson(),
        'yesterday': yesterday.toJson(),
        'thisWeek': thisWeek.toJson(),
        'lastWeek': lastWeek.toJson(),
        'range': range.toJson(),
        'perSource': perSource.map((e) => e.toJson()).toList(),
      };

  factory OverviewStats.fromJson(Map<String, dynamic> json) => OverviewStats(
        today: TokenBreakdown.fromJson(
          (json['today'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        yesterday: TokenBreakdown.fromJson(
          (json['yesterday'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        thisWeek: TokenBreakdown.fromJson(
          (json['thisWeek'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        lastWeek: TokenBreakdown.fromJson(
          (json['lastWeek'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        range: TokenBreakdown.fromJson(
          (json['range'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        perSource: (json['perSource'] as List? ?? const [])
            .map((e) => GroupStat.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}

class CalendarPoint {
  final String day;
  final int tokens;

  const CalendarPoint(this.day, this.tokens);
}

class AgentStats {
  final String source;
  final TokenBreakdown totals;
  final List<GroupStat> perModel;
  final List<GroupStat> perProject;
  final List<GroupStat> perInstance;
  final List<CalendarPoint> calendar;

  const AgentStats({
    required this.source,
    required this.totals,
    required this.perModel,
    required this.perProject,
    required this.perInstance,
    required this.calendar,
  });

  Map<String, dynamic> toJson() => {
        'source': source,
        'totals': totals.toJson(),
        'perModel': perModel.map((e) => e.toJson()).toList(),
        'perProject': perProject.map((e) => e.toJson()).toList(),
        'perInstance': perInstance.map((e) => e.toJson()).toList(),
        'calendar': calendar.map((c) => [c.day, c.tokens]).toList(),
      };

  factory AgentStats.fromJson(Map<String, dynamic> json) => AgentStats(
        source: json['source'] as String? ?? '',
        totals: TokenBreakdown.fromJson(
          (json['totals'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        perModel: (json['perModel'] as List? ?? const [])
            .map((e) => GroupStat.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        perProject: (json['perProject'] as List? ?? const [])
            .map((e) => GroupStat.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        perInstance: (json['perInstance'] as List? ?? const [])
            .map((e) => GroupStat.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        calendar: (json['calendar'] as List? ?? const []).map((c) {
          if (c is List && c.length >= 2) {
            return CalendarPoint(c[0].toString(), (c[1] as num).toInt());
          }
          return const CalendarPoint('', 0);
        }).toList(),
      );
}

class LiveSource {
  final String source;
  final double rpm;
  final double tpm;
  final bool active;
  final bool polling;

  const LiveSource({
    required this.source,
    required this.rpm,
    required this.tpm,
    required this.active,
    required this.polling,
  });

  Map<String, dynamic> toJson() => {
        'source': source,
        'rpm': rpm,
        'tpm': tpm,
        'active': active,
        'polling': polling,
      };

  factory LiveSource.fromJson(Map<String, dynamic> json) => LiveSource(
        source: json['source'] as String? ?? '',
        rpm: (json['rpm'] as num?)?.toDouble() ?? 0.0,
        tpm: (json['tpm'] as num?)?.toDouble() ?? 0.0,
        active: json['active'] as bool? ?? false,
        polling: json['polling'] as bool? ?? false,
      );
}

class LiveRates {
  final double rpm;
  final double tpm;
  final double costToday;
  final int tokensToday;
  final List<LiveSource> perSource;
  final List<int> spark60;
  final double budgetCostToday;
  final int budgetTokensToday;

  const LiveRates({
    this.rpm = 0.0,
    this.tpm = 0.0,
    this.costToday = 0.0,
    this.tokensToday = 0,
    this.perSource = const [],
    this.spark60 = const [],
    this.budgetCostToday = 0.0,
    this.budgetTokensToday = 0,
  });

  LiveRates copyWith({
    double? rpm,
    double? tpm,
    double? costToday,
    int? tokensToday,
    List<LiveSource>? perSource,
    List<int>? spark60,
    double? budgetCostToday,
    int? budgetTokensToday,
  }) {
    return LiveRates(
      rpm: rpm ?? this.rpm,
      tpm: tpm ?? this.tpm,
      costToday: costToday ?? this.costToday,
      tokensToday: tokensToday ?? this.tokensToday,
      perSource: perSource ?? this.perSource,
      spark60: spark60 ?? this.spark60,
      budgetCostToday: budgetCostToday ?? this.budgetCostToday,
      budgetTokensToday: budgetTokensToday ?? this.budgetTokensToday,
    );
  }

  Map<String, dynamic> toJson() => {
        'rpm': rpm,
        'tpm': tpm,
        'costToday': costToday,
        'tokensToday': tokensToday,
        'perSource': perSource.map((e) => e.toJson()).toList(),
        'spark60': spark60,
        'budgetCostToday': budgetCostToday,
        'budgetTokensToday': budgetTokensToday,
      };

  factory LiveRates.fromJson(Map<String, dynamic> json) => LiveRates(
        rpm: (json['rpm'] as num?)?.toDouble() ?? 0.0,
        tpm: (json['tpm'] as num?)?.toDouble() ?? 0.0,
        costToday: (json['costToday'] as num?)?.toDouble() ?? 0.0,
        tokensToday: (json['tokensToday'] as num?)?.toInt() ?? 0,
        perSource: (json['perSource'] as List? ?? const [])
            .map((e) => LiveSource.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        spark60: (json['spark60'] as List? ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
        budgetCostToday: (json['budgetCostToday'] as num?)?.toDouble() ?? 0.0,
        budgetTokensToday: (json['budgetTokensToday'] as num?)?.toInt() ?? 0,
      );
}

class DeltaEvent {
  final String source;
  final int timestamp;
  final int deltaTokens;
  final int deltaEvents;

  const DeltaEvent({
    required this.source,
    required this.timestamp,
    required this.deltaTokens,
    required this.deltaEvents,
  });

  int get tsMs => timestamp;
  int get tokens => deltaTokens;
  bool get isNewRequest => deltaEvents > 0;
}

class IngestOutcome {
  final int changed;
  final List<DeltaEvent> deltas;

  const IngestOutcome({
    this.changed = 0,
    this.deltas = const [],
  });
}

class FilterOptions {
  final List<String> source;
  final List<String> provider;
  final List<String> modelNorm;
  final List<String> instance;

  const FilterOptions({
    this.source = const [],
    this.provider = const [],
    this.modelNorm = const [],
    this.instance = const [],
  });

  Map<String, dynamic> toJson() => {
        'source': source,
        'provider': provider,
        'modelNorm': modelNorm,
        'instance': instance,
      };

  factory FilterOptions.fromJson(Map<String, dynamic> json) => FilterOptions(
        source:
            (json['source'] as List?)?.map((e) => e.toString()).toList() ??
                const [],
        provider:
            (json['provider'] as List?)?.map((e) => e.toString()).toList() ??
                const [],
        modelNorm:
            (json['modelNorm'] as List?)?.map((e) => e.toString()).toList() ??
                const [],
        instance:
            (json['instance'] as List?)?.map((e) => e.toString()).toList() ??
                const [],
      );
}

class CursorStatus {
  final bool hasAccessToken;
  final bool hasCookie;
  final String? lastError;

  const CursorStatus({
    required this.hasAccessToken,
    required this.hasCookie,
    this.lastError,
  });

  Map<String, dynamic> toJson() => {
        'hasAccessToken': hasAccessToken,
        'hasCookie': hasCookie,
        'lastError': lastError,
      };

  factory CursorStatus.fromJson(Map<String, dynamic> json) => CursorStatus(
        hasAccessToken: json['hasAccessToken'] as bool? ?? false,
        hasCookie: json['hasCookie'] as bool? ?? false,
        lastError: json['lastError'] as String?,
      );
}

class RemoteInstance {
  final String name;
  final String agent;
  final String host;
  final int port;
  final String username;
  final String authMode;
  final String? keyPath;
  final String? remoteHome;
  final String? remotePath;
  final int pollSecs;
  final bool importArchives;
  final bool enabled;
  final bool hasSecret;
  final String? proxyUrl;

  const RemoteInstance({
    required this.name,
    required this.agent,
    required this.host,
    this.port = 22,
    required this.username,
    this.authMode = 'key',
    this.keyPath,
    this.remoteHome,
    this.remotePath,
    this.pollSecs = 300,
    this.importArchives = false,
    this.enabled = true,
    this.hasSecret = false,
    this.proxyUrl,
  });

  void validate() {
    RemoteInstanceInput(
      name: name,
      agent: agent,
      host: host,
      port: port,
      username: username,
      authMode: authMode,
      keyPath: keyPath,
      remoteHome: remoteHome,
      remotePath: remotePath,
      pollSecs: pollSecs,
      importArchives: importArchives,
      enabled: enabled,
      proxyUrl: proxyUrl,
    ).validate();
  }

  List<String> defaultRemotePaths(String home) {
    switch (agent) {
      case 'hermes':
        return ['$home/.hermes/state.db'];
      case 'openclaw':
        return ['$home/.openclaw'];
      default:
        return const [];
    }
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'agent': agent,
        'host': host,
        'port': port,
        'username': username,
        'authMode': authMode,
        'keyPath': keyPath,
        'remoteHome': remoteHome,
        'remotePath': remotePath,
        'pollSecs': pollSecs,
        'importArchives': importArchives,
        'enabled': enabled,
        'hasSecret': hasSecret,
        'proxyUrl': proxyUrl,
      };

  factory RemoteInstance.fromJson(Map<String, dynamic> json) => RemoteInstance(
        name: json['name'] as String? ?? '',
        agent: json['agent'] as String? ?? 'hermes',
        host: json['host'] as String? ?? '',
        port: (json['port'] as num?)?.toInt() ?? 22,
        username: json['username'] as String? ?? '',
        authMode: json['authMode'] as String? ?? 'key',
        keyPath: json['keyPath'] as String?,
        remoteHome: json['remoteHome'] as String?,
        remotePath: json['remotePath'] as String?,
        pollSecs: (json['pollSecs'] as num?)?.toInt() ?? 300,
        importArchives: json['importArchives'] as bool? ?? false,
        enabled: json['enabled'] as bool? ?? true,
        hasSecret: json['hasSecret'] as bool? ?? false,
        proxyUrl: json['proxyUrl'] as String?,
      );
}

class RemoteInstanceInput {
  final String name;
  final String agent;
  final String host;
  final int port;
  final String username;
  final String authMode;
  final String? keyPath;
  final String? password;
  final String? remoteHome;
  final String? remotePath;
  final int pollSecs;
  final bool importArchives;
  final bool enabled;
  final String? proxyUrl;

  const RemoteInstanceInput({
    required this.name,
    required this.agent,
    required this.host,
    this.port = 22,
    required this.username,
    required this.authMode,
    this.keyPath,
    this.password,
    this.remoteHome,
    this.remotePath,
    this.pollSecs = 300,
    this.importArchives = false,
    this.enabled = true,
    this.proxyUrl,
  });

  void validate() {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty || trimmedName.length > 64) {
      throw ArgumentError('instance name must be between 1 and 64 characters');
    }
    if (trimmedName.toLowerCase() == kLocalInstance) {
      throw ArgumentError("'local' is reserved for this machine");
    }
    if (trimmedName.endsWith('.')) {
      throw ArgumentError('instance name may not end with a dot');
    }
    final validName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');
    if (!validName.hasMatch(trimmedName)) {
      throw ArgumentError(
        "instance name must start with a letter or number and contain only letters, numbers, '.', '_' or '-'",
      );
    }
    final stem = trimmedName.split('.').first.toUpperCase();
    const reservedNames = {'CON', 'PRN', 'AUX', 'NUL'};
    final reservedPort = stem.length == 4 &&
        (stem.startsWith('COM') || stem.startsWith('LPT')) &&
        RegExp(r'^[1-9]$').hasMatch(stem[3]);
    if (reservedNames.contains(stem) || reservedPort) {
      throw ArgumentError('instance name is reserved by Windows');
    }
    if (agent != 'hermes' && agent != 'openclaw') {
      throw ArgumentError('unsupported remote agent type');
    }
    final trimmedHost = host.trim();
    if (trimmedHost.isEmpty ||
        !RegExp(r'^[A-Za-z0-9.\-:\[\]]+$').hasMatch(trimmedHost)) {
      throw ArgumentError('host contains unsupported characters');
    }
    final trimmedUser = username.trim();
    if (trimmedUser.isEmpty ||
        !RegExp(r'^[A-Za-z0-9._\-]+$').hasMatch(trimmedUser)) {
      throw ArgumentError('username contains unsupported characters');
    }
    if (port < 1 || port > 65535) {
      throw ArgumentError('port must be between 1 and 65535');
    }
    if (authMode != 'key' && authMode != 'agent' && authMode != 'password') {
      throw ArgumentError('unsupported authentication mode');
    }
    if (pollSecs < 60 || pollSecs > 3600) {
      throw ArgumentError('poll interval must be between 60 and 3600 seconds');
    }
    for (final v in [keyPath, remoteHome, remotePath, proxyUrl]) {
      if (v != null &&
          (v.contains('\x00') || v.contains('\r') || v.contains('\n'))) {
        throw ArgumentError('paths may not contain control characters');
      }
    }
    final proxy = proxyUrl?.trim();
    if (proxy != null && proxy.isNotEmpty) {
      if (!proxy.startsWith('http://')) {
        throw ArgumentError('proxy must look like http://host:port');
      }
      final rest = proxy.substring('http://'.length).split('/').first;
      final parts = rest.split(':');
      final validProxy = parts.length == 2 &&
          parts.every(
            (p) => p.isNotEmpty && RegExp(r'^[A-Za-z0-9.\-]+$').hasMatch(p),
          );
      if (!validProxy) {
        throw ArgumentError('proxy must look like http://host:port');
      }
    }
  }

  RemoteInstance toRemoteInstance({bool hasExistingSecret = false}) {
    final p = proxyUrl?.trim();
    return RemoteInstance(
      name: name.trim(),
      agent: agent,
      host: host.trim(),
      port: port,
      username: username.trim(),
      authMode: authMode,
      keyPath: keyPath,
      remoteHome: remoteHome,
      remotePath: remotePath,
      pollSecs: pollSecs.clamp(60, 3600),
      importArchives: importArchives,
      enabled: enabled,
      hasSecret:
          (password != null && password!.isNotEmpty) || hasExistingSecret,
      proxyUrl: (p != null && p.isNotEmpty) ? p : null,
    );
  }

  RemoteInstance toInstance({bool hasExistingSecret = false}) =>
      toRemoteInstance(hasExistingSecret: hasExistingSecret);

  Map<String, dynamic> toJson() => {
        'name': name,
        'agent': agent,
        'host': host,
        'port': port,
        'username': username,
        'authMode': authMode,
        'keyPath': keyPath,
        'password': password,
        'remoteHome': remoteHome,
        'remotePath': remotePath,
        'pollSecs': pollSecs,
        'importArchives': importArchives,
        'enabled': enabled,
        'proxyUrl': proxyUrl,
      };

  factory RemoteInstanceInput.fromJson(Map<String, dynamic> json) =>
      RemoteInstanceInput(
        name: json['name'] as String? ?? '',
        agent: json['agent'] as String? ?? 'hermes',
        host: json['host'] as String? ?? '',
        port: (json['port'] as num?)?.toInt() ?? 22,
        username: json['username'] as String? ?? '',
        authMode: json['authMode'] as String? ?? 'key',
        keyPath: json['keyPath'] as String?,
        password: json['password'] as String?,
        remoteHome: json['remoteHome'] as String?,
        remotePath: json['remotePath'] as String?,
        pollSecs: (json['pollSecs'] as num?)?.toInt() ?? 300,
        importArchives: json['importArchives'] as bool? ?? false,
        enabled: json['enabled'] as bool? ?? true,
        proxyUrl: json['proxyUrl'] as String?,
      );
}

class TestStep {
  final String label;
  final bool ok;
  final String detail;

  const TestStep({
    required this.label,
    required this.ok,
    required this.detail,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'ok': ok,
        'detail': detail,
      };

  factory TestStep.fromJson(Map<String, dynamic> json) => TestStep(
        label: json['label'] as String? ?? '',
        ok: json['ok'] as bool? ?? false,
        detail: json['detail'] as String? ?? '',
      );
}

class TestReport {
  final bool ok;
  final List<TestStep> steps;

  const TestReport({
    required this.ok,
    required this.steps,
  });

  Map<String, dynamic> toJson() => {
        'ok': ok,
        'steps': steps.map((s) => s.toJson()).toList(),
      };

  factory TestReport.fromJson(Map<String, dynamic> json) => TestReport(
        ok: json['ok'] as bool? ?? false,
        steps: (json['steps'] as List? ?? const [])
            .map((s) => TestStep.fromJson((s as Map).cast<String, dynamic>()))
            .toList(),
      );
}
