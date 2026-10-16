import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../database/app_database.dart';
import 'collector_base.dart';

class WireLocation {
  final String? sessionId;
  final String agent;
  final String? project;

  const WireLocation({
    this.sessionId,
    this.agent = 'main',
    this.project,
  });
}

class KimiUsage {
  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final String? model;
  final int? timeMs;
  final String? messageId;

  const KimiUsage({
    required this.input,
    required this.output,
    required this.cacheRead,
    required this.cacheWrite,
    this.model,
    this.timeMs,
    this.messageId,
  });
}

class KimiCollector extends Collector {
  @override
  String get id => SourceIds.kimi;

  @override
  String get label => 'Kimi Code';

  @override
  WriteMode get writeMode => WriteMode.upsert;

  static List<String> dataRoots(AppSettings settings) {
    final custom = settings.customPath(SourceIds.kimi);
    if (custom != null) return [custom];
    final roots = <String>[];
    final env = Platform.environment;
    final kcHome = env['KIMI_CODE_HOME']?.trim();
    if (kcHome != null && kcHome.isNotEmpty) {
      roots.add(kcHome);
    }
    final kData = env['KIMI_DATA_DIR'];
    if (kData != null) {
      for (final part in kData.split(',')) {
        final t = part.trim();
        if (t.isNotEmpty) roots.add(t);
      }
    }
    if (roots.isEmpty) {
      final home = homeDir();
      roots.add(p.join(home, '.kimi-code'));
      final legacy = p.join(home, '.kimi');
      if (Directory(legacy).existsSync()) {
        roots.add(legacy);
      }
    }
    return roots
        .where((r) => Directory(r).existsSync() || File(r).existsSync())
        .toList();
  }

  static List<String> sessionsDirs(AppSettings settings) {
    return dataRoots(settings)
        .map((r) => p.join(r, 'sessions'))
        .where((d) => Directory(d).existsSync())
        .toList();
  }

  @override
  List<String> detect(AppSettings settings) => sessionsDirs(settings);

  @override
  ScanReport scan(ScanCtx ctx) {
    final roots = ctx.rootOverride != null
        ? [ctx.rootOverride!]
        : sessionsDirs(ctx.settings);
    if (roots.isEmpty) return ScanReport();

    final projects = _projectIndex(ctx.settings, roots);
    final files = <String>[];
    for (final r in roots) {
      files.addAll(
        findFiles(r, (f) => p.basename(f).toLowerCase() == 'wire.jsonl'),
      );
    }

    final report = ScanReport(
      filesSeen: files.length,
      detectedPaths: List.from(roots),
    );

    for (final path in files) {
      JsonlChunk chunk;
      try {
        chunk = readNewLines(ctx.store, SourceIds.kimi, ctx.instance, path);
      } catch (_) {
        continue;
      }
      if (chunk.lines.isEmpty) continue;
      final loc = locationFromPath(path);
      final proj = (loc.sessionId != null ? projects[loc.sessionId!] : null) ??
          loc.project;
      final (events, skipped) =
          parseKimiLines(chunk, loc, proj, ctx.instance);
      report.events.addAll(events);
      report.skipped += skipped;
      report.states.add(
        pendingScanState(SourceIds.kimi, ctx.instance, path, chunk),
      );
    }

    report.events = finalizeEvents(report.events, ctx.pricing);
    return report;
  }

  static WireLocation locationFromPath(String path) {
    final parts = p.split(path);
    var agentsIdx = -1;
    for (var i = parts.length - 1; i >= 0; i--) {
      if (parts[i] == 'agents') {
        agentsIdx = i;
        break;
      }
    }
    if (agentsIdx >= 0) {
      final agent =
          (agentsIdx + 1 < parts.length) ? parts[agentsIdx + 1] : 'main';
      final sessionId = agentsIdx >= 1 ? parts[agentsIdx - 1] : null;
      final project = agentsIdx >= 2
          ? _projectFromWorkdirKey(parts[agentsIdx - 2])
          : null;
      return WireLocation(
        sessionId: sessionId,
        agent: agent,
        project: project,
      );
    }
    final parentName = p.basename(p.dirname(path));
    return WireLocation(
      sessionId: parentName.isEmpty ? null : parentName,
      agent: 'main',
    );
  }

  static String? _projectFromWorkdirKey(String key) {
    if (key.startsWith('wd_')) {
      return key.substring(3);
    }
    return null;
  }

  static Map<String, String> _projectIndex(
    AppSettings settings,
    List<String> sessionRoots,
  ) {
    final out = <String, String>{};
    final indexFiles = <String>[
      for (final s in sessionRoots) p.join(p.dirname(s), 'session_index.jsonl'),
    ];
    if (indexFiles.isEmpty) {
      for (final r in dataRoots(settings)) {
        indexFiles.add(p.join(r, 'session_index.jsonl'));
      }
    }
    for (final f in indexFiles) {
      final file = File(f);
      if (!file.existsSync()) continue;
      try {
        for (final line in const LineSplitter().convert(file.readAsStringSync())) {
          final v = jsonDecode(line);
          if (v is Map) {
            final id = v['sessionId'] as String?;
            final label = projectLabel(v['workDir'] as String?);
            if (id != null && label != null) {
              out[id] = label;
            }
          }
        }
      } catch (_) {}
    }
    return out;
  }

