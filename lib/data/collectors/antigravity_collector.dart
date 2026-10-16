import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../database/app_database.dart';
import 'collector_base.dart';
import 'protoscan.dart';

class AntigravityCollector extends Collector {
  @override
  String get id => SourceIds.antigravity;

  @override
  String get label => 'Antigravity';

  @override
  WriteMode get writeMode => WriteMode.upsert;

  static String geminiHome(AppSettings settings) {
    return resolveRoot(
      settings,
      SourceIds.antigravity,
      'GEMINI_CLI_HOME',
      p.join(homeDir(), '.gemini'),
    );
  }

  static List<String> ideDirs(AppSettings settings) {
    final home = geminiHome(settings);
    return ['antigravity', 'antigravity-ide']
        .map((d) => p.join(home, d, 'conversations'))
        .where((dir) => Directory(dir).existsSync())
        .toList();
  }

  static List<String> cliDirs(AppSettings settings) {
    final home = geminiHome(settings);
    final dir = p.join(home, 'antigravity-cli', 'conversations');
    return Directory(dir).existsSync() ? [dir] : const [];
  }

  @override
  List<String> detect(AppSettings settings) {
    return [
      ...cliDirs(settings),
      ...ideDirs(settings),
    ];
  }

  @override
  ScanReport scan(ScanCtx ctx) {
    final report = ScanReport();

    for (final dir in cliDirs(ctx.settings)) {
      report.detectedPaths.add(dir);
      for (final db in findFiles(dir, (f) => hasExt(f, 'db'))) {
        report.filesSeen += 1;
        try {
          report.merge(scanCliDb(ctx, db));
        } catch (_) {
          report.skipped += 1;
        }
      }
    }

    if (ctx.settings.antigravityIdeEnabled) {
      for (final dir in ideDirs(ctx.settings)) {
        report.detectedPaths.add(dir);
        for (final db in findFiles(dir, (f) => hasExt(f, 'db'))) {
          report.filesSeen += 1;
          try {
            report.merge(scanIdeDb(ctx, db));
          } catch (_) {
            report.skipped += 1;
          }
        }
      }
    } else {
      for (final dir in ideDirs(ctx.settings)) {
        report.detectedPaths.add('$dir (disabled)');
      }
    }

    report.events = finalizeEvents(report.events, ctx.pricing);
    return report;
  }

  static ScanReport scanIdeDb(ScanCtx ctx, String dbPath) {
    final key = 'ide:$dbPath';
    final state =
        ctx.store.getScanState(SourceIds.antigravity, ctx.instance, key) ??
            const ScanState();

    final conn = openSqliteReadOnly(dbPath);
    try {
      if (!tableExists(conn, 'gen_metadata')) {
        return ScanReport();
      }
      final maxRows =
          conn.select('SELECT COALESCE(MAX(idx), -1) AS m FROM gen_metadata');
      final maxIdx = (maxRows.first['m'] as num?)?.toInt() ?? -1;
      final watermark = maxIdx + 1 < state.offset ? -1 : state.offset - 1;
      if (maxIdx <= watermark) {
        return ScanReport();
      }

      final conversation = fileStem(dbPath);
      final rows = conn.select(
        'SELECT idx, data FROM gen_metadata WHERE idx > ?1 ORDER BY idx',
        [watermark],
      );

      final report = ScanReport();
      for (final r in rows) {
        final idx = (r['idx'] as num).toInt();
        final rawBlob = r['data'];
        Uint8List? blob;
        if (rawBlob is Uint8List) {
          blob = rawBlob;
        } else if (rawBlob is List<int>) {
          blob = Uint8List.fromList(rawBlob);
        }
        if (blob == null) {
          report.skipped += 1;
          continue;
        }
        final ev = decodeGeneration(blob, conversation, idx, ctx.instance);
        if (ev != null) {
          report.events.add(ev);
        } else {
          report.skipped += 1;
        }
      }

      report.states.add(
        PendingScanState(
          source: SourceIds.antigravity,
          instance: ctx.instance,
          key: key,
          state: ScanState(
            offset: maxIdx + 1,
            mtimeMs: mtimeMs(dbPath),
          ),
        ),
      );
      return report;
    } finally {
      conn.dispose();
    }
  }

