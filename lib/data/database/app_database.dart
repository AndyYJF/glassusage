import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../domain/models/settings_model.dart';
import '../../domain/models/usage_models.dart';
import '../pricing/pricing_service.dart';

const int kSchemaVersion = 1;

enum WriteMode {
  insertOrIgnore,
  upsert,
}

int nowMs() => DateTime.now().millisecondsSinceEpoch;

class AppDatabase {
  final Database _db;
  final String dataDir;

  AppDatabase._(this._db, this.dataDir);

  factory AppDatabase.open(String dataDir) {
    Directory(dataDir).createSync(recursive: true);
    final dbPath = p.join(dataDir, 'usage.db');
    final bakPath = p.join(dataDir, 'usage.db.pre-flutter.bak');
    if (File(dbPath).existsSync() && !File(bakPath).existsSync()) {
      try {
        File(dbPath).copySync(bakPath);
      } catch (_) {}
    }
    final db = sqlite3.open(dbPath);
    final store = AppDatabase._(db, dataDir);
    store._init();
    return store;
  }

  factory AppDatabase.inMemory({String dataDir = '.'}) {
    final db = sqlite3.openInMemory();
    final store = AppDatabase._(db, dataDir);
    store._init();
    return store;
  }

  void close() => _db.dispose();
  void dispose() => close();

  static int nowMs() => DateTime.now().millisecondsSinceEpoch;

  static String dayKeyLocal(int tsMs) => _localDateString(tsMs);

