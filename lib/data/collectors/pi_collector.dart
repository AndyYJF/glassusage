import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../database/app_database.dart';
import 'collector_base.dart';

class PiFileMeta {
  String sessionId;
  String? project;
  String model;
  String provider;

  PiFileMeta({
    this.sessionId = '',
    this.project,
    this.model = '',
    this.provider = '',
  });
}

class PiParsedUsage {
  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final int reasoning;
  final double? cost;

  const PiParsedUsage({
    required this.input,
    required this.output,
    required this.cacheRead,
    required this.cacheWrite,
    required this.reasoning,
    this.cost,
  });
}

class PiCollector extends Collector {
  @override
  String get id => SourceIds.pi;

  @override
  String get label => 'Pi';

  static String sessionsDir(AppSettings settings) {
    final custom = settings.customPath(SourceIds.pi);
    if (custom != null) return custom;
    final env = Platform.environment;
    final sessEnv = env['PI_CODING_AGENT_SESSION_DIR']?.trim();
    if (sessEnv != null && sessEnv.isNotEmpty) return sessEnv;
    final agentEnv = env['PI_CODING_AGENT_DIR']?.trim();
    final agentDir = (agentEnv != null && agentEnv.isNotEmpty)
        ? agentEnv
        : p.join(homeDir(), '.pi', 'agent');
    return p.join(agentDir, 'sessions');
  }

  @override
  List<String> detect(AppSettings settings) {
    final dir = sessionsDir(settings);
    return Directory(dir).existsSync() ? [dir] : const [];
  }

  @override
  ScanReport scan(ScanCtx ctx) {
    final root = ctx.rootOverride ?? sessionsDir(ctx.settings);
    if (!Directory(root).existsSync()) return ScanReport();

    final files = findFiles(root, (f) => hasExt(f, 'jsonl'));
    final report = ScanReport(
      filesSeen: files.length,
      detectedPaths: [root],
    );

    for (final path in files) {
      final res = _parseFile(ctx, path);
      if (res == null) continue;
      final (chunk, meta, events, skipped) = res;
      report.events.addAll(events);
      report.skipped += skipped;
      report.states.add(
        PendingScanState(
          source: SourceIds.pi,
          instance: ctx.instance,
          key: path,
          state: ScanState(
            offset: chunk.newOffset,
            mtimeMs: chunk.mtimeMs,
            extra: jsonEncode({
              'line_no': chunk.newLineNo,
              'session_id': meta.sessionId,
              'project': meta.project,
              'model': meta.model,
              'provider': meta.provider,
            }),
          ),
        ),
      );
    }

    report.events = finalizeEvents(report.events, ctx.pricing);
    return report;
  }

  static (JsonlChunk, PiFileMeta, List<UsageEvent>, int)? _parseFile(
    ScanCtx ctx,
    String path,
  ) {
    final stored = ctx.store.getScanState(SourceIds.pi, ctx.instance, path);
    final size = fileSize(path);
    final meta = (stored != null && size >= stored.offset && stored.extra != null)
        ? fileMetaFromExtra(stored.extra!)
        : PiFileMeta();

    JsonlChunk chunk;
    try {
      chunk = readNewLines(ctx.store, SourceIds.pi, ctx.instance, path);
    } catch (_) {
      return null;
    }
    if (chunk.lines.isEmpty) return null;

    if (meta.sessionId.isEmpty) {
      final header = _peekSessionHeader(path);
      if (header != null) {
        meta.sessionId = header.$1;
        meta.project = header.$2;
      } else {
        final fromName = sessionIdFromFilename(path);
        if (fromName != null) {
          meta.sessionId = fromName;
        }
      }
    }

    final fallbackSession =
        meta.sessionId.isEmpty ? fileStem(path) : meta.sessionId;
    final events = <UsageEvent>[];
    var skipped = 0;

    for (final (_, line) in chunk.lines) {
      dynamic v;
      try {
        v = jsonDecode(line);
      } catch (_) {
        skipped += 1;
        continue;
      }
      if (v is! Map) continue;
      final map = Map<String, dynamic>.from(v);
      final typ = map['type'] as String? ?? '';
      switch (typ) {
        case 'session':
          final id = map['id'] as String?;
          if (id != null) meta.sessionId = id;
          final cwd = map['cwd'] as String?;
          if (cwd != null) meta.project = projectLabel(cwd);
        case 'model_change':
          final m = map['modelId'] as String?;
          if (m != null) meta.model = m;
          final pr = map['provider'] as String?;
          if (pr != null) meta.provider = pr;
        case 'message':
          final msgRaw = map['message'];
          if (msgRaw is! Map) continue;
          final message = Map<String, dynamic>.from(msgRaw);
          final role = message['role'] as String? ?? '';
          if (role == 'assistant') {
            final m = message['model'] as String?;
            if (m != null) meta.model = m;
            final pr = message['provider'] as String?;
            if (pr != null) meta.provider = pr;
          }
          if (role != 'assistant' && role != 'toolResult') continue;
          final ev = eventFromUsage(
            map,
            message,
            ctx.instance,
            meta,
            fallbackSession,
            role,
          );
          if (ev != null) events.add(ev);
        case 'compaction' || 'branch_summary':
          final ev = eventFromUsage(
            map,
            map,
            ctx.instance,
            meta,
            fallbackSession,
            typ,
          );
          if (ev != null) events.add(ev);
      }
    }

    return (chunk, meta, events, skipped);
  }

