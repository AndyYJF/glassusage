import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../database/app_database.dart';
import 'collector_base.dart';
import 'zstd_decoder.dart';

const int kDshFoldVersion = 2;
const String kDshFoldMarker = 'dsh-fold-version';

class DshFileMeta {
  String sessionId;
  String? project;
  String model;
  String provider;

  DshFileMeta({
    this.sessionId = '',
    this.project,
    this.model = '',
    this.provider = '',
  });
}

class DshUsageFold {
  int slotSeq;
  bool slotOpen;
  int? slotTurn;
  int? slotStep;
  int input;
  int output;
  int cacheRead;
  int cacheWrite;
  int reasoning;

  DshUsageFold({
    this.slotSeq = 0,
    this.slotOpen = false,
    this.slotTurn,
    this.slotStep,
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.reasoning = 0,
  });

  bool matches(DshParsedUsage u) {
    return input == u.input &&
        output == u.output &&
        cacheRead == u.cacheRead &&
        cacheWrite == u.cacheWrite &&
        reasoning == u.reasoning;
  }

  void remember(DshParsedUsage u) {
    input = u.input;
    output = u.output;
    cacheRead = u.cacheRead;
    cacheWrite = u.cacheWrite;
    reasoning = u.reasoning;
  }
}

class DshParsedUsage {
  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final int reasoning;

  const DshParsedUsage({
    required this.input,
    required this.output,
    required this.cacheRead,
    required this.cacheWrite,
    required this.reasoning,
  });
}

class DshCollector extends Collector {
  @override
  String get id => SourceIds.dsh;

  @override
  String get label => 'DeepSeek Harness';

  @override
  WriteMode get writeMode => WriteMode.upsert;

  static String sessionsDir(AppSettings settings) {
    final custom = settings.customPath(SourceIds.dsh);
    if (custom != null) return custom;
    final env = Platform.environment['DSH_HOME']?.trim();
    if (env != null && env.isNotEmpty) {
      return p.join(env, 'sessions');
    }
    return p.join(homeDir(), '.dsh', 'sessions');
  }

  @override
  List<String> detect(AppSettings settings) {
    final dir = sessionsDir(settings);
    return Directory(dir).existsSync() ? [dir] : [];
  }

  @override
  ScanReport scan(ScanCtx ctx) {
    final root = ctx.rootOverride ?? sessionsDir(ctx.settings);
    if (!Directory(root).existsSync() && !File(root).existsSync()) {
      return ScanReport();
    }

    final report = ScanReport(
      detectedPaths: Directory(root).existsSync() ? [root] : [],
    );

    if (_storedFoldVersion(ctx.store, ctx.instance) < kDshFoldVersion) {
      ctx.store.deleteSource(SourceIds.dsh, instance: ctx.instance);
      ctx.store.clearScanState(SourceIds.dsh, instance: ctx.instance);
      report.states.add(_foldMarker(ctx.instance));
    }

    final files = chooseLatestDshLogs(findFiles(root, _isSessionLog));
    report.filesSeen = files.length;

    for (final path in files) {
      final parsed = _parseFile(ctx, path);
      if (parsed == null) continue;
      report.events.addAll(parsed.$4);
      report.skipped += parsed.$5;
      report.states.add(
        PendingScanState(
          source: SourceIds.dsh,
          instance: ctx.instance,
          key: path,
          state: ScanState(
            offset: parsed.$1.newOffset,
            mtimeMs: parsed.$1.mtimeMs,
            extra: jsonEncode(
              _fileStateJson(parsed.$2, parsed.$3, parsed.$1.newLineNo),
            ),
          ),
        ),
      );
    }

    report.events = finalizeEvents(report.events, ctx.pricing);
    return report;
  }
}

bool _isSessionLog(String path) => dshSessionLogRank(path) != null;