  static (int, int) dayBounds(int daysAgo) {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day - daysAgo);
    final end = DateTime(now.year, now.month, now.day - daysAgo + 1);
    return (start.millisecondsSinceEpoch, end.millisecondsSinceEpoch - 1);
  }

  List<(int, String, int)> recentEvents(int sinceMs) {
    final rows = _db.select(
      '''
      SELECT ts_ms, source,
             input_tokens + output_tokens + cache_read_tokens + cache_write_tokens AS tok
      FROM usage_events
      WHERE ts_ms >= ?1
      ORDER BY ts_ms ASC
      ''',
      [sinceMs],
    );
    return rows
        .map(
          (r) => (
            (r['ts_ms'] as num).toInt(),
            r['source'] as String,
            (r['tok'] as num).toInt(),
          ),
        )
        .toList();
  }

  void _init() {
    // Anti-Jank Rule 2: Enable WAL mode, NORMAL synchronous, and 5000ms busy_timeout.
    _db.execute('''
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      PRAGMA foreign_keys = ON;
      PRAGMA temp_store = MEMORY;
      PRAGMA busy_timeout = 5000;
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS usage_events (
        id                 INTEGER PRIMARY KEY AUTOINCREMENT,
        ts_ms              INTEGER NOT NULL,
        source             TEXT    NOT NULL,
        surface            TEXT    NOT NULL,
        instance           TEXT    NOT NULL DEFAULT 'local',
        session_id         TEXT    NOT NULL DEFAULT '',
        project            TEXT,
        provider           TEXT,
        model              TEXT    NOT NULL,
        model_norm         TEXT    NOT NULL,
        input_tokens       INTEGER NOT NULL DEFAULT 0,
        output_tokens      INTEGER NOT NULL DEFAULT 0,
        cache_read_tokens  INTEGER NOT NULL DEFAULT 0,
        cache_write_tokens INTEGER NOT NULL DEFAULT 0,
        reasoning_tokens   INTEGER NOT NULL DEFAULT 0,
        cost_usd           REAL,
        dedup_key          TEXT    NOT NULL,
        UNIQUE(source, instance, dedup_key)
      );

      CREATE INDEX IF NOT EXISTS idx_ev_ts          ON usage_events(ts_ms);
      CREATE INDEX IF NOT EXISTS idx_ev_src_ts      ON usage_events(source, ts_ms);
      CREATE INDEX IF NOT EXISTS idx_ev_src_inst_ts ON usage_events(source, instance, ts_ms);
      CREATE INDEX IF NOT EXISTS idx_ev_model_ts    ON usage_events(model_norm, ts_ms);
      CREATE INDEX IF NOT EXISTS idx_ev_instance_ts ON usage_events(instance, ts_ms);
      CREATE INDEX IF NOT EXISTS idx_ev_provider_ts ON usage_events(provider, ts_ms);

      CREATE TABLE IF NOT EXISTS scan_state (
        source    TEXT NOT NULL,
        instance  TEXT NOT NULL DEFAULT 'local',
        key       TEXT NOT NULL,
        offset    INTEGER NOT NULL DEFAULT 0,
        mtime_ms  INTEGER NOT NULL DEFAULT 0,
        extra     TEXT,
        PRIMARY KEY (source, instance, key)
      );

      CREATE TABLE IF NOT EXISTS source_status (
        source          TEXT NOT NULL,
        instance        TEXT NOT NULL DEFAULT 'local',
        last_scan_ms    INTEGER,
        last_error      TEXT,
        file_count      INTEGER NOT NULL DEFAULT 0,
        skipped_rows    INTEGER NOT NULL DEFAULT 0,
        detected_paths  TEXT    NOT NULL DEFAULT '[]',
        PRIMARY KEY (source, instance)
      );

      CREATE TABLE IF NOT EXISTS settings_kv (
        key   TEXT PRIMARY KEY,
        value BLOB NOT NULL
      );

      CREATE TABLE IF NOT EXISTS remote_instances (
        name             TEXT PRIMARY KEY,
        agent            TEXT NOT NULL,
        host             TEXT NOT NULL,
        port             INTEGER NOT NULL DEFAULT 22,
        username         TEXT NOT NULL,
        auth_mode        TEXT NOT NULL DEFAULT 'key',
        key_path         TEXT,
        secret_dpapi     BLOB,
        remote_home      TEXT,
        remote_path      TEXT,
        poll_secs        INTEGER NOT NULL DEFAULT 300,
        import_archives  INTEGER NOT NULL DEFAULT 0,
        enabled          INTEGER NOT NULL DEFAULT 1,
        proxy_url        TEXT
      );

      CREATE TABLE IF NOT EXISTS daily_rollup (
        day                TEXT NOT NULL,
        source             TEXT NOT NULL,
        instance           TEXT NOT NULL,
        model_norm         TEXT NOT NULL,
        input_tokens       INTEGER NOT NULL DEFAULT 0,
        output_tokens      INTEGER NOT NULL DEFAULT 0,
        cache_read_tokens  INTEGER NOT NULL DEFAULT 0,
        cache_write_tokens INTEGER NOT NULL DEFAULT 0,
        reasoning_tokens   INTEGER NOT NULL DEFAULT 0,
        cost_usd           REAL    NOT NULL DEFAULT 0,
        events             INTEGER NOT NULL DEFAULT 0,
        unpriced_events    INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day, source, instance, model_norm)
      );
    ''');

    final cols = _db.select('PRAGMA table_info(remote_instances)');
    final hasProxy = cols.any((r) => r['name'] == 'proxy_url');
    if (!hasProxy) {
      try {
        _db.execute('ALTER TABLE remote_instances ADD COLUMN proxy_url TEXT');
      } catch (_) {}
    }

    final rollupCols = _db.select('PRAGMA table_info(daily_rollup)');
    final hasInstance = rollupCols.any((r) => r['name'] == 'instance');
    final hasUnpriced = rollupCols.any((r) => r['name'] == 'unpriced_events');
    if (!hasInstance || !hasUnpriced) {
      _db.execute('DROP TABLE IF EXISTS daily_rollup');
      _db.execute('''
        CREATE TABLE daily_rollup (
          day                TEXT NOT NULL,
          source             TEXT NOT NULL,
          instance           TEXT NOT NULL DEFAULT 'local',
          model_norm         TEXT NOT NULL,
          input_tokens       INTEGER NOT NULL DEFAULT 0,
          output_tokens      INTEGER NOT NULL DEFAULT 0,
          cache_read_tokens  INTEGER NOT NULL DEFAULT 0,
          cache_write_tokens INTEGER NOT NULL DEFAULT 0,
          reasoning_tokens   INTEGER NOT NULL DEFAULT 0,
          cost_usd           REAL    NOT NULL DEFAULT 0,
          events             INTEGER NOT NULL DEFAULT 0,
          unpriced_events    INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (day, source, instance, model_norm)
        );
      ''');
    }

    _db.execute('''
      UPDATE source_status
         SET last_error = NULL
       WHERE last_error LIKE '%daily_rollup%'
          OR last_error LIKE '%no such column: instance%'
    ''');

    _db.execute(
      "INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', ?)",
      [kSchemaVersion.toString()],
    );

    // Ensure daily_rollup is populated if usage_events already has rows.
    final rollupCount =
        _db.select('SELECT COUNT(*) AS c FROM daily_rollup').first['c'] as int;
    if (rollupCount == 0) {
      final evCount = _db
          .select('SELECT COUNT(*) AS c FROM usage_events')
          .first['c'] as int;
      if (evCount > 0) {
        _rebuildAllRollup();
      }
    }
  }

  // ----------------------------------------------------------------- ingestion

  IngestOutcome ingest(List<UsageEvent> events, WriteMode mode) {
    return ingestScan(events, mode, const []);
  }

  IngestOutcome ingestScan(
    List<UsageEvent> events,
    WriteMode mode,
    List<PendingScanState> states,
  ) {
    if (events.isEmpty && states.isEmpty) {
      return const IngestOutcome();
    }

    _db.execute('BEGIN IMMEDIATE TRANSACTION');
    try {
      var changed = 0;
      final deltas = <DeltaEvent>[];
      final dirtyDays = <String>{};

      final insertIgnoreStmt = _db.prepare('''
        INSERT OR IGNORE INTO usage_events (
          ts_ms, source, surface, instance, session_id, project, provider,
          model, model_norm, input_tokens, output_tokens,
          cache_read_tokens, cache_write_tokens, reasoning_tokens,
          cost_usd, dedup_key
        ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)
      ''');

      final prevTotalsStmt = _db.prepare('''
        SELECT input_tokens + output_tokens + cache_read_tokens + cache_write_tokens AS total,
               ts_ms
        FROM usage_events
        WHERE source = ?1 AND instance = ?2 AND dedup_key = ?3
      ''');

      final upsertStmt = _db.prepare('''
        INSERT INTO usage_events (
          ts_ms, source, surface, instance, session_id, project, provider,
          model, model_norm, input_tokens, output_tokens,
          cache_read_tokens, cache_write_tokens, reasoning_tokens,
          cost_usd, dedup_key
        ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)
        ON CONFLICT(source, instance, dedup_key) DO UPDATE SET
          ts_ms              = excluded.ts_ms,
          surface            = excluded.surface,
          session_id         = excluded.session_id,
          project            = COALESCE(excluded.project, usage_events.project),
          provider           = COALESCE(excluded.provider, usage_events.provider),
          model              = excluded.model,
          model_norm         = excluded.model_norm,
          input_tokens       = excluded.input_tokens,
          output_tokens      = excluded.output_tokens,
          cache_read_tokens  = excluded.cache_read_tokens,
          cache_write_tokens = excluded.cache_write_tokens,
          reasoning_tokens   = excluded.reasoning_tokens,
          cost_usd           = excluded.cost_usd
      ''');

      final stateStmt = _db.prepare('''
        INSERT INTO scan_state(source, instance, key, offset, mtime_ms, extra)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT(source, instance, key) DO UPDATE SET
          offset   = excluded.offset,
          mtime_ms = excluded.mtime_ms,
          extra    = excluded.extra
      ''');

      try {
        for (final e in events) {
          if (e.isEmpty) continue;
          final params = [
            e.timestamp,
            e.source,
            e.surface,
            e.instance,
            e.sessionId,
            e.project,
            e.provider,
            e.model,
            e.modelNorm,
            e.inputTokens,
            e.outputTokens,
            e.cacheReadTokens,
            e.cacheWriteTokens,
            e.reasoningTokens,
            e.costUsd,
            e.dedupKey,
          ];

          if (mode == WriteMode.insertOrIgnore) {
            insertIgnoreStmt.execute(params);
            final rowsAffected = _db.updatedRows;
            if (rowsAffected > 0) {
              changed += rowsAffected;
              dirtyDays.add(_localDateString(e.timestamp));
              deltas.add(
                DeltaEvent(
                  source: e.source,
                  timestamp: e.timestamp,
                  deltaTokens: e.totalTokens,
                  deltaEvents: 1,
                ),
              );
            }
          } else {
            final prevRows = prevTotalsStmt.select([
              e.source,
              e.instance,
              e.dedupKey,
            ]);
            int? prevTotal;
            int? prevTs;
            if (prevRows.isNotEmpty) {
              prevTotal = (prevRows.first['total'] as num?)?.toInt();
              prevTs = (prevRows.first['ts_ms'] as num?)?.toInt();
            }

            upsertStmt.execute(params);
            final deltaTokens = e.totalTokens - (prevTotal ?? 0);
            final deltaEvents = prevTotal == null ? 1 : 0;
            if (deltaTokens > 0 || deltaEvents > 0) {
              changed += 1;
              dirtyDays.add(_localDateString(e.timestamp));
              if (prevTs != null) {
                dirtyDays.add(_localDateString(prevTs));
              }
              deltas.add(
                DeltaEvent(
                  source: e.source,
                  timestamp: e.timestamp,
                  deltaTokens: deltaTokens < 0 ? 0 : deltaTokens,
                  deltaEvents: deltaEvents,
                ),
              );
            }
          }
        }

        if (dirtyDays.isNotEmpty) {
          _rebuildRollupDaysTx(dirtyDays);
        }

        for (final pending in states) {
          stateStmt.execute([
            pending.source,
            pending.instance,
            pending.key,
            pending.state.offset,
            pending.state.mtimeMs,
            pending.state.extra,
          ]);
        }
      } finally {
        insertIgnoreStmt.dispose();
        prevTotalsStmt.dispose();
        upsertStmt.dispose();
        stateStmt.dispose();
      }

      _db.execute('COMMIT');
      return IngestOutcome(changed: changed, deltas: deltas);
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Anti-Jank Rule 2: Rebuild daily_rollup for touched days using indexed
  /// `[dayStartMs, dayEndMs)` range bounds so SQLite uses `idx_ev_ts` instead of
  /// performing a full-table scan via `WHERE date(ts_ms/1000, ...)`.
  void _rebuildRollupDaysTx(Iterable<String> days) {
    final delStmt = _db.prepare('DELETE FROM daily_rollup WHERE day = ?1');
    final insStmt = _db.prepare('''
      INSERT INTO daily_rollup (
        day, source, instance, model_norm,
        input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
        reasoning_tokens, cost_usd, events, unpriced_events
      )
      SELECT
        ?1 AS day,
        source, instance, model_norm,
        SUM(input_tokens),
        SUM(output_tokens),
        SUM(cache_read_tokens),
        SUM(cache_write_tokens),
        SUM(reasoning_tokens),
        COALESCE(SUM(cost_usd), 0.0),
        COUNT(*),
        SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END)
      FROM usage_events
      WHERE ts_ms >= ?2 AND ts_ms < ?3
      GROUP BY source, instance, model_norm
    ''');

    try {
      for (final day in days) {
        final bounds = _dayBoundsMs(day);
        if (bounds == null) continue;
        delStmt.execute([day]);
        insStmt.execute([day, bounds.$1, bounds.$2]);
      }
    } finally {
      delStmt.dispose();
      insStmt.dispose();
    }
  }

  void _rebuildAllRollup() {
    _db.execute('DELETE FROM daily_rollup');
    _db.execute('''
      INSERT INTO daily_rollup (
        day, source, instance, model_norm,
        input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
        reasoning_tokens, cost_usd, events, unpriced_events
      )
      SELECT
        date(ts_ms / 1000, 'unixepoch', 'localtime') AS day,
        source, instance, model_norm,
        SUM(input_tokens),
        SUM(output_tokens),
        SUM(cache_read_tokens),
        SUM(cache_write_tokens),
        SUM(reasoning_tokens),
        COALESCE(SUM(cost_usd), 0.0),
        COUNT(*),
        SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END)
      FROM usage_events
      GROUP BY day, source, instance, model_norm
    ''');
  }

  static String _localDateString(int tsMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(tsMs);
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  static (int, int)? _dayBoundsMs(String day) {
    final parts = day.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    final start = DateTime(y, m, d);
    final end = DateTime(y, m, d + 1);
    return (start.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
  }

  static bool _sameCost(double? a, double? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return (a - b).abs() <= 1e-11;
  }

  int reprice(PricingService pricing) {
    final rows = _db.select('''
      SELECT id, source, model, model_norm, input_tokens, output_tokens,
             cache_read_tokens, cache_write_tokens, cost_usd
      FROM usage_events
    ''');

    final toUpdate = <(String, double?, int)>[];
    for (final r in rows) {
      final id = (r['id'] as num).toInt();
      final source = r['source'] as String;
      final model = r['model'] as String;
      final oldNorm = r['model_norm'] as String;
      final oldCost = (r['cost_usd'] as num?)?.toDouble();
      final input = (r['input_tokens'] as num?)?.toInt() ?? 0;
      final output = (r['output_tokens'] as num?)?.toInt() ?? 0;
      final cr = (r['cache_read_tokens'] as num?)?.toInt() ?? 0;
      final cw = (r['cache_write_tokens'] as num?)?.toInt() ?? 0;

      final norm = pricing.normalize(model);
      final cost = pricing.cost(norm, input, output, cr, cw);

      if (sourceHasNativeCost(source) && cost == null) {
        continue;
      }
      if (norm != oldNorm || !_sameCost(cost, oldCost)) {
        toUpdate.add((norm, cost, id));
      }
    }

    if (toUpdate.isEmpty) {
      return 0;
    }

    _db.execute('BEGIN IMMEDIATE TRANSACTION');
    final updateStmt = _db.prepare('''
      UPDATE usage_events
         SET model_norm = ?1, cost_usd = ?2
       WHERE id = ?3
    ''');
    var updated = 0;
    try {
      for (final item in toUpdate) {
        updateStmt.execute([item.$1, item.$2, item.$3]);
        updated += _db.updatedRows;
      }
      if (updated > 0) {
        _rebuildAllRollup();
      }
      _db.execute('COMMIT');
      return updated;
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      updateStmt.dispose();
    }
  }

  // ----------------------------------------------------------------- scan state

  ScanState? getScanState(String source, String instance, String key) {
    final rows = _db.select(
      'SELECT offset, mtime_ms, extra FROM scan_state WHERE source=?1 AND instance=?2 AND key=?3',
      [source, instance, key],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return ScanState(
      offset: (r['offset'] as num).toInt(),
      mtimeMs: (r['mtime_ms'] as num).toInt(),
      extra: r['extra'] as String?,
    );
  }

  void setScanState(
    String source,
    String instance,
    String key,
    ScanState state,
  ) {
    _db.execute(
      '''
      INSERT INTO scan_state(source, instance, key, offset, mtime_ms, extra)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      ON CONFLICT(source, instance, key) DO UPDATE SET
        offset   = excluded.offset,
        mtime_ms = excluded.mtime_ms,
        extra    = excluded.extra
      ''',
      [source, instance, key, state.offset, state.mtimeMs, state.extra],
    );
  }

  void clearScanState(String source, {String? instance}) {
    if (instance != null) {
      _db.execute(
        'DELETE FROM scan_state WHERE source = ?1 AND instance = ?2',
        [source, instance],
      );
    } else {
      _db.execute('DELETE FROM scan_state WHERE source = ?1', [source]);
    }
  }

  void deleteSource(String source, {String? instance}) {
    if (instance != null) {
      _db.execute(
        'DELETE FROM usage_events WHERE source = ?1 AND instance = ?2',
        [source, instance],
      );
      _db.execute(
        'DELETE FROM daily_rollup WHERE source = ?1 AND instance = ?2',
        [source, instance],
      );
    } else {
      _db.execute('DELETE FROM usage_events WHERE source = ?1', [source]);
      _db.execute('DELETE FROM daily_rollup WHERE source = ?1', [source]);
    }
  }

  void recordStatus(
    String source,
    String instance,
    int fileCount,
    int skipped,
    List<String> paths,
    String? error,
  ) {
    _db.execute(
      '''
      INSERT INTO source_status
        (source, instance, last_scan_ms, last_error, file_count, skipped_rows, detected_paths)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
      ON CONFLICT(source, instance) DO UPDATE SET
        last_scan_ms   = excluded.last_scan_ms,
        last_error     = excluded.last_error,
        file_count     = excluded.file_count,
        skipped_rows   = excluded.skipped_rows,
        detected_paths = excluded.detected_paths
      ''',
      [
        source,
        instance,
        nowMs(),
        error,
        fileCount,
        skipped,
        jsonEncode(paths),
      ],
    );
  }

  // ----------------------------------------------------------------- queries

  TokenBreakdown sumRange(
    int fromMs,
    int toMs, {
    String? source,
    String? instance,
  }) {
    final clauses = <String>['ts_ms >= ?', 'ts_ms <= ?'];
    final args = <Object?>[fromMs, toMs];
    if (source != null) {
      clauses.add('source = ?');
      args.add(source);
    }
    if (instance != null) {
      clauses.add('instance = ?');
      args.add(instance);
    }
    final whereSql = clauses.join(' AND ');
    final rows = _db.select(
      '''
      SELECT
        COALESCE(SUM(input_tokens), 0) AS inp,
        COALESCE(SUM(output_tokens), 0) AS outp,
        COALESCE(SUM(cache_read_tokens), 0) AS cr,
        COALESCE(SUM(cache_write_tokens), 0) AS cw,
        COALESCE(SUM(reasoning_tokens), 0) AS reas,
        COALESCE(SUM(cost_usd), 0.0) AS cost,
        COUNT(*) AS ev,
        COALESCE(SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END), 0) AS unpriced
      FROM usage_events
      WHERE $whereSql
      ''',
      args,
    );
    return _breakdownFromRow(rows.first);
  }

  /// Anti-Jank Rule 2: Fast rollup sum for complete local day ranges `[fromDay, toDay]`.
  TokenBreakdown sumRollupDays(
    String fromDay,
    String toDay, {
    List<String>? sources,
  }) {
    if (sources != null && sources.isNotEmpty) {
      final placeholders = List.filled(sources.length, '?').join(',');
      final rows = _db.select(
        '''
        SELECT
          COALESCE(SUM(input_tokens), 0) AS inp,
          COALESCE(SUM(output_tokens), 0) AS outp,
          COALESCE(SUM(cache_read_tokens), 0) AS cr,
          COALESCE(SUM(cache_write_tokens), 0) AS cw,
          COALESCE(SUM(reasoning_tokens), 0) AS reas,
          COALESCE(SUM(cost_usd), 0.0) AS cost,
          COALESCE(SUM(events), 0) AS ev,
          COALESCE(SUM(unpriced_events), 0) AS unpriced
        FROM daily_rollup
        WHERE day >= ? AND day <= ? AND source IN ($placeholders)
        ''',
        [fromDay, toDay, ...sources],
      );
      return _breakdownFromRow(rows.first);
    }

    final rows = _db.select(
      '''
      SELECT
        COALESCE(SUM(input_tokens), 0) AS inp,
        COALESCE(SUM(output_tokens), 0) AS outp,
        COALESCE(SUM(cache_read_tokens), 0) AS cr,
        COALESCE(SUM(cache_write_tokens), 0) AS cw,
        COALESCE(SUM(reasoning_tokens), 0) AS reas,
        COALESCE(SUM(cost_usd), 0.0) AS cost,
        COALESCE(SUM(events), 0) AS ev,
        COALESCE(SUM(unpriced_events), 0) AS unpriced
      FROM daily_rollup
      WHERE day >= ?1 AND day <= ?2
      ''',
      [fromDay, toDay],
    );
    return _breakdownFromRow(rows.first);
  }

  TokenBreakdown sumRangeSources(
    int fromMs,
    int toMs,
    List<String> sources,
  ) {
    final todayStart = startOfLocalDay(nowMs());
    if (fromMs == todayStart) {
      final todayStr = _localDateString(todayStart);
      return sumRollupDays(todayStr, todayStr, sources: sources);
    }
    if (sources.isEmpty) {
      return sumRange(fromMs, toMs);
    }
    final placeholders = List.filled(sources.length, '?').join(',');
    final rows = _db.select(
      '''
      SELECT
        COALESCE(SUM(input_tokens), 0) AS inp,
        COALESCE(SUM(output_tokens), 0) AS outp,
        COALESCE(SUM(cache_read_tokens), 0) AS cr,
        COALESCE(SUM(cache_write_tokens), 0) AS cw,
        COALESCE(SUM(reasoning_tokens), 0) AS reas,
        COALESCE(SUM(cost_usd), 0.0) AS cost,
        COUNT(*) AS ev,
        COALESCE(SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END), 0) AS unpriced
      FROM usage_events
      WHERE ts_ms >= ? AND ts_ms <= ? AND source IN ($placeholders)
      ''',
      [fromMs, toMs, ...sources],
    );
    return _breakdownFromRow(rows.first);
  }

  /// Anti-Jank Rule 2: `today`, `yesterday`, `thisWeek`, and `lastWeek` are read from
  /// `daily_rollup` rather than executing 4 separate full scans of `usage_events`.
  OverviewStats overview(int fromMs, int toMs) {
    final now = nowMs();
    final todayStart = startOfLocalDay(now);
    const dayMs = 86400 * 1000;
    final yesterdayStart = todayStart - dayMs;
    final thisWeekStart = startOfLocalWeek(now);
    final lastWeekStart = thisWeekStart - 7 * dayMs;
    final lastWeekEnd = thisWeekStart - 1;

    final todayStr = _localDateString(todayStart);
    final yesterdayStr = _localDateString(yesterdayStart);
    final thisWeekStartStr = _localDateString(thisWeekStart);
    final lastWeekStartStr = _localDateString(lastWeekStart);
    final lastWeekEndStr = _localDateString(lastWeekEnd);

    final today = sumRollupDays(todayStr, todayStr);
    final yesterday = sumRollupDays(yesterdayStr, yesterdayStr);
    final thisWeek = sumRollupDays(thisWeekStartStr, todayStr);
    final lastWeek = sumRollupDays(lastWeekStartStr, lastWeekEndStr);
    final range = sumRange(fromMs, toMs);
    final perSource = groupStats(
      'source',
      UsageFilter(from: fromMs, to: toMs),
    );

    return OverviewStats(
      today: today,
      yesterday: yesterday,
      thisWeek: thisWeek,
      lastWeek: lastWeek,
      range: range,
      perSource: perSource,
    );
  }

  List<SeriesPoint> timeseries({
    required int fromMs,
    required int toMs,
    required String bucket,
    required String groupBy,
    String? source,
  }) {
    // Anti-Jank Rule 2: For day/week buckets grouped by source, model_norm, or total,
    // query `daily_rollup` first instead of scanning raw `usage_events`.
    final canUseRollup = (bucket == 'day' || bucket == 'week') &&
        (groupBy == 'source' || groupBy == 'model_norm' || groupBy == 'total');

    if (canUseRollup) {
      final fromDay = _localDateString(fromMs);
      final toDay = _localDateString(toMs);
      final keyExpr = switch (groupBy) {
        'source' => 'source',
        'model_norm' => 'model_norm',
        _ => "'total'",
      };
      final sourceClause = source != null ? 'AND source = ?3' : '';
      final rows = _db.select(
        '''
        SELECT
          day,
          $keyExpr AS grp_key,
          SUM(input_tokens) AS inp,
          SUM(output_tokens) AS outp,
          SUM(cache_read_tokens) AS cr,
          SUM(cache_write_tokens) AS cw,
          SUM(reasoning_tokens) AS reas,
          COALESCE(SUM(cost_usd), 0.0) AS cost,
          SUM(events) AS ev,
          SUM(unpriced_events) AS unpriced
        FROM daily_rollup
        WHERE day >= ?1 AND day <= ?2 $sourceClause
        GROUP BY day, grp_key
        ORDER BY day ASC
        ''',
        source != null ? [fromDay, toDay, source] : [fromDay, toDay],
      );

      if (bucket == 'day') {
        return rows.map((r) {
          final dayStr = r['day'] as String;
          final bMs = _dayBoundsMs(dayStr)?.$1 ?? fromMs;
          return SeriesPoint(
            bucket: bMs,
            key: (r['grp_key'] as String?) ?? 'unknown',
            totals: _breakdownFromRow(r),
          );
        }).toList();
      } else {
        // Bucket by Monday start of local week.
        final grouped = <(int, String), TokenBreakdown>{};
        for (final r in rows) {
          final dayStr = r['day'] as String;
          final dayStart = _dayBoundsMs(dayStr)?.$1 ?? fromMs;
          final weekStart = startOfLocalWeek(dayStart);
          final key = (r['grp_key'] as String?) ?? 'unknown';
          final cur = _breakdownFromRow(r);
          final prev = grouped[(weekStart, key)];
          grouped[(weekStart, key)] = prev == null
              ? cur
              : _addBreakdowns(prev, cur);
        }
        final entries = grouped.entries.toList()
          ..sort((a, b) => a.key.$1.compareTo(b.key.$1));
        return entries
            .map(
              (e) => SeriesPoint(
                bucket: e.key.$1,
                key: e.key.$2,
                totals: e.value,
              ),
            )
            .toList();
      }
    }

    final bucketExpr = switch (bucket) {
      'hour' => '(ts_ms / 3600000) * 3600000',
      'week' =>
        "strftime('%s', date(ts_ms/1000, 'unixepoch', 'localtime', 'weekday 0', '-6 days')) * 1000",
      _ =>
        "strftime('%s', date(ts_ms/1000, 'unixepoch', 'localtime')) * 1000",
    };

    final keyExpr = switch (groupBy) {
      'source' => 'source',
      'model' || 'model_norm' => 'model_norm',
      'provider' => "COALESCE(provider, 'unknown')",
      'instance' => 'instance',
      'project' => "COALESCE(project, '(none)')",
      _ => "'total'",
    };

    final sourceClause = source != null ? 'AND source = ?3' : '';
    final sql = '''
      SELECT
        $bucketExpr AS b,
        $keyExpr    AS grp_key,
        SUM(input_tokens) AS inp,
        SUM(output_tokens) AS outp,
        SUM(cache_read_tokens) AS cr,
        SUM(cache_write_tokens) AS cw,
        SUM(reasoning_tokens) AS reas,
        COALESCE(SUM(cost_usd), 0.0) AS cost,
        COUNT(*) AS ev,
        SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END) AS unpriced
      FROM usage_events
      WHERE ts_ms >= ?1 AND ts_ms <= ?2 $sourceClause
      GROUP BY b, grp_key
      ORDER BY b ASC
    ''';

    final rows = _db.select(
      sql,
      source != null ? [fromMs, toMs, source] : [fromMs, toMs],
    );
    return rows
        .map(
          (r) => SeriesPoint(
            bucket: (r['b'] as num).toInt(),
            key: (r['grp_key'] as String?) ?? 'unknown',
            totals: _breakdownFromRow(r),
          ),
        )
        .toList();
  }

  List<GroupStat> groupStats(String column, UsageFilter filter) {
    final colExpr = switch (column) {
      'source' => 'source',
      'model' || 'model_norm' => 'model_norm',
      'provider' => "COALESCE(provider, 'unknown')",
      'project' => "COALESCE(project, '(none)')",
      'instance' => 'instance',
      _ => 'source',
    };

    final (whereSql, args) = _buildFilter(filter);
    final rows = _db.select(
      '''
      SELECT
        $colExpr AS grp_key,
        SUM(input_tokens) AS inp,
        SUM(output_tokens) AS outp,
        SUM(cache_read_tokens) AS cr,
        SUM(cache_write_tokens) AS cw,
        SUM(reasoning_tokens) AS reas,
        COALESCE(SUM(cost_usd), 0.0) AS cost,
        COUNT(*) AS ev,
        SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END) AS unpriced
      FROM usage_events
      $whereSql
      GROUP BY grp_key
      ORDER BY (SUM(input_tokens)+SUM(output_tokens)+SUM(cache_read_tokens)+SUM(cache_write_tokens)) DESC
      ''',
      args,
    );

    var grandTotal = 0;
    final parsed = <(String, TokenBreakdown)>[];
    for (final r in rows) {
      final key = (r['grp_key'] as String?) ?? 'unknown';
      final b = _breakdownFromRow(r);
      grandTotal += b.totalTokens;
      parsed.add((key, b));
    }

    return parsed.map((item) {
      final (key, totals) = item;
      final share = grandTotal == 0 ? 0.0 : totals.totalTokens / grandTotal;
      return GroupStat(
        key: key,
        label: key,
        totals: totals,
        share: share,
        unpriced: totals.unpricedEvents > 0,
      );
    }).toList();
  }

  AgentStats agentStats(
    String source,
    int fromMs,
    int toMs, {
    String? instance,
  }) {
    final scopedFilter = UsageFilter(
      from: fromMs,
      to: toMs,
      sources: [source],
      instances: instance == null ? null : [instance],
    );
    final allInstancesFilter = UsageFilter(
      from: fromMs,
      to: toMs,
      sources: [source],
    );
    final totals = sumRange(fromMs, toMs, source: source, instance: instance);
    final perModel = groupStats('model_norm', scopedFilter);
    final perProject = groupStats('project', scopedFilter);
    final perInstance = groupStats('instance', allInstancesFilter);

    final sinceDay = _localDateString(nowMs() - 180 * 86400 * 1000);
    final calRows = instance != null
        ? _db.select(
            '''
            SELECT day,
                   SUM(input_tokens + output_tokens + cache_read_tokens + cache_write_tokens) AS t
            FROM daily_rollup
            WHERE source = ?1 AND day >= ?2 AND instance = ?3
            GROUP BY day
            ORDER BY day ASC
            ''',
            [source, sinceDay, instance],
          )
        : _db.select(
            '''
            SELECT day,
                   SUM(input_tokens + output_tokens + cache_read_tokens + cache_write_tokens) AS t
            FROM daily_rollup
            WHERE source = ?1 AND day >= ?2
            GROUP BY day
            ORDER BY day ASC
            ''',
            [source, sinceDay],
          );
    final calendar = calRows
        .map(
          (r) => CalendarPoint(
            r['day'] as String,
            (r['t'] as num).toInt(),
          ),
        )
        .toList();

    return AgentStats(
      source: source,
      totals: totals,
      perModel: perModel,
      perProject: perProject,
      perInstance: perInstance,
      calendar: calendar,
    );
  }

  Page<UsageRow> usageLog(UsageFilter filter, int page, int pageSize) {
    final safePageSize = pageSize.clamp(1, 500);
    final safePage = page < 0 ? 0 : page;
    final offset = safePage * safePageSize;

    final (whereSql, args) = _buildFilter(filter);
    final totalRows = _db.select(
      'SELECT COUNT(*) AS c FROM usage_events $whereSql',
      args,
    );
    final total = (totalRows.first['c'] as num).toInt();

    final dataRows = _db.select(
      '''
      SELECT id, ts_ms, source, surface, instance, provider, model, model_norm,
             project, session_id, input_tokens, output_tokens,
             cache_read_tokens, cache_write_tokens, reasoning_tokens, cost_usd
      FROM usage_events
      $whereSql
      ORDER BY ts_ms DESC, id DESC
      LIMIT $safePageSize OFFSET $offset
      ''',
      args,
    );

    final rows = dataRows.map((r) {
      final cost = (r['cost_usd'] as num?)?.toDouble();
      return UsageRow(
        id: (r['id'] as num).toInt(),
        tsMs: (r['ts_ms'] as num).toInt(),
        source: r['source'] as String,
        surface: r['surface'] as String,
        instance: r['instance'] as String,
        provider: r['provider'] as String?,
        model: r['model'] as String,
        modelNorm: r['model_norm'] as String,
        project: r['project'] as String?,
        sessionId: (r['session_id'] as String?) ?? '',
        inputTokens: (r['input_tokens'] as num?)?.toInt() ?? 0,
        outputTokens: (r['output_tokens'] as num?)?.toInt() ?? 0,
        cacheReadTokens: (r['cache_read_tokens'] as num?)?.toInt() ?? 0,
        cacheWriteTokens: (r['cache_write_tokens'] as num?)?.toInt() ?? 0,
        reasoningTokens: (r['reasoning_tokens'] as num?)?.toInt() ?? 0,
        costUsd: cost,
        unpriced: cost == null,
      );
    }).toList();

    return Page<UsageRow>(
      rows: rows,
      total: total,
      page: safePage,
      pageSize: safePageSize,
    );
  }

  List<MonthlyStat> monthlyStats(UsageFilter filter) {
    final (whereSql, args) = _buildFilter(filter);
    final rows = _db.select(
      '''
      SELECT
        strftime('%Y-%m', ts_ms / 1000, 'unixepoch', 'localtime') AS ym,
        source,
        SUM(input_tokens) AS inp,
        SUM(output_tokens) AS outp,
        SUM(cache_read_tokens) AS cr,
        SUM(cache_write_tokens) AS cw,
        SUM(reasoning_tokens) AS reas,
        COALESCE(SUM(cost_usd), 0.0) AS cost,
        COUNT(*) AS ev,
        SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END) AS unpriced
      FROM usage_events
      $whereSql
      GROUP BY ym, source
      ORDER BY ym DESC
      ''',
      args,
    );

    final byMonth = <String, List<(String, TokenBreakdown)>>{};
    final monthOrder = <String>[];
    for (final r in rows) {
      final ym = (r['ym'] as String?) ?? 'unknown';
      final src = r['source'] as String;
      final b = _breakdownFromRow(r);
      if (!byMonth.containsKey(ym)) {
        monthOrder.add(ym);
        byMonth[ym] = [];
      }
      byMonth[ym]!.add((src, b));
    }

    return monthOrder.map((month) {
      final entries = byMonth[month]!
        ..sort((a, b) => b.$2.totalTokens.compareTo(a.$2.totalTokens));
      var totals = const TokenBreakdown();
      for (final e in entries) {
        totals = _addBreakdowns(totals, e.$2);
      }
      final bySource = entries.map((e) {
        final share =
            totals.totalTokens == 0 ? 0.0 : e.$2.totalTokens / totals.totalTokens;
        return GroupStat(
          key: e.$1,
          label: e.$1,
          totals: e.$2,
          share: share,
          unpriced: e.$2.unpricedEvents > 0,
        );
      }).toList();
      return MonthlyStat(month: month, totals: totals, bySource: bySource);
    }).toList();
  }

  /// Anti-Jank Rule 2 & 4: Uses `idx_ev_src_inst_ts` and cached `detectedPaths` map
  /// without touching the filesystem on the UI isolate.
  List<SourceHealth> sourceHealth({
    required AppSettings settings,
    required Map<String, List<String>> detectedPathsBySource,
    required Set<String> realtimeSources,
  }) {
    final statusRows = _db.select('''
      SELECT source, instance, last_scan_ms, last_error, file_count, skipped_rows, detected_paths
      FROM source_status
    ''');
    final recorded = <(String, String), Row>{
      for (final r in statusRows)
        (r['source'] as String, r['instance'] as String): r,
    };

    final countRows = _db.select('''
      SELECT source, instance, COUNT(*) AS cnt, MAX(ts_ms) AS max_ts
      FROM usage_events
      GROUP BY source, instance
    ''');
    final counts = <(String, String), (int, int?)>{
      for (final r in countRows)
        (r['source'] as String, r['instance'] as String): (
          (r['cnt'] as num).toInt(),
          (r['max_ts'] as num?)?.toInt(),
        ),
    };

    final remoteInstances = listRemote();
    final out = <SourceHealth>[];

    for (final src in SourceIds.all) {
      final enabled = settings.sourceEnabled(src);
      final detected = detectedPathsBySource[src] ?? const [];
      final isRealtime = realtimeSources.contains(src);
      final rec = recorded[(src, kLocalInstance)];
      final cnt = counts[(src, kLocalInstance)] ?? (0, null);
      final lastErr = rec?['last_error'] as String?;

      final status = !enabled
          ? HealthStatus.disabled
          : (lastErr != null && lastErr.isNotEmpty)
              ? HealthStatus.error
              : detected.isEmpty
                  ? HealthStatus.missing
                  : isRealtime
                      ? HealthStatus.live
                      : HealthStatus.polling;

      List<String> paths = detected;
      if (paths.isEmpty && rec != null) {
        try {
          final decoded = jsonDecode(rec['detected_paths'] as String? ?? '[]');
          if (decoded is List) {
            paths = decoded.map((e) => e.toString()).toList();
          }
        } catch (_) {}
      }

      out.add(
        SourceHealth(
          source: src,
          instance: kLocalInstance,
          status: status,
          detectedPaths: paths,
          fileCount: (rec?['file_count'] as num?)?.toInt() ?? 0,
          eventCount: cnt.$1,
          lastScanMs: (rec?['last_scan_ms'] as num?)?.toInt(),
          lastEventMs: cnt.$2,
          lastError: lastErr,
          skippedRows: (rec?['skipped_rows'] as num?)?.toInt() ?? 0,
        ),
      );
    }

    for (final remote in remoteInstances) {
      final rec = recorded[(remote.agent, remote.name)];
      final cnt = counts[(remote.agent, remote.name)] ?? (0, null);
      final lastErr = rec?['last_error'] as String?;
      final status = !remote.enabled
          ? HealthStatus.disabled
          : (lastErr != null && lastErr.isNotEmpty)
              ? HealthStatus.error
              : HealthStatus.polling;

      out.add(
        SourceHealth(
          source: remote.agent,
          instance: remote.name,
          status: status,
          detectedPaths: ['${remote.username}@${remote.host}:${remote.port}'],
          fileCount: (rec?['file_count'] as num?)?.toInt() ?? 0,
          eventCount: cnt.$1,
          lastScanMs: (rec?['last_scan_ms'] as num?)?.toInt(),
          lastEventMs: cnt.$2,
          lastError: lastErr,
          skippedRows: (rec?['skipped_rows'] as num?)?.toInt() ?? 0,
        ),
      );
    }

    return out;
  }

  FilterOptions filterOptions() {
    List<String> distinct(String col) {
      final rows = _db.select(
        'SELECT DISTINCT $col AS v FROM usage_events WHERE $col IS NOT NULL AND $col != \'\' ORDER BY v',
      );
      return rows.map((r) => r['v'] as String).toList();
    }

    return FilterOptions(
      source: distinct('source'),
      provider: distinct('provider'),
      modelNorm: distinct('model_norm'),
      instance: distinct('instance'),
    );
  }

  // ----------------------------------------------------------------- exports

  String exportCsv(UsageFilter filter, String outPath) {
    final (whereSql, args) = _buildFilter(filter);
    final rows = _db.select(
      '''
      SELECT ts_ms, source, surface, instance, COALESCE(provider,'') AS prov,
             model, model_norm, COALESCE(project,'') AS proj, session_id,
             input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
             reasoning_tokens, cost_usd
      FROM usage_events
      $whereSql
      ORDER BY ts_ms DESC
      ''',
      args,
    );

    final buf = StringBuffer();
    buf.writeln(
      'timestamp_ms,iso_time,source,surface,instance,provider,model,model_norm,project,session_id,'
      'input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,cost_usd',
    );
    for (final r in rows) {
      final ts = (r['ts_ms'] as num).toInt();
      final iso = DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true)
          .toIso8601String();
      final cost = (r['cost_usd'] as num?)?.toDouble();
      final costCell = cost != null ? cost.toStringAsFixed(6) : '';
      buf.writeln(
        '$ts,$iso,${_csvEscape(r['source'] as String)},${_csvEscape(r['surface'] as String)},'
        '${_csvEscape(r['instance'] as String)},${_csvEscape(r['prov'] as String)},'
        '${_csvEscape(r['model'] as String)},${_csvEscape(r['model_norm'] as String)},'
        '${_csvEscape(r['proj'] as String)},${_csvEscape((r['session_id'] as String?) ?? '')},'
        '${r['input_tokens']},${r['output_tokens']},${r['cache_read_tokens']},'
        '${r['cache_write_tokens']},${r['reasoning_tokens']},$costCell',
      );
    }
    final f = File(outPath);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(buf.toString());
    return outPath;
  }

  String exportJson(UsageFilter filter, String outPath) {
    final page = usageLog(filter, 0, 50000);
    const encoder = JsonEncoder.withIndent('  ');
    final f = File(outPath);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(
      encoder.convert(page.rows.map((r) => r.toJson()).toList()),
    );
    return outPath;
  }

  String exportMonthlyReport(UsageFilter filter, String outPath) {
    final months = monthlyStats(filter);
    const encoder = JsonEncoder.withIndent('  ');
    final f = File(outPath);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(
      encoder.convert(months.map((m) => m.toJson()).toList()),
    );
    return outPath;
  }

  static String _csvEscape(String s) {
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  // ----------------------------------------------------------------- secrets & remote

  void putSecret(String key, Uint8List blob) {
    _db.execute(
      'INSERT OR REPLACE INTO settings_kv(key, value) VALUES (?1, ?2)',
      [key, blob],
    );
  }

  Uint8List? getSecret(String key) {
    final rows = _db.select(
      'SELECT value FROM settings_kv WHERE key = ?1',
      [key],
    );
    if (rows.isEmpty) return null;
    final val = rows.first['value'];
    if (val is Uint8List) return val;
    if (val is List<int>) return Uint8List.fromList(val);
    return null;
  }

  void deleteSecret(String key) {
    _db.execute('DELETE FROM settings_kv WHERE key = ?1', [key]);
  }

  List<RemoteInstance> listRemote() {
    final rows = _db.select('''
      SELECT name, agent, host, port, username, auth_mode, key_path,
             remote_home, remote_path, poll_secs, import_archives, enabled,
             secret_dpapi IS NOT NULL AS has_secret, proxy_url
      FROM remote_instances
      ORDER BY name
    ''');
    return rows
        .map(
          (r) => RemoteInstance(
            name: r['name'] as String,
            agent: r['agent'] as String,
            host: r['host'] as String,
            port: (r['port'] as num).toInt(),
            username: r['username'] as String,
            authMode: r['auth_mode'] as String,
            keyPath: r['key_path'] as String?,
            remoteHome: r['remote_home'] as String?,
            remotePath: r['remote_path'] as String?,
            pollSecs: (r['poll_secs'] as num).toInt(),
            importArchives: ((r['import_archives'] as num).toInt()) != 0,
            enabled: ((r['enabled'] as num).toInt()) != 0,
            hasSecret: ((r['has_secret'] as num).toInt()) != 0,
            proxyUrl: r['proxy_url'] as String?,
          ),
        )
        .toList();
  }

  void upsertRemote(RemoteInstance inst, Uint8List? secretDpapi) {
    _db.execute(
      '''
      INSERT INTO remote_instances (
        name, agent, host, port, username, auth_mode, key_path,
        secret_dpapi, remote_home, remote_path, poll_secs, import_archives, enabled, proxy_url
      ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)
      ON CONFLICT(name) DO UPDATE SET
        agent           = excluded.agent,
        host            = excluded.host,
        port            = excluded.port,
        username        = excluded.username,
        auth_mode       = excluded.auth_mode,
        key_path        = excluded.key_path,
        secret_dpapi    = COALESCE(excluded.secret_dpapi, remote_instances.secret_dpapi),
        remote_home     = excluded.remote_home,
        remote_path     = excluded.remote_path,
        poll_secs       = excluded.poll_secs,
        import_archives = excluded.import_archives,
        enabled         = excluded.enabled,
        proxy_url       = excluded.proxy_url
      ''',
      [
        inst.name,
        inst.agent,
        inst.host,
        inst.port,
        inst.username,
        inst.authMode,
        inst.keyPath,
        secretDpapi,
        inst.remoteHome,
        inst.remotePath,
        inst.pollSecs,
        inst.importArchives ? 1 : 0,
        inst.enabled ? 1 : 0,
        inst.proxyUrl,
      ],
    );
  }

  void setRemoteHome(String name, String home) {
    _db.execute(
      'UPDATE remote_instances SET remote_home = ?2 WHERE name = ?1',
      [name, home],
    );
  }

  Uint8List? remoteSecret(String name) {
    final rows = _db.select(
      'SELECT secret_dpapi FROM remote_instances WHERE name = ?1',
      [name],
    );
    if (rows.isEmpty) return null;
    final v = rows.first['secret_dpapi'];
    if (v is Uint8List) return v;
    if (v is List<int>) return Uint8List.fromList(v);
    return null;
  }

  void deleteRemote(String name, {bool purgeEvents = false}) {
    _db.execute('DELETE FROM remote_instances WHERE name = ?1', [name]);
    _db.execute('DELETE FROM scan_state WHERE instance = ?1', [name]);
    _db.execute('DELETE FROM source_status WHERE instance = ?1', [name]);
    if (purgeEvents) {
      _db.execute('DELETE FROM usage_events WHERE instance = ?1', [name]);
      _db.execute('DELETE FROM daily_rollup WHERE instance = ?1', [name]);
    }
  }

  // ----------------------------------------------------------------- helpers

  static TokenBreakdown _breakdownFromRow(Row r) {
    final inp = (r['inp'] as num?)?.toInt() ?? 0;
    final outp = (r['outp'] as num?)?.toInt() ?? 0;
    final cr = (r['cr'] as num?)?.toInt() ?? 0;
    final cw = (r['cw'] as num?)?.toInt() ?? 0;
    final reas = (r['reas'] as num?)?.toInt() ?? 0;
    final cost = (r['cost'] as num?)?.toDouble() ?? 0.0;
    final ev = (r['ev'] as num?)?.toInt() ?? 0;
    final unpriced = (r['unpriced'] as num?)?.toInt() ?? 0;
    return TokenBreakdown(
      inputTokens: inp,
      outputTokens: outp,
      cacheReadTokens: cr,
      cacheWriteTokens: cw,
      reasoningTokens: reas,
      totalTokens: inp + outp + cr + cw,
      costUsd: cost,
      events: ev,
      unpricedEvents: unpriced,
    );
  }

  static TokenBreakdown _addBreakdowns(TokenBreakdown a, TokenBreakdown b) {
    return TokenBreakdown(
      inputTokens: a.inputTokens + b.inputTokens,
      outputTokens: a.outputTokens + b.outputTokens,
      cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens,
      cacheWriteTokens: a.cacheWriteTokens + b.cacheWriteTokens,
      reasoningTokens: a.reasoningTokens + b.reasoningTokens,
      totalTokens: a.totalTokens + b.totalTokens,
      costUsd: a.costUsd + b.costUsd,
      events: a.events + b.events,
      unpricedEvents: a.unpricedEvents + b.unpricedEvents,
    );
  }

  static (String, List<Object?>) _buildFilter(UsageFilter f) {
    final clauses = <String>[];
    final args = <Object?>[];

    if (f.from != null) {
      args.add(f.from);
      clauses.add('ts_ms >= ?${args.length}');
    }
    if (f.to != null) {
      args.add(f.to);
      clauses.add('ts_ms <= ?${args.length}');
    }

    void addIn(String col, List<String>? list) {
      if (list == null || list.isEmpty) return;
      final ph = <String>[];
      for (final item in list) {
        args.add(item);
        ph.add('?${args.length}');
      }
      clauses.add('$col IN (${ph.join(',')})');
    }

    addIn('source', f.sources);
    addIn('instance', f.instances);
    addIn('provider', f.providers);
    addIn('model_norm', f.models);

    final q = f.search?.trim();
    if (q != null && q.isNotEmpty) {
      args.add('%$q%');
      final idx = args.length;
      clauses.add(
        '(model LIKE ?$idx OR project LIKE ?$idx OR session_id LIKE ?$idx)',
      );
    }

    if (f.unpricedOnly == true) {
      clauses.add('cost_usd IS NULL');
    }

    if (clauses.isEmpty) {
      return ('', args);
    }
    return ('WHERE ${clauses.join(' AND ')}', args);
  }

  static int startOfLocalDay(int tsMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(tsMs);
    return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
  }

  static int startOfLocalWeek(int tsMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(tsMs);
    final midnight = DateTime(d.year, d.month, d.day);
    final daysFromMonday = midnight.weekday - DateTime.monday;
    return midnight
        .subtract(Duration(days: daysFromMonday))
        .millisecondsSinceEpoch;
  }
}