  static (List<UsageEvent>, int) parseKimiLines(
    JsonlChunk chunk,
    WireLocation loc,
    String? project,
    String instance,
  ) {
    final byKey = <String, UsageEvent>{};
    final order = <String>[];
    var skipped = 0;
    final session = loc.sessionId ?? 'unknown';

    for (final (lineNo, line) in chunk.lines) {
      dynamic v;
      try {
        v = jsonDecode(line);
      } catch (_) {
        skipped += 1;
        continue;
      }
      if (v is! Map) continue;
      final parsed = parseUsageLine(Map<String, dynamic>.from(v));
      if (parsed == null) continue;
      if (parsed.input + parsed.output + parsed.cacheRead + parsed.cacheWrite ==
          0) {
        continue;
      }

      String dedupKey;
      if (parsed.messageId != null && parsed.messageId!.isNotEmpty) {
        dedupKey = '$session:${loc.agent}:${parsed.messageId}';
      } else if (parsed.timeMs != null) {
        dedupKey = '$session:${loc.agent}:${parsed.timeMs}:$lineNo';
      } else {
        dedupKey = '$session:${loc.agent}:$lineNo';
      }

      final ev = UsageEvent(
        source: SourceIds.kimi,
        surface: SurfaceIds.cli,
        instance: instance,
        dedupKey: dedupKey,
        sessionId: session,
        project: project,
        model: parsed.model ?? 'unknown',
        provider: 'moonshot',
        timestamp: parsed.timeMs ?? nowMs(),
        inputTokens: parsed.input,
        outputTokens: parsed.output,
        cacheReadTokens: parsed.cacheRead,
        cacheWriteTokens: parsed.cacheWrite,
      );

      if (!byKey.containsKey(dedupKey)) {
        order.add(dedupKey);
      }
      byKey[dedupKey] = ev;
    }

    final events = [
      for (final k in order)
        if (byKey.containsKey(k)) byKey[k]!,
    ];
    return (events, skipped);
  }

  static KimiUsage? parseUsageLine(Map<String, dynamic> v) {
    if (v['type'] == 'usage.record') {
      return _parseUsageRecord(v);
    }
    return _parseStatusUpdate(v);
  }

  static KimiUsage? _parseUsageRecord(Map<String, dynamic> v) {
    final scope = v['usageScope'] as String? ?? 'turn';
    if (scope != 'turn') return null;
    final rawUsage = v['usage'];
    if (rawUsage is! Map) return null;
    final usage = Map<String, dynamic>.from(rawUsage);
    return KimiUsage(
      input: _usageInt(usage, const ['inputOther', 'input_other']),
      output: _usageInt(usage, const ['output']),
      cacheRead: _usageInt(usage, const ['inputCacheRead', 'input_cache_read']),
      cacheWrite: _usageInt(
        usage,
        const ['inputCacheCreation', 'input_cache_creation'],
      ),
      model: v['model'] as String?,
      timeMs: parseTimestamp(v['time']),
    );
  }

  static KimiUsage? _parseStatusUpdate(Map<String, dynamic> v) {
    final msgObj = v['message'] is Map
        ? Map<String, dynamic>.from(v['message'] as Map)
        : v;
    final isStatus =
        msgObj['type'] == 'StatusUpdate' || v['type'] == 'StatusUpdate';
    if (!isStatus) return null;
    final payload = msgObj['payload'] is Map
        ? Map<String, dynamic>.from(msgObj['payload'] as Map)
        : msgObj;
    final rawUsage = payload['token_usage'] ?? payload['tokenUsage'];
    if (rawUsage is! Map) return null;
    final usage = Map<String, dynamic>.from(rawUsage);
    return KimiUsage(
      input: _usageInt(usage, const ['input_other', 'inputOther']),
      output: _usageInt(usage, const ['output']),
      cacheRead: _usageInt(usage, const ['input_cache_read', 'inputCacheRead']),
      cacheWrite: _usageInt(
        usage,
        const ['input_cache_creation', 'inputCacheCreation'],
      ),
      model: (v['model'] as String?) ?? (payload['model'] as String?),
      timeMs: parseTimestamp(v['timestamp'] ?? v['time']),
      messageId:
          (payload['message_id'] as String?) ?? (payload['messageId'] as String?),
    );
  }

  static int _usageInt(Map<String, dynamic> usage, List<String> keys) {
    for (final k in keys) {
      final v = usage[k];
      if (v is num) return v.toInt();
    }
    return 0;
  }
}