  static UsageEvent? decodeGeneration(
    Uint8List blob,
    String conversation,
    int idx,
    String instance,
  ) {
    final root = decodeProtobuf(blob);
    if (root == null) return null;
    final outer = root.message(1);
    if (outer == null) return null;
    final usage = outer.message(4);
    if (usage == null) return null;

    final input = usage.varint(2);
    final output = usage.varint(3);
    final cacheRead = usage.varint(5);
    final reasoning = usage.varint(9);
    final text = usage.varint(10);
    if (input + output + cacheRead == 0) return null;
    if (output != reasoning + text) return null;

    final reqIdRaw = usage.string(11);
    final requestId =
        (reqIdRaw != null && reqIdRaw.isNotEmpty) ? reqIdRaw : null;
    final modelRaw = outer.string(19);
    final model = (modelRaw != null && modelRaw.isNotEmpty)
        ? modelRaw
        : 'antigravity-model-${usage.varint(1)}';

    final tsMsg = outer.path(const [9, 4]);
    int timestamp = nowMs();
    if (tsMsg != null) {
      final candidate = tsMsg.varint(1) * 1000 + (tsMsg.varint(2) ~/ 1000000);
      if (candidate > 0) timestamp = candidate;
    }

    final dedupKey =
        requestId != null ? 'ide:$requestId' : 'ide:$conversation:$idx';

    return UsageEvent(
      source: SourceIds.antigravity,
      surface: SurfaceIds.ide,
      instance: instance,
      dedupKey: dedupKey,
      sessionId: root.string(4) ?? conversation,
      model: model,
      provider: 'google',
      timestamp: timestamp,
      inputTokens: input,
      outputTokens: output,
      cacheReadTokens: cacheRead,
      reasoningTokens: reasoning,
    );
  }

  static ScanReport scanCliDb(ScanCtx ctx, String dbPath) {
    final conn = openSqliteReadOnly(dbPath);
    try {
      String? table;
      for (final candidate in [
        'conversations',
        'messages',
        'generations',
        'turns',
        'usage',
      ]) {
        if (tableExists(conn, candidate)) {
          table = candidate;
          break;
        }
      }
      if (table == null) {
        if (tableExists(conn, 'gen_metadata')) {
          conn.dispose();
          return scanIdeDb(ctx, dbPath);
        }
        return ScanReport();
      }

      String? pick(List<String> candidates) {
        for (final c in candidates) {
          if (columnExists(conn, table!, c)) return c;
        }
        return null;
      }

      String expr(List<String> candidates) => pick(candidates) ?? '0';

      final idCol = pick(const ['id', 'uuid', 'conversation_id']) ?? 'rowid';
      final inputExpr = expr(const ['input_tokens', 'prompt_tokens', 'tokens_input']);
      final outputExpr =
          expr(const ['output_tokens', 'completion_tokens', 'tokens_output']);
      final creadExpr = expr(
        const ['cache_read_tokens', 'cached_tokens', 'tokens_cache_read'],
      );
      final cwriteExpr =
          expr(const ['cache_write_tokens', 'tokens_cache_write']);
      final reasoningExpr =
          expr(const ['reasoning_tokens', 'thoughts_tokens']);
      final modelExpr =
          pick(const ['model', 'model_name', 'model_id']) ?? "''";
      final tsExpr = pick(
            const ['updated_at', 'created_at', 'timestamp', 'time_created'],
          ) ??
          '0';

      final rows = conn.select('''
        SELECT "$idCol" AS id_val,
               $inputExpr AS inp,
               $outputExpr AS outp,
               $creadExpr AS cr,
               $cwriteExpr AS cw,
               $reasoningExpr AS reas,
               $modelExpr AS mdl,
               $tsExpr AS ts
        FROM "$table"
      ''');

      final stem = fileStem(dbPath);
      final report = ScanReport();
      for (final r in rows) {
        final id = r['id_val']?.toString() ?? '';
        final inp = (r['inp'] as num?)?.toInt() ?? 0;
        final outp = (r['outp'] as num?)?.toInt() ?? 0;
        final cr = (r['cr'] as num?)?.toInt() ?? 0;
        final cw = (r['cw'] as num?)?.toInt() ?? 0;
        final reas = (r['reas'] as num?)?.toInt() ?? 0;
        final mdl = (r['mdl'] as String?)?.trim() ?? '';
        final tsRaw = r['ts'];

        final ev = UsageEvent(
          source: SourceIds.antigravity,
          surface: SurfaceIds.cli,
          instance: ctx.instance,
          dedupKey: 'cli:$stem:$id',
          sessionId: id.isEmpty ? stem : id,
          model: mdl.isEmpty ? 'unknown' : mdl,
          provider: 'google',
          inputTokens: inp,
          outputTokens: outp,
          cacheReadTokens: cr,
          cacheWriteTokens: cw,
          reasoningTokens: reas,
          timestamp: parseTimestamp(tsRaw) ?? nowMs(),
        );
        if (!ev.isEmpty) {
          report.events.add(ev);
        }
      }
      return report;
    } finally {
      try {
        conn.dispose();
      } catch (_) {}
    }
  }
}
