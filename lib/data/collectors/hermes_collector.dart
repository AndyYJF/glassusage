import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../database/app_database.dart';
import 'collector_base.dart';

class HermesCollector extends Collector {
  @override
  String get id => SourceIds.hermes;

  @override
  String get label => 'Hermes Agent';

  @override
  WriteMode get writeMode => WriteMode.upsert;

  static List<String> homes(AppSettings settings) {
    final custom = settings.customPath(SourceIds.hermes);
    if (custom != null) return [custom];
    final env = Platform.environment['HERMES_HOME'];
    if (env != null && env.trim().isNotEmpty) {
      final parts = env
          .split(RegExp(r'[,;]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (parts.isNotEmpty) return parts;
    }
    return [p.join(homeDir(), '.hermes')];
  }

  static List<String> databasesUnder(String root) {
    final out = <String>[];
    final mainDb = p.join(root, 'state.db');
    if (File(mainDb).existsSync()) {
      out.add(mainDb);
    }
    final profilesDir = Directory(p.join(root, 'profiles'));
    if (profilesDir.existsSync()) {
      try {
        for (final e in profilesDir.listSync(followLinks: false)) {
          if (e is Directory) {
            final db = p.join(e.path, 'state.db');
            if (File(db).existsSync()) {
              out.add(db);
            }
          }
        }
      } catch (_) {}
    }
    return out;
  }

  static List<String> databases(AppSettings settings) {
    final out = <String>[];
    for (final h in homes(settings)) {
      out.addAll(databasesUnder(h));
    }
    return out;
  }

  @override
  List<String> detect(AppSettings settings) => databases(settings);

  @override
  List<String> watchPaths(AppSettings settings) =>
      homes(settings).where((d) => Directory(d).existsSync()).toList();

  @override
  ScanReport scan(ScanCtx ctx) {
    List<String> dbs;
    if (ctx.rootOverride != null) {
      dbs = databasesUnder(ctx.rootOverride!);
      if (dbs.isEmpty) {
        dbs = findFiles(ctx.rootOverride!, (f) => hasExt(f, 'db'));
      }
    } else {
      dbs = databases(ctx.settings);
    }

    final report = ScanReport(
      filesSeen: dbs.length,
      detectedPaths: List.from(dbs),
    );
    for (final db in dbs) {
      try {
        report.merge(scanDb(ctx, db));
      } catch (_) {
        report.skipped += 1;
      }
    }
    report.events = finalizeEvents(report.events, ctx.pricing);
    return report;
  }

  static ScanReport scanDb(ScanCtx ctx, String dbPath) {
    final conn = openSqliteReadOnly(dbPath);
    try {
      if (!tableExists(conn, 'sessions')) {
        throw StateError('unsupported Hermes schema: missing sessions table');
      }
      bool has(String c) => columnExists(conn, 'sessions', c);
      String col(String c, String fallback) => has(c) ? c : fallback;

      final sourceCol = has('source') ? 'source' : "''";
      final modelCol = has('model') ? 'model' : "''";
      final startedCol = col('started_at', '0');
      final inputCol = col('input_tokens', '0');
      final outputCol = col('output_tokens', '0');
      final creadCol = col('cache_read_tokens', '0');
      final cwriteCol = col('cache_write_tokens', '0');
      final reasoningCol = col('reasoning_tokens', '0');
      final actualCol = has('actual_cost_usd') ? 'actual_cost_usd' : 'NULL';
      final estimatedCol =
          has('estimated_cost_usd') ? 'estimated_cost_usd' : 'NULL';
      final providerCol = has('billing_provider') ? 'billing_provider' : 'NULL';

      final rows = conn.select('''
        SELECT id,
               $sourceCol AS src,
               $modelCol AS mdl,
               $startedCol AS started,
               $inputCol AS inp,
               $outputCol AS outp,
               $creadCol AS cr,
               $cwriteCol AS cw,
               $reasoningCol AS reas,
               $actualCol AS actual_cost,
               $estimatedCol AS est_cost,
               $providerCol AS prov
        FROM sessions
      ''');

      final report = ScanReport();
      for (final r in rows) {
        final id = r['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final src = r['src'] as String?;
        final model = (r['mdl'] as String?)?.trim() ?? '';
        final started = (r['started'] as num?)?.toDouble();
        final inp = (r['inp'] as num?)?.toInt() ?? 0;
        final outp = (r['outp'] as num?)?.toInt() ?? 0;
        final cr = (r['cr'] as num?)?.toInt() ?? 0;
        final cw = (r['cw'] as num?)?.toInt() ?? 0;
        final reas = (r['reas'] as num?)?.toInt() ?? 0;
        final actual = (r['actual_cost'] as num?)?.toDouble();
        final estimated = (r['est_cost'] as num?)?.toDouble();
        final provider = r['prov'] as String?;

        double? costUsd;
        if (actual != null && actual > 0.0) {
          costUsd = actual;
        } else if (estimated != null && estimated > 0.0) {
          costUsd = estimated;
        }

        final ev = UsageEvent(
          source: SourceIds.hermes,
          surface: SurfaceIds.cli,
          instance: ctx.instance,
          dedupKey: id,
          sessionId: id,
          project: projectLabel(src),
          model: model.isEmpty ? 'unknown' : model,
          provider: provider,
          timestamp:
              (started != null && started > 0) ? normalizeEpoch(started) : nowMs(),
          inputTokens: inp,
          outputTokens: outp,
          cacheReadTokens: cr,
          cacheWriteTokens: cw,
          reasoningTokens: reas,
          costUsd: costUsd,
        );
        if (!ev.isEmpty) {
          report.events.add(ev);
        }
      }
      return report;
    } finally {
      conn.dispose();
    }
  }
}