  static PiFileMeta fileMetaFromExtra(String extra) {
    try {
      final v = jsonDecode(extra);
      if (v is Map) {
        return PiFileMeta(
          sessionId: v['session_id'] as String? ?? '',
          project: v['project'] as String?,
          model: v['model'] as String? ?? '',
          provider: v['provider'] as String? ?? '',
        );
      }
    } catch (_) {}
    return PiFileMeta();
  }

  static UsageEvent? eventFromUsage(
    Map<String, dynamic> entry,
    Map<String, dynamic> usageHolder,
    String instance,
    PiFileMeta meta,
    String fallbackSession,
    String kind,
  ) {
    final rawUsage = usageHolder['usage'];
    if (rawUsage is! Map) return null;
    final usage = parsedUsage(Map<String, dynamic>.from(rawUsage));
    if (usage == null) return null;

    final entryId = entry['id'] as String? ?? '';
    if (entryId.isEmpty) return null;

    final sessionId =
        meta.sessionId.isEmpty ? fallbackSession : meta.sessionId;
    final dedupKey = '$sessionId:$entryId:$kind';

    final holderModel = (usageHolder['model'] as String?)?.trim() ?? '';
    final model = holderModel.isNotEmpty
        ? holderModel
        : (meta.model.isEmpty ? 'unknown' : meta.model);

    final holderProvider = usageHolder['provider'] as String?;
    final provider = holderProvider ??
        (meta.provider.isEmpty ? null : meta.provider);

    final ts = parseTimestamp(entry['timestamp']) ??
        parseTimestamp(usageHolder['timestamp']) ??
        nowMs();

    return UsageEvent(
      source: SourceIds.pi,
      surface: SurfaceIds.cli,
      instance: instance,
      dedupKey: dedupKey,
      sessionId: sessionId,
      project: meta.project,
      model: model,
      provider: provider,
      timestamp: ts,
      inputTokens: usage.input,
      outputTokens: usage.output,
      cacheReadTokens: usage.cacheRead,
      cacheWriteTokens: usage.cacheWrite,
      reasoningTokens: usage.reasoning,
      costUsd: usage.cost,
    );
  }

  static PiParsedUsage? parsedUsage(Map<String, dynamic> usage) {
    int n(List<String> keys) {
      for (final k in keys) {
        final v = usage[k];
        if (v is num) return v.toInt();
      }
      return 0;
    }

    final input = n(const ['input', 'input_tokens']);
    final rawOutput = n(const ['output', 'output_tokens']);
    final cacheRead =
        n(const ['cacheRead', 'cache_read', 'cache_read_tokens']);
    final cacheWrite =
        n(const ['cacheWrite', 'cache_write', 'cache_write_tokens']);
    final reasoning = n(const ['reasoning', 'reasoning_tokens']);

    if (input + rawOutput + cacheRead + cacheWrite + reasoning == 0) {
      return null;
    }

    double? cost;
    final c = usage['cost'];
    if (c is num && c > 0) {
      cost = c.toDouble();
    } else if (c is Map && c['total'] is num && (c['total'] as num) > 0) {
      cost = (c['total'] as num).toDouble();
    }

    // Pi reports reasoning beside output, so fold it into output.
    return PiParsedUsage(
      input: input,
      output: rawOutput + reasoning,
      cacheRead: cacheRead,
      cacheWrite: cacheWrite,
      reasoning: reasoning,
      cost: cost,
    );
  }

  static (String, String?)? _peekSessionHeader(String path) {
    try {
      final lines = File(path)
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      // Read synchronously using readAsBytesSync prefix for simplicity in worker isolate:
      final raf = File(path).openSync(mode: FileMode.read);
      try {
        final buf = raf.readSync(4096);
        final text = utf8.decode(buf, allowMalformed: true);
        final firstLine = const LineSplitter().convert(text).firstOrNull;
        if (firstLine == null) return null;
        final v = jsonDecode(firstLine.trim());
        if (v is Map && v['type'] == 'session') {
          final id = v['id'] as String?;
          if (id == null) return null;
          final proj = projectLabel(v['cwd'] as String?);
          return (id, proj);
        }
      } finally {
        raf.closeSync();
      }
      lines.toString();
    } catch (_) {}
    return null;
  }

  static String? sessionIdFromFilename(String path) {
    final stem = fileStem(path);
    final idx = stem.lastIndexOf('_');
    if (idx < 0 || idx + 1 >= stem.length) return null;
    return stem.substring(idx + 1);
  }
}
