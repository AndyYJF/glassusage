import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../database/app_database.dart';
import 'collector_base.dart';

class OpenCodeCollector extends Collector {
  @override
  String get id => SourceIds.opencode;

  @override
  String get label => 'OpenCode';

  @override
  WriteMode get writeMode => WriteMode.upsert;

  static List<String> dataDirs(AppSettings settings) {
    final custom = settings.customPath(SourceIds.opencode);
    if (custom != null) return [custom];
    final dirs = <String>[];
    final env = Platform.environment;
    final ocData = env['OPENCODE_DATA_DIR']?.trim();
    if (ocData != null && ocData.isNotEmpty) {
      dirs.add(ocData);
    }
    final xdg = env['XDG_DATA_HOME']?.trim();
    if (xdg != null && xdg.isNotEmpty) {
      dirs.add(p.join(xdg, 'opencode'));
    }
    dirs.add(p.join(homeDir(), '.local', 'share', 'opencode'));
    final local = localDataDir();
    if (local != null) {
      dirs.add(p.join(local, 'opencode'));
    }
    return dirs.where((d) => Directory(d).existsSync()).toSet().toList();
  }

  static List<String> databases(AppSettings settings) {
    final out = <String>[];
    for (final dir in dataDirs(settings)) {
      try {
        for (final entry in Directory(dir).listSync(followLinks: false)) {
          if (entry is File) {
            final name = p.basename(entry.path);
            if (name.startsWith('opencode') && name.endsWith('.db')) {
              out.add(entry.path);
            }
          }
        }
      } catch (_) {}
    }
    return out;
  }

  @override
  List<String> detect(AppSettings settings) => databases(settings);

  @override
  List<String> watchPaths(AppSettings settings) => dataDirs(settings);

  @override
  ScanReport scan(ScanCtx ctx) {
    final dbs = ctx.rootOverride != null
        ? findFiles(ctx.rootOverride!, (f) => hasExt(f, 'db'))
        : databases(ctx.settings);

    final report = ScanReport(
      filesSeen: dbs.length,
      detectedPaths: List.from(dbs),
    );

    for (final dbPath in dbs) {
      try {
        report.merge(scanDb(ctx, dbPath));
      } catch (_) {
        report.skipped += 1;
      }
    }

    for (final dir in dataDirs(ctx.settings)) {
      final legacy = p.join(dir, 'storage', 'message');
      if (Directory(legacy).existsSync()) {
        try {
          report.merge(scanLegacy(ctx, legacy));
        } catch (_) {}
      }
    }

    report.events = finalizeEvents(report.events, ctx.pricing);
    return report;
  }

