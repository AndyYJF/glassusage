import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../database/app_database.dart';
import 'collector_base.dart';

enum OpenClawOutcomeType { event, skip, bad }

class OpenClawParseOutcome {
  final OpenClawOutcomeType type;
  final UsageEvent? event;

  const OpenClawParseOutcome.skip()
      : type = OpenClawOutcomeType.skip,
        event = null;
  const OpenClawParseOutcome.bad()
      : type = OpenClawOutcomeType.bad,
        event = null;
  const OpenClawParseOutcome.event(this.event)
      : type = OpenClawOutcomeType.event;
}

class ProjectHolder {
  String? value;
  ProjectHolder([this.value]);
}

class OpenClawCollector extends Collector {
  @override
  String get id => SourceIds.openclaw;

  @override
  String get label => 'OpenClaw';

  static List<String> roots(AppSettings settings) {
    final custom = settings.customPath(SourceIds.openclaw);
    if (custom != null) return [custom];
    final home = homeDir();
    return ['.openclaw', '.clawdbot', '.moltbot']
        .map((d) => p.join(home, d))
        .where((dir) => Directory(dir).existsSync())
        .toList();
  }

  static bool _isLockOrSidecarDb(String path) {
    final name = p.basename(path).toLowerCase();
    return name.contains('.reindex-lock.') ||
        name.contains('.generation-lock.') ||
        name.contains('.generation-writer.') ||
        name.endsWith('.lock.sqlite');
  }

  static List<String> databasesUnder(String root) {
    final agentsDir = Directory(p.join(root, 'agents'));
    final out = <String>[];
    if (agentsDir.existsSync()) {
      try {
        for (final e in agentsDir.listSync(followLinks: false)) {
          if (e is Directory) {
            final dir = Directory(p.join(e.path, 'agent'));
            if (dir.existsSync()) {
              for (final f in dir.listSync(followLinks: false)) {
                if (f is File &&
                    (hasExt(f.path, 'sqlite') || hasExt(f.path, 'db')) &&
                    !_isLockOrSidecarDb(f.path)) {
                  out.add(f.path);
                }
              }
            }
          }
        }
      } catch (_) {}
    }
    if (out.isEmpty) {
      return findFiles(
        root,
        (f) => hasExt(f, 'sqlite') && !_isLockOrSidecarDb(f),
      );
    }
    return out;
  }

  static List<String> archivesUnder(String root) {
    return findFiles(p.join(root, 'agents'), (f) => hasExt(f, 'jsonl'));
  }

  @override
  List<String> detect(AppSettings settings) {
    final out = <String>[];
    for (final r in roots(settings)) {
      out.addAll(databasesUnder(r));
    }
    return out;
  }

  @override
  List<String> watchPaths(AppSettings settings) => roots(settings);

  @override
  ScanReport scan(ScanCtx ctx) {
    final rootDirs =
        ctx.rootOverride != null ? [ctx.rootOverride!] : roots(ctx.settings);
    final report = ScanReport();

    for (final root in rootDirs) {
      report.detectedPaths.add(root);
      for (final db in databasesUnder(root)) {
        report.filesSeen += 1;
        try {
          report.merge(scanDb(ctx, db));
        } catch (_) {
          report.skipped += 1;
        }
      }

      for (final jsonl in archivesUnder(root)) {
        report.filesSeen += 1;
        final key = 'jsonl:$jsonl';
        final mtime = mtimeMs(jsonl);
        final size = fileSize(jsonl);
        final prev =
            ctx.store.getScanState(SourceIds.openclaw, ctx.instance, key);
        if (prev != null && prev.mtimeMs == mtime && prev.offset == size) {
          continue;
        }

        String text;
        try {
          text = File(jsonl).readAsStringSync();
        } catch (_) {
          report.skipped += 1;
          continue;
        }

        final sessionProject = ProjectHolder();
        for (final line in const LineSplitter().convert(text)) {
          final outcome = parseEntry(line, ctx.instance, sessionProject);
          switch (outcome.type) {
            case OpenClawOutcomeType.event:
              report.events.add(outcome.event!);
            case OpenClawOutcomeType.skip:
              break;
            case OpenClawOutcomeType.bad:
              report.skipped += 1;
          }
        }
        report.states.add(
          PendingScanState(
            source: SourceIds.openclaw,
            instance: ctx.instance,
            key: key,
            state: ScanState(
              offset: size,
              mtimeMs: mtime,
              extra: 'jsonl',
            ),
          ),
        );
      }
    }

    report.events = finalizeEvents(report.events, ctx.pricing);
    return report;
  }