(int, bool)? dshSessionLogRank(String path) {
  final name = p.basename(path);
  final zstd = name.endsWith('.zstd') || name.endsWith('.zst');
  String base = name;
  if (base.endsWith('.zstd')) {
    base = base.substring(0, base.length - 5);
  } else if (base.endsWith('.zst')) {
    base = base.substring(0, base.length - 4);
  }
  if (base == 'session.jsonl') {
    return (0, zstd);
  }
  if (base.startsWith('session.v') && base.endsWith('.jsonl')) {
    final verStr = base.substring(
      'session.v'.length,
      base.length - '.jsonl'.length,
    );
    final ver = int.tryParse(verStr);
    if (ver != null && ver >= 0) {
      return (ver, zstd);
    }
  }
  return null;
}

List<String> chooseLatestDshLogs(List<String> files) {
  final best = <String, (int, bool, String)>{};
  for (final path in files) {
    final parent = p.dirname(path);
    final rank = dshSessionLogRank(path);
    if (rank == null) continue;
    final cur = best[parent];
    final replace = cur == null ||
        rank.$1 > cur.$1 ||
        (rank.$1 == cur.$1 && rank.$2 && !cur.$2);
    if (replace) {
      best[parent] = (rank.$1, rank.$2, path);
    }
  }
  final out = best.values.map((e) => e.$3).toList()..sort();
  return out;
}

int _storedFoldVersion(AppDatabase store, String instance) {
  final state = store.getScanState(SourceIds.dsh, instance, kDshFoldMarker);
  final extra = state?.extra;
  if (extra == null) return 0;
  try {
    final decoded = jsonDecode(extra);
    if (decoded is Map) {
      return (decoded['fold_version'] as num?)?.toInt() ?? 0;
    }
  } catch (_) {}
  return 0;
}

PendingScanState _foldMarker(String instance) {
  return PendingScanState(
    source: SourceIds.dsh,
    instance: instance,
    key: kDshFoldMarker,
    state: ScanState(
      offset: kDshFoldVersion,
      mtimeMs: 0,
      extra: '{"fold_version":$kDshFoldVersion}',
    ),
  );
}

(JsonlChunk, DshFileMeta, DshUsageFold, List<UsageEvent>, int)? _parseFile(
  ScanCtx ctx,
  String path,
) {
  final stored = ctx.store.getScanState(SourceIds.dsh, ctx.instance, path);
  final size = fileSize(path);
  final truncated = stored != null && size < stored.offset;
  final meta = truncated
      ? DshFileMeta()
      : (stored?.extra != null
          ? dshFileMetaFromExtra(stored!.extra!)
          : DshFileMeta());
  final fold = truncated
      ? DshUsageFold()
      : (stored?.extra != null
          ? dshFoldFromExtra(stored!.extra!)
          : DshUsageFold());

  final chunk = _isZstd(path)
      ? readNewZstdLines(ctx.store, SourceIds.dsh, ctx.instance, path)
      : readNewLines(ctx.store, SourceIds.dsh, ctx.instance, path);
  if (chunk.lines.isEmpty) return null;

  if (meta.sessionId.isEmpty) {
    final dirId = dshSessionIdFromDir(path);
    if (dirId != null) meta.sessionId = dirId;
    meta.project ??= dshProjectFromSessionPath(path);
  }

  final fallbackSession = meta.sessionId.isEmpty
      ? p.basenameWithoutExtension(p.dirname(path))
      : meta.sessionId;

  final events = <UsageEvent>[];
  var skipped = 0;

  for (final (_, line) in chunk.lines) {
    Map<String, dynamic> v;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) {
        skipped++;
        continue;
      }
      v = decoded;
    } catch (_) {
      skipped++;
      continue;
    }
    applyDshEntry(
      v,
      ctx.instance,
      meta,
      fallbackSession,
      fold,
      events,
    );
  }

  return (chunk, meta, fold, events, skipped);
}