  static ScanReport scanDb(ScanCtx ctx, String dbPath) {
    final conn = openSqliteReadOnly(dbPath);
    try {
      final key = 'sqlite:$dbPath';
      final state =
          ctx.store.getScanState(SourceIds.opencode, ctx.instance, key) ??
              const ScanState();
      final watermark = state.offset;
      var highWater = watermark;
      final report = ScanReport();

      if (tableExists(conn, 'message')) {
        final dirs = <String, String>{};
        if (tableExists(conn, 'session')) {
          try {
            final sessRows = conn.select('SELECT id, directory FROM session');
            for (final s in sessRows) {
              final sid = s['id'] as String?;
              final dir = s['directory'] as String?;
              if (sid != null && dir != null) {
                dirs[sid] = dir;
              }
            }
          } catch (_) {}
        }

        final rows = conn.select(
          '''
          SELECT id, session_id, time_created, time_updated, data
          FROM message
          WHERE time_updated >= ?1
          ORDER BY time_updated
          ''',
          [watermark],
        );

        for (final r in rows) {
          final id = r['id'] as String;
          final sessionId = r['session_id'] as String? ?? '';
          final created = (r['time_created'] as num?)?.toInt() ?? nowMs();
          final updated = (r['time_updated'] as num?)?.toInt() ?? created;
          final data = r['data'] as String? ?? '';
          highWater = math.max(highWater, updated);

          dynamic v;
          try {
            v = jsonDecode(data);
          } catch (_) {
            report.skipped += 1;
            continue;
          }
          if (v is! Map || v['role'] != 'assistant') continue;
          final tokens = v['tokens'];
          if (tokens is! Map) continue;

          int n(List<String> path) {
            dynamic cur = tokens;
            for (final seg in path) {
              if (cur is Map && cur.containsKey(seg)) {
                cur = cur[seg];
              } else {
                return 0;
              }
            }
            return (cur is num) ? cur.toInt() : 0;
          }

          final modelObj = v['model'];
          final model = (modelObj is Map ? modelObj['modelID'] as String? : null) ??
              (v['modelID'] as String?) ??
              'unknown';
          final provider =
              (modelObj is Map ? modelObj['providerID'] as String? : null) ??
                  (v['providerID'] as String?);
          final pathObj = v['path'];
          final cwd = (pathObj is Map ? pathObj['cwd'] as String? : null) ??
              dirs[sessionId];
          final timeObj = v['time'];
          final ts = (timeObj is Map
                  ? parseTimestamp(timeObj['created'])
                  : null) ??
              created;
          final rawCost = (v['cost'] as num?)?.toDouble();

          final ev = UsageEvent(
            source: SourceIds.opencode,
            surface: SurfaceIds.cli,
            instance: ctx.instance,
            dedupKey: id,
            sessionId: sessionId,
            project: projectLabel(cwd),
            model: model,
            provider: provider,
            timestamp: ts,
            inputTokens: n(const ['input']),
            outputTokens: n(const ['output']),
            reasoningTokens: n(const ['reasoning']),
            cacheReadTokens: n(const ['cache', 'read']),
            cacheWriteTokens: n(const ['cache', 'write']),
            costUsd: (rawCost != null && rawCost > 0.0) ? rawCost : null,
          );
          if (!ev.isEmpty) {
            report.events.add(ev);
          }
        }
      } else if (tableExists(conn, 'session')) {
        final rows = conn.select(
          '''
          SELECT id, directory, model, cost, tokens_input, tokens_output, tokens_reasoning,
                 tokens_cache_read, tokens_cache_write, time_created, time_updated
          FROM session WHERE time_updated >= ?1
          ''',
          [watermark],
        );
        for (final r in rows) {
          final id = r['id'] as String;
          final dir = r['directory'] as String?;
          final model = r['model'] as String? ?? 'unknown';
          final cost = (r['cost'] as num?)?.toDouble();
          final ti = (r['tokens_input'] as num?)?.toInt() ?? 0;
          final to = (r['tokens_output'] as num?)?.toInt() ?? 0;
          final tr = (r['tokens_reasoning'] as num?)?.toInt() ?? 0;
          final tcr = (r['tokens_cache_read'] as num?)?.toInt() ?? 0;
          final tcw = (r['tokens_cache_write'] as num?)?.toInt() ?? 0;
          final created = (r['time_created'] as num?)?.toInt() ?? nowMs();
          final updated = (r['time_updated'] as num?)?.toInt() ?? created;
          highWater = math.max(highWater, updated);

          final ev = UsageEvent(
            source: SourceIds.opencode,
            surface: SurfaceIds.cli,
            instance: ctx.instance,
            dedupKey: 'session:$id',
            sessionId: id,
            project: projectLabel(dir),
            model: model,
            inputTokens: ti,
            outputTokens: to,
            reasoningTokens: tr,
            cacheReadTokens: tcr,
            cacheWriteTokens: tcw,
            costUsd: (cost != null && cost > 0.0) ? cost : null,
            timestamp: created,
          );
          if (!ev.isEmpty) {
            report.events.add(ev);
          }
        }
      }

      if (highWater > watermark) {
        report.states.add(
          PendingScanState(
            source: SourceIds.opencode,
            instance: ctx.instance,
            key: key,
            state: ScanState(
              offset: highWater,
              mtimeMs: mtimeMs(dbPath),
            ),
          ),
        );
      }
      return report;
    } finally {
      conn.dispose();
    }
  }

  static ScanReport scanLegacy(ScanCtx ctx, String dir) {
    final key = 'legacy:$dir';
    if (ctx.store.getScanState(SourceIds.opencode, ctx.instance, key) != null) {
      return ScanReport();
    }
    final report = ScanReport();
    for (final file in findFiles(dir, (f) => hasExt(f, 'json'))) {
      dynamic v;
      try {
        v = jsonDecode(File(file).readAsStringSync());
      } catch (_) {
        report.skipped += 1;
        continue;
      }
      if (v is! Map || v['role'] != 'assistant') continue;
      final tokens = v['tokens'];
      if (tokens is! Map) continue;

      int n(List<String> path) {
        dynamic cur = tokens;
        for (final seg in path) {
          if (cur is Map && cur.containsKey(seg)) {
            cur = cur[seg];
          } else {
            return 0;
          }
        }
        return (cur is num) ? cur.toInt() : 0;
      }

      final id = (v['id'] as String?) ?? fileStem(file);
      final timeObj = v['time'];
      final ts = (timeObj is Map ? parseTimestamp(timeObj['created']) : null) ??
          nowMs();
      final ev = UsageEvent(
        source: SourceIds.opencode,
        surface: SurfaceIds.cli,
        instance: ctx.instance,
        dedupKey: id,
        sessionId: (v['sessionID'] as String?) ?? '',
        model: (v['modelID'] as String?) ?? 'unknown',
        provider: v['providerID'] as String?,
        timestamp: ts,
        inputTokens: n(const ['input']),
        outputTokens: n(const ['output']),
        reasoningTokens: n(const ['reasoning']),
        cacheReadTokens: n(const ['cache', 'read']),
        cacheWriteTokens: n(const ['cache', 'write']),
      );
      if (!ev.isEmpty) {
        report.events.add(ev);
      }
    }
    report.states.add(
      PendingScanState(
        source: SourceIds.opencode,
        instance: ctx.instance,
        key: key,
        state: ScanState(
          offset: 1,
          mtimeMs: nowMs(),
          extra: 'imported',
        ),
      ),
    );
    return report;
  }
}