  static ScanReport scanDb(ScanCtx ctx, String dbPath) {
    final conn = openSqliteReadOnly(dbPath);
    try {
      final found = _findTranscriptTable(conn);
      if (found == null) return ScanReport();
      final (table, idCol, dataCol, orderCol) = found;

      final hasSessionCol = columnExists(conn, table, 'session_id');
      final hasSeqCol = columnExists(conn, table, 'seq');
      final hasCreatedCol = columnExists(conn, table, 'created_at');

      final key = 'sqlite:$dbPath';
      final state =
          ctx.store.getScanState(SourceIds.openclaw, ctx.instance, key) ??
              const ScanState();
      final watermark = state.offset;
      var highWater = watermark;

      final sessionSelect =
          hasSessionCol ? '"session_id" AS session_val,' : 'NULL AS session_val,';
      final rowSeqSelect =
          hasSeqCol ? '"seq" AS row_seq_val,' : 'NULL AS row_seq_val,';
      final createdSelect =
          hasCreatedCol ? '"created_at" AS created_val,' : 'NULL AS created_val,';
      final idSelect =
          idCol == 'rowid' ? 'rowid AS id_val' : '"$idCol" AS id_val';
      final orderSelect =
          orderCol == 'rowid' ? 'rowid AS seq_val' : '"$orderCol" AS seq_val';
      final orderExpr = orderCol == 'rowid' ? 'rowid' : '"$orderCol"';

      final rows = conn.select(
        '''
        SELECT $idSelect, $sessionSelect $rowSeqSelect $createdSelect "$dataCol" AS data_val, $orderSelect
        FROM "$table"
        WHERE $orderExpr >= ?1
        ORDER BY $orderExpr
        ''',
        [watermark],
      );

      final report = ScanReport();
      final defaultProject = ProjectHolder();
      final projectBySession = <String, ProjectHolder>{};

      for (final r in rows) {
        final id = r['id_val']?.toString() ?? '';
        final rowSessionId = r['session_val']?.toString() ?? '';
        final rowSeq = r['row_seq_val']?.toString() ?? '';
        final rowCreated = (r['created_val'] as num?)?.toInt();
        final data = r['data_val']?.toString() ?? '';
        final seq = (r['seq_val'] as num?)?.toInt() ?? 0;
        highWater = math.max(highWater, seq);

        final holder = rowSessionId.isNotEmpty
            ? projectBySession.putIfAbsent(
                rowSessionId,
                () => ProjectHolder(defaultProject.value),
              )
            : defaultProject;

        final outcome = parseEntry(
          data,
          ctx.instance,
          holder,
          fallbackSessionId: rowSessionId.isEmpty ? null : rowSessionId,
          fallbackTsMs: rowCreated != null ? normalizeEpoch(rowCreated.toDouble()) : null,
        );
        if (rowSessionId.isNotEmpty &&
            holder.value != null &&
            defaultProject.value == null) {
          defaultProject.value = holder.value;
        }

        switch (outcome.type) {
          case OpenClawOutcomeType.event:
            final ev = outcome.event!;
            if (ev.dedupKey.isEmpty) {
              if (rowSessionId.isNotEmpty && rowSeq.isNotEmpty) {
                ev.dedupKey = '$rowSessionId:$rowSeq';
              } else if (id.isNotEmpty && idCol != 'rowid') {
                ev.dedupKey = id;
              }
            }
            report.events.add(ev);
          case OpenClawOutcomeType.skip:
            break;
          case OpenClawOutcomeType.bad:
            report.skipped += 1;
        }
      }

      if (highWater > watermark) {
        report.states.add(
          PendingScanState(
            source: SourceIds.openclaw,
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

  static (String, String, String, String)? _findTranscriptTable(Database conn) {
    List<String> tables;
    try {
      final rows =
          conn.select("SELECT name FROM sqlite_master WHERE type = 'table'");
      tables = rows.map((r) => r['name'] as String).toList();
    } catch (_) {
      return null;
    }

    for (final candidate in [
      'transcript_events',
      'transcript',
      'entries',
      'messages',
      'transcript_entries',
      'events',
    ]) {
      final match = tables.where(
        (t) => t.toLowerCase() == candidate.toLowerCase(),
      );
      if (match.isNotEmpty) {
        final t = match.first;
        String? dataCol;
        for (final c in [
          'event_json',
          'payload_json',
          'data',
          'json',
          'payload',
          'content',
          'body',
        ]) {
          if (columnExists(conn, t, c)) {
            dataCol = c;
            break;
          }
        }
        if (dataCol == null) continue;
        String idCol = 'rowid';
        for (final c in ['id', 'entry_id', 'event_id', 'uuid']) {
          if (columnExists(conn, t, c)) {
            idCol = c;
            break;
          }
        }
        String orderCol = 'rowid';
        // Check if `rowid` is selectable on this table (non-WITHOUT ROWID).
        var hasRowId = false;
        try {
          conn.select('SELECT rowid FROM "$t" LIMIT 1');
          hasRowId = true;
        } catch (_) {}
        if (!hasRowId) {
          for (final c in ['created_at', 'timestamp', 'ts', 'seq']) {
            if (columnExists(conn, t, c)) {
              orderCol = c;
              break;
            }
          }
        }
        return (t, idCol, dataCol, orderCol);
      }
    }
    return null;
  }

  static OpenClawParseOutcome parseEntry(
    String line,
    String instance,
    ProjectHolder project, {
    String? fallbackSessionId,
    int? fallbackTsMs,
  }) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return const OpenClawParseOutcome.skip();
    dynamic v;
    try {
      v = jsonDecode(trimmed);
    } catch (_) {
      return const OpenClawParseOutcome.bad();
    }
    if (v is! Map) return const OpenClawParseOutcome.bad();
    final map = Map<String, dynamic>.from(v);

    final traceSchema = map['traceSchema'] as String?;
    final entryType = map['type'] as String? ?? '';
    if ((traceSchema != null && traceSchema.startsWith('openclaw')) ||
        entryType.contains('.')) {
      return _parseTrajectory(
        map,
        instance,
        project,
        fallbackSessionId: fallbackSessionId,
        fallbackTsMs: fallbackTsMs,
      );
    }

    if (entryType == 'session') {
      final cwd = map['cwd'] as String?;
      if (cwd != null) {
        project.value = projectLabel(cwd);
      }
      return const OpenClawParseOutcome.skip();
    }
    if (entryType != 'message') {
      return const OpenClawParseOutcome.skip();
    }
    final message = map['message'];
    if (message is! Map || message['role'] != 'assistant') {
      return const OpenClawParseOutcome.skip();
    }
    final usage = (message['usage'] ?? map['usage']);
    if (usage is! Map) {
      return const OpenClawParseOutcome.skip();
    }

    int n(List<String> keys) {
      for (final k in keys) {
        final val = usage[k];
        if (val is num) return val.toInt();
      }
      return 0;
    }

    double? nativeCost;
    final costObj = usage['cost'];
    if (costObj is Map) {
      final totalCost = (costObj['total'] as num?)?.toDouble();
      if (totalCost != null && totalCost > 0) {
        nativeCost = totalCost;
      }
    } else if (costObj is num && costObj.toDouble() > 0) {
      nativeCost = costObj.toDouble();
    }

    final ev = UsageEvent(
      source: SourceIds.openclaw,
      surface: SurfaceIds.cli,
      instance: instance,
      dedupKey: (map['id'] as String?) ??
          (message['id'] as String?) ??
          '',
      inputTokens: n(const [
        'inputTokens',
        'input',
        'input_tokens',
        'promptTokens',
        'prompt_tokens',
      ]),
      outputTokens: n(const [
        'outputTokens',
        'output',
        'output_tokens',
        'completionTokens',
        'completion_tokens',
      ]),
      cacheReadTokens: n(const [
        'cacheReadTokens',
        'cacheRead',
        'cache_read_tokens',
      ]),
      cacheWriteTokens: n(const [
        'cacheWriteTokens',
        'cacheWrite',
        'cache_write_tokens',
        'cacheCreationTokens',
        'cache_creation_tokens',
      ]),
      reasoningTokens: n(const [
        'reasoningTokens',
        'reasoning',
        'reasoning_tokens',
      ]),
      costUsd: nativeCost,
    );
    if (ev.isEmpty) return const OpenClawParseOutcome.skip();

    ev.model = (map['model'] as String?) ??
        (message['model'] as String?) ??
        'unknown';
    ev.provider =
        (map['provider'] as String?) ?? (message['provider'] as String?);
    ev.sessionId = (map['sessionId'] as String?) ??
        (map['session_id'] as String?) ??
        (message['sessionId'] as String?) ??
        fallbackSessionId ??
        '';
    ev.project = project.value;
    ev.timestamp = parseTimestamp(
          map['timestamp'] ??
              map['time'] ??
              map['createdAt'] ??
              message['timestamp'],
        ) ??
        fallbackTsMs ??
        nowMs();
    if (ev.dedupKey.isEmpty) {
      ev.dedupKey = shaKey([
        ev.sessionId,
        ev.model,
        ev.timestamp.toString(),
        ev.totalTokens.toString(),
      ]);
    }
    return OpenClawParseOutcome.event(ev);
  }

  static OpenClawParseOutcome _parseTrajectory(
    Map<String, dynamic> v,
    String instance,
    ProjectHolder project, {
    String? fallbackSessionId,
    int? fallbackTsMs,
  }) {
    final entryType = v['type'] as String? ?? '';
    final dataObj = v['data'] is Map
        ? Map<String, dynamic>.from(v['data'] as Map)
        : null;

    if (entryType == 'session.started') {
      final cwd = (v['workspaceDir'] as String?) ??
          (dataObj?['workspaceDir'] as String?);
      if (cwd != null) {
        project.value = projectLabel(cwd);
      }
      return const OpenClawParseOutcome.skip();
    }
    if (entryType != 'model.completed') {
      return const OpenClawParseOutcome.skip();
    }

    final promptCache = dataObj?['promptCache'] is Map
        ? Map<String, dynamic>.from(dataObj!['promptCache'] as Map)
        : null;
    final rawUsage =
        promptCache?['lastCallUsage'] ?? dataObj?['usage'] ?? v['usage'];
    if (rawUsage is! Map) {
      return const OpenClawParseOutcome.skip();
    }
    final usage = Map<String, dynamic>.from(rawUsage);

    int n(String camel, String snake) =>
        ((usage[camel] ?? usage[snake]) as num?)?.toInt() ?? 0;

    final ev = UsageEvent(
      source: SourceIds.openclaw,
      surface: SurfaceIds.cli,
      instance: instance,
      dedupKey: '',
      inputTokens: n('input', 'inputTokens'),
      outputTokens: n('output', 'outputTokens'),
      cacheReadTokens: n('cacheRead', 'cacheReadTokens'),
      cacheWriteTokens: n('cacheWrite', 'cacheWriteTokens'),
      reasoningTokens: n('reasoningTokens', 'reasoning_tokens'),
    );
    if (ev.isEmpty) return const OpenClawParseOutcome.skip();

    ev.model =
        (v['modelId'] as String?) ?? (v['model'] as String?) ?? 'unknown';
    ev.provider = v['provider'] as String?;
    ev.sessionId = (v['sessionId'] as String?) ??
        (v['traceId'] as String?) ??
        fallbackSessionId ??
        '';
    if (project.value == null) {
      final cwd = v['workspaceDir'] as String?;
      if (cwd != null) {
        project.value = projectLabel(cwd);
      }
    }
    ev.project = project.value;
    ev.timestamp =
        parseTimestamp(v['ts'] ?? v['timestamp']) ?? fallbackTsMs ?? nowMs();

    final seq = (v['seq'] as num?)?.toInt().toString() ?? '';
    ev.dedupKey = (ev.sessionId.isNotEmpty && seq.isNotEmpty)
        ? '${ev.sessionId}:$seq'
        : shaKey([
            ev.sessionId,
            ev.model,
            ev.timestamp.toString(),
            ev.totalTokens.toString(),
          ]);

    return OpenClawParseOutcome.event(ev);
  }
}