void applyDshSessionHeader(Map<String, dynamic> v, DshFileMeta meta) {
  final id = v['id'] as String?;
  if (id != null) meta.sessionId = id;
  final cwd = v['cwd'] as String?;
  if (cwd != null) meta.project = projectLabel(cwd);
}

void applyDshRequestHeader(Map<String, dynamic> v, DshFileMeta meta) {
  final data = v['data'];
  if (data is! Map) return;
  final header = data['header'];
  if (header is! Map) return;
  final config = header['config'];
  if (config is! Map) return;
  final m = config['model'] as String?;
  if (m != null && m.isNotEmpty) meta.model = m;
  final prov = config['provider'] as String?;
  if (prov != null && prov.isNotEmpty) meta.provider = prov;
}

void applyDshEntry(
  Map<String, dynamic> entry,
  String instance,
  DshFileMeta meta,
  String fallbackSession,
  DshUsageFold fold,
  List<UsageEvent> events,
) {
  final type = entry['type'] as String? ?? '';
  switch (type) {
    case 'session':
      applyDshSessionHeader(entry, meta);
      break;
    case 'request/header':
      applyDshRequestHeader(entry, meta);
      break;
    case 'llm/retry-started':
      _noteRetry(entry, fold);
      break;
    case 'compaction/summary':
      final ev = _eventFromCompaction(entry, instance, meta, fallbackSession);
      if (ev != null) events.add(ev);
      break;
    case 'assistant/message':
    case 'assistant/attempt':
      final ev = _eventFromFolded(entry, instance, meta, fallbackSession, fold);
      if (ev != null) events.add(ev);
      break;
  }
}

void _noteRetry(Map<String, dynamic> entry, DshUsageFold fold) {
  final data = entry['data'];
  final turn = data is Map ? (data['turn'] as num?)?.toInt() : null;
  final step = data is Map ? (data['step'] as num?)?.toInt() : null;
  if (fold.slotOpen && fold.slotTurn == turn && fold.slotStep == step) {
    fold.slotOpen = false;
  }
}

UsageEvent? _eventFromFolded(
  Map<String, dynamic> entry,
  String instance,
  DshFileMeta meta,
  String fallbackSession,
  DshUsageFold fold,
) {
  final rawUsage = _usageOf(entry);
  if (rawUsage == null) return null;
  final usage = _parsedUsage(rawUsage);
  if (usage == null) return null;
  final seq = (entry['seq'] as num?)?.toInt();
  if (seq == null) return null;
  final data = entry['data'] is Map<String, dynamic>
      ? entry['data'] as Map<String, dynamic>
      : entry;
  final turn = (data['turn'] as num?)?.toInt();
  final step = (data['step'] as num?)?.toInt();
  final same = fold.slotOpen &&
      turn != null &&
      fold.slotTurn == turn &&
      fold.slotStep == step;
  if (same && fold.matches(usage)) {
    return null;
  }
  final slotSeq = same ? fold.slotSeq : seq;
  if (!same) {
    fold.slotOpen = true;
    fold.slotTurn = turn;
    fold.slotStep = step;
    fold.slotSeq = seq;
  }
  fold.remember(usage);
  return _eventFromUsage(
    entry,
    's:$slotSeq',
    usage,
    instance,
    meta,
    fallbackSession,
  );
}

UsageEvent? _eventFromCompaction(
  Map<String, dynamic> entry,
  String instance,
  DshFileMeta meta,
  String fallbackSession,
) {
  final data = entry['data'];
  if (data is! Map) return null;
  final rawUsage = data['usage'];
  if (rawUsage is! Map<String, dynamic>) return null;
  final usage = _parsedUsage(rawUsage);
  if (usage == null) return null;
  final seq = (entry['seq'] as num?)?.toInt();
  if (seq == null) return null;
  return _eventFromUsage(
    entry,
    'c:$seq',
    usage,
    instance,
    meta,
    fallbackSession,
  );
}

Map<String, dynamic>? _usageOf(Map<String, dynamic> entry) {
  final ty = entry['type'] as String?;
  final data = entry['data'];
  if (ty == null || data is! Map<String, dynamic>) return null;
  if (ty == 'assistant/message') {
    final u = data['usage'];
    if (u is Map<String, dynamic>) return u;
  }
  if (ty == 'assistant/message' || ty == 'assistant/attempt') {
    final stream = data['stream'];
    if (stream is List) {
      return _lastStreamUsage(stream);
    }
  }
  return null;
}

Map<String, dynamic>? _lastStreamUsage(List<dynamic> stream) {
  for (var i = stream.length - 1; i >= 0; i--) {
    final item = stream[i];
    if (item is! Map) continue;
    if (item['type'] != 'chunk') continue;
    final chunk = item['chunk'];
    if (chunk is! Map) continue;
    if (chunk['type'] != 'usage') continue;
    final u = chunk['usage'];
    if (u is Map<String, dynamic>) return u;
  }
  return null;
}

UsageEvent _eventFromUsage(
  Map<String, dynamic> entry,
  String slot,
  DshParsedUsage usage,
  String instance,
  DshFileMeta meta,
  String fallbackSession,
) {
  final data = entry['data'] is Map<String, dynamic>
      ? entry['data'] as Map<String, dynamic>
      : entry;
  final sessionId =
      meta.sessionId.isEmpty ? fallbackSession : meta.sessionId;
  final msg = data['message'];
  final src = msg is Map ? msg['source'] : null;
  String model = meta.model.isEmpty ? 'unknown' : meta.model;
  String? provider = meta.provider.isEmpty ? null : meta.provider;
  if (src is Map) {
    final m = src['model'] as String?;
    if (m != null && m.isNotEmpty) model = m;
    final prov = src['provider'] as String?;
    if (prov != null && prov.isNotEmpty) provider = prov;
  }

  return UsageEvent(
    source: SourceIds.dsh,
    surface: SurfaceIds.cli,
    instance: instance,
    sessionId: sessionId,
    project: meta.project,
    model: model,
    provider: provider,
    timestamp: parseTimestamp(entry['time']) ??
        DateTime.now().millisecondsSinceEpoch,
    inputTokens: usage.input,
    outputTokens: usage.output,
    cacheReadTokens: usage.cacheRead,
    cacheWriteTokens: usage.cacheWrite,
    reasoningTokens: usage.reasoning,
    dedupKey: '$sessionId:$slot',
  );
}

DshParsedUsage? _parsedUsage(Map<String, dynamic> usage) {
  int n(List<String> keys) {
    for (final k in keys) {
      final v = usage[k];
      if (v is num) return v.toInt();
    }
    return 0;
  }

  final input = n(const ['inputTokens', 'uncachedInputTokens', 'input']);
  final output = n(const ['outputTokens', 'output']);
  final cacheRead = n(const ['cacheReadTokens', 'cacheRead']);
  final cacheWrite = n(const ['cacheWriteTokens', 'cacheWrite']);
  final reasoning = n(const ['reasoningTokens', 'reasoning']);
  if (input + output + cacheRead + cacheWrite + reasoning == 0) {
    return null;
  }
  return DshParsedUsage(
    input: input,
    output: output,
    cacheRead: cacheRead,
    cacheWrite: cacheWrite,
    reasoning: reasoning,
  );
}

DshFileMeta dshFileMetaFromExtra(String extra) {
  try {
    final m = jsonDecode(extra);
    if (m is Map) {
      return DshFileMeta(
        sessionId: m['session_id'] as String? ?? '',
        project: m['project'] as String?,
        model: m['model'] as String? ?? '',
        provider: m['provider'] as String? ?? '',
      );
    }
  } catch (_) {}
  return DshFileMeta();
}

DshUsageFold dshFoldFromExtra(String extra) {
  try {
    final m = jsonDecode(extra);
    if (m is Map) {
      return DshUsageFold(
        slotSeq: (m['slot_seq'] as num?)?.toInt() ?? 0,
        slotOpen: m['slot_open'] as bool? ?? false,
        slotTurn: (m['slot_turn'] as num?)?.toInt(),
        slotStep: (m['slot_step'] as num?)?.toInt(),
        input: (m['slot_input'] as num?)?.toInt() ?? 0,
        output: (m['slot_output'] as num?)?.toInt() ?? 0,
        cacheRead: (m['slot_cache_read'] as num?)?.toInt() ?? 0,
        cacheWrite: (m['slot_cache_write'] as num?)?.toInt() ?? 0,
        reasoning: (m['slot_reasoning'] as num?)?.toInt() ?? 0,
      );
    }
  } catch (_) {}
  return DshUsageFold();
}

Map<String, dynamic> _fileStateJson(
  DshFileMeta meta,
  DshUsageFold fold,
  int lineNo,
) {
  return {
    'line_no': lineNo,
    'session_id': meta.sessionId,
    'project': meta.project,
    'model': meta.model,
    'provider': meta.provider,
    'slot_seq': fold.slotSeq,
    'slot_open': fold.slotOpen,
    'slot_turn': fold.slotTurn,
    'slot_step': fold.slotStep,
    'slot_input': fold.input,
    'slot_output': fold.output,
    'slot_cache_read': fold.cacheRead,
    'slot_cache_write': fold.cacheWrite,
    'slot_reasoning': fold.reasoning,
  };
}

bool _isZstd(String path) {
  final n = p.basename(path);
  return n.endsWith('.zstd') || n.endsWith('.zst');
}

String? dshSessionIdFromDir(String path) {
  final parent = p.dirname(path);
  final name = p.basename(parent);
  return name.isEmpty ? null : name;
}

String? dshProjectFromSessionPath(String path) {
  final sessionDir = p.dirname(path);
  final projectDir = p.dirname(sessionDir);
  final name = p.basename(projectDir);
  final trimmed = name.replaceAll(RegExp(r'^-+|-+$'), '');
  if (trimmed.isEmpty || trimmed == '_no-cwd') return null;
  final parts = trimmed.split('-');
  return parts.isEmpty ? null : parts.last;
}

JsonlChunk readNewZstdLines(
  AppDatabase store,
  String source,
  String instance,
  String path,
) {
  final state =
      store.getScanState(source, instance, path) ?? const ScanState();
  final size = fileSize(path);
  final mtime = mtimeMs(path);

  var offset = size < state.offset ? 0 : state.offset;
  var lineNo = size < state.offset ? 0 : lineNoFromExtra(state.extra);

  if (offset >= size) {
    return JsonlChunk(
      lines: const [],
      newOffset: offset,
      newLineNo: lineNo,
      mtimeMs: mtime,
    );
  }

  try {
    final bytes = File(path).readAsBytesSync();
    if (offset > bytes.length) {
      return JsonlChunk(
        lines: const [],
        newOffset: offset,
        newLineNo: lineNo,
        mtimeMs: mtime,
      );
    }
    final (consumed, frames) = decodeCompleteZstdFrames(
      bytes.sublist(offset),
    );
    final lines = <(int, String)>[];
    for (final text in frames) {
      for (final raw in const LineSplitter().convert(text)) {
        lineNo++;
        final t = raw.trim();
        if (t.isNotEmpty) {
          lines.add((lineNo, t));
        }
      }
    }
    return JsonlChunk(
      lines: lines,
      newOffset: offset + consumed,
      newLineNo: lineNo,
      mtimeMs: mtime,
    );
  } catch (_) {
    return JsonlChunk(
      lines: const [],
      newOffset: offset,
      newLineNo: lineNo,
      mtimeMs: mtime,
    );
  }
}
