//! The aggregate database (`%APPDATA%\GlassUsage\usage.db`).
//!
//! Every collector funnels normalized [`UsageEvent`]s through here. Deduplication is
//! enforced by `UNIQUE(source, instance, dedup_key)` so a collector may re-scan the same
//! region of a log without inflating totals.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use chrono::{DateTime, Datelike, Local, NaiveDate, TimeZone};
use parking_lot::Mutex;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension};

use crate::model::*;

pub struct Store {
    conn: Mutex<Connection>,
    pub path: PathBuf,
}

/// What one token increment contributes to the live RPM/TPM window.
#[derive(Debug, Clone)]
pub struct LiveDelta {
    pub ts_ms: i64,
    pub source: String,
    pub tokens: i64,
    pub is_new_request: bool,
}

#[derive(Debug, Default)]
pub struct InsertOutcome {
    /// Rows inserted or modified.
    pub changed: usize,
    pub deltas: Vec<LiveDelta>,
    pub events: Vec<UsageEvent>,
}

/// How a source's rows should be reconciled on re-scan.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteMode {
    /// Append-only sources: a dedup key that already exists is left untouched.
    InsertOrIgnore,
    /// Snapshot sources (Hermes sessions, OpenCode session rollups) whose rows keep
    /// accumulating: the newest read wins.
    Upsert,
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).ok();
        }
        let conn = Connection::open(path).with_context(|| format!("open {}", path.display()))?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        let store = Self {
            conn: Mutex::new(conn),
            path: path.to_path_buf(),
        };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&self) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS usage_events (
              id INTEGER PRIMARY KEY,
              source TEXT NOT NULL,
              surface TEXT NOT NULL,
              instance TEXT NOT NULL DEFAULT 'local',
              session_id TEXT,
              project TEXT,
              model TEXT NOT NULL,
              model_norm TEXT NOT NULL,
              provider TEXT,
              ts_ms INTEGER NOT NULL,
              input_tokens INTEGER DEFAULT 0,
              output_tokens INTEGER DEFAULT 0,
              cache_read_tokens INTEGER DEFAULT 0,
              cache_write_tokens INTEGER DEFAULT 0,
              reasoning_tokens INTEGER DEFAULT 0,
              cost_usd REAL,
              dedup_key TEXT NOT NULL,
              UNIQUE(source, instance, dedup_key)
            );
            CREATE INDEX IF NOT EXISTS idx_ev_ts ON usage_events(ts_ms);
            CREATE INDEX IF NOT EXISTS idx_ev_src_ts ON usage_events(source, ts_ms);
            CREATE INDEX IF NOT EXISTS idx_ev_model ON usage_events(model_norm);
            CREATE INDEX IF NOT EXISTS idx_ev_inst ON usage_events(instance);

            CREATE TABLE IF NOT EXISTS scan_state (
              source TEXT NOT NULL,
              instance TEXT NOT NULL DEFAULT 'local',
              key TEXT NOT NULL,
              offset INTEGER DEFAULT 0,
              mtime_ms INTEGER DEFAULT 0,
              extra TEXT,
              PRIMARY KEY(source, instance, key)
            );

            CREATE TABLE IF NOT EXISTS remote_instances (
              name TEXT PRIMARY KEY,
              agent TEXT NOT NULL,
              host TEXT NOT NULL,
              port INTEGER DEFAULT 22,
              username TEXT NOT NULL,
              auth_mode TEXT NOT NULL,
              key_path TEXT,
              secret_dpapi BLOB,
              remote_home TEXT,
              remote_path TEXT,
              poll_secs INTEGER DEFAULT 300,
              import_archives INTEGER DEFAULT 0,
              enabled INTEGER DEFAULT 1
            );

            CREATE TABLE IF NOT EXISTS daily_rollup (
              day TEXT NOT NULL,
              source TEXT NOT NULL,
              model_norm TEXT NOT NULL,
              input_tokens INTEGER DEFAULT 0,
              output_tokens INTEGER DEFAULT 0,
              cache_read_tokens INTEGER DEFAULT 0,
              cache_write_tokens INTEGER DEFAULT 0,
              reasoning_tokens INTEGER DEFAULT 0,
              cost_usd REAL DEFAULT 0,
              events INTEGER DEFAULT 0,
              PRIMARY KEY(day, source, model_norm)
            );

            CREATE TABLE IF NOT EXISTS source_status (
              source TEXT NOT NULL,
              instance TEXT NOT NULL DEFAULT 'local',
              last_scan_ms INTEGER,
              last_error TEXT,
              file_count INTEGER DEFAULT 0,
              skipped_rows INTEGER DEFAULT 0,
              detected_paths TEXT,
              PRIMARY KEY(source, instance)
            );
            "#,
        )?;
        Self::ensure_column(&conn, "remote_instances", "proxy_url", "TEXT")?;
        Ok(())
    }

    /// Idempotent column add for tables created before the column existed.
    fn ensure_column(
        conn: &rusqlite::Connection,
        table: &str,
        column: &str,
        col_type: &str,
    ) -> Result<()> {
        let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
        let exists = stmt
            .query_map([], |r| r.get::<_, String>(1))?
            .filter_map(|r| r.ok())
            .any(|name| name == column);
        if !exists {
            conn.execute(
                &format!("ALTER TABLE {table} ADD COLUMN {column} {col_type}"),
                [],
            )?;
        }
        Ok(())
    }

    /// Insert a batch of events.
    ///
    /// The returned deltas are what actually changed, which matters for upsert sources:
    /// re-reading a streamed Claude message whose token count grew must contribute only
    /// the increment to the live rate window, never the full total a second time.
    pub fn insert_events(&self, events: &[UsageEvent], mode: WriteMode) -> Result<InsertOutcome> {
        self.ingest_scan(events, mode, &[])
    }

    /// Persist a collector result and its watermarks as one transaction.
    pub fn ingest_scan(
        &self,
        events: &[UsageEvent],
        mode: WriteMode,
        states: &[PendingScanState],
    ) -> Result<InsertOutcome> {
        if events.is_empty() && states.is_empty() {
            return Ok(InsertOutcome::default());
        }
        let mut conn = self.conn.lock();

        // Snapshot the totals of any rows this batch will overwrite.
        let mut prior: HashMap<(String, String, String), (i64, i64)> = HashMap::new();
        if mode == WriteMode::Upsert {
            let mut stmt = conn.prepare_cached(
                "SELECT input_tokens + output_tokens + cache_read_tokens + cache_write_tokens,
                        ts_ms
                 FROM usage_events WHERE source=?1 AND instance=?2 AND dedup_key=?3",
            )?;
            for e in events {
                if let Some(existing) = stmt
                    .query_row(params![e.source, e.instance, e.dedup_key], |r| {
                        Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
                    })
                    .optional()?
                {
                    prior.insert(
                        (e.source.clone(), e.instance.clone(), e.dedup_key.clone()),
                        existing,
                    );
                }
            }
        }

        let tx = conn.transaction()?;
        let mut accepted = Vec::new();
        let mut running_totals = prior.clone();
        let mut delta_bases = Vec::new();
        {
            let sql = match mode {
                WriteMode::InsertOrIgnore => {
                    "INSERT OR IGNORE INTO usage_events
                     (source, surface, instance, session_id, project, model, model_norm, provider,
                      ts_ms, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                      reasoning_tokens, cost_usd, dedup_key)
                     VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)"
                }
                WriteMode::Upsert => {
                    "INSERT INTO usage_events
                     (source, surface, instance, session_id, project, model, model_norm, provider,
                      ts_ms, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                      reasoning_tokens, cost_usd, dedup_key)
                     VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)
                     ON CONFLICT(source, instance, dedup_key) DO UPDATE SET
                       surface=excluded.surface, session_id=excluded.session_id,
                       project=excluded.project, model=excluded.model,
                       model_norm=excluded.model_norm, provider=excluded.provider,
                       ts_ms=excluded.ts_ms,
                       input_tokens=excluded.input_tokens, output_tokens=excluded.output_tokens,
                       cache_read_tokens=excluded.cache_read_tokens,
                       cache_write_tokens=excluded.cache_write_tokens,
                       reasoning_tokens=excluded.reasoning_tokens,
                       cost_usd=excluded.cost_usd
                      WHERE excluded.input_tokens != usage_events.input_tokens
                         OR excluded.output_tokens != usage_events.output_tokens
                         OR excluded.cache_read_tokens != usage_events.cache_read_tokens
                         OR excluded.cache_write_tokens != usage_events.cache_write_tokens
                         OR excluded.reasoning_tokens != usage_events.reasoning_tokens
                         OR excluded.surface IS NOT usage_events.surface
                         OR excluded.session_id IS NOT usage_events.session_id
                         OR excluded.project IS NOT usage_events.project
                         OR excluded.model IS NOT usage_events.model
                         OR excluded.model_norm IS NOT usage_events.model_norm
                         OR excluded.provider IS NOT usage_events.provider
                         OR excluded.ts_ms != usage_events.ts_ms
                         OR excluded.cost_usd IS NOT usage_events.cost_usd"
                }
            };
            let mut stmt = tx.prepare_cached(sql)?;
            for e in events {
                let changed = stmt.execute(params![
                    e.source,
                    e.surface,
                    e.instance,
                    e.session_id,
                    e.project,
                    e.model,
                    e.model_norm,
                    e.provider,
                    e.timestamp,
                    e.input_tokens,
                    e.output_tokens,
                    e.cache_read_tokens,
                    e.cache_write_tokens,
                    e.reasoning_tokens,
                    e.cost_usd,
                    e.dedup_key,
                ])?;
                if changed > 0 {
                    let key = (e.source.clone(), e.instance.clone(), e.dedup_key.clone());
                    let existing = running_totals.get(&key);
                    let before = existing.map(|(total, _)| *total).unwrap_or(0);
                    delta_bases.push((before, existing.is_none()));
                    running_totals.insert(key, (e.total_tokens(), e.timestamp));
                    accepted.push(e.clone());
                }
            }
        }

        for pending in states {
            tx.execute(
                "INSERT INTO scan_state (source, instance, key, offset, mtime_ms, extra)
                 VALUES (?1,?2,?3,?4,?5,?6)
                 ON CONFLICT(source, instance, key) DO UPDATE SET
                   offset=excluded.offset, mtime_ms=excluded.mtime_ms, extra=excluded.extra",
                params![
                    pending.source,
                    pending.instance,
                    pending.key,
                    pending.state.offset,
                    pending.state.mtime_ms,
                    pending.state.extra
                ],
            )?;
        }

        let mut touched: HashSet<String> = days_touched(&accepted).into_iter().collect();
        for event in &accepted {
            if let Some((_, old_ts)) = prior.get(&(
                event.source.clone(),
                event.instance.clone(),
                event.dedup_key.clone(),
            )) {
                if let Some(day) = day_for_timestamp(*old_ts) {
                    touched.insert(day);
                }
            }
        }
        let mut touched: Vec<String> = touched.into_iter().collect();
        touched.sort();
        if !touched.is_empty() {
            rebuild_rollup_days_tx(&tx, &touched)?;
        }
        tx.commit()?;

        let deltas = accepted
            .iter()
            .zip(delta_bases)
            .map(|(e, (before, is_new_request))| {
                LiveDelta {
                    ts_ms: e.timestamp,
                    source: e.source.clone(),
                    tokens: (e.total_tokens() - before).max(0),
                    // A grown row is the same call reported again, not a new request.
                    is_new_request,
                }
            })
            .collect();

        Ok(InsertOutcome {
            changed: accepted.len(),
            deltas,
            events: accepted,
        })
    }

    pub fn rebuild_all_rollups(&self) -> Result<()> {
        let mut conn = self.conn.lock();
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM daily_rollup", [])?;
        tx.execute(
            r#"
            INSERT INTO daily_rollup
              (day, source, model_norm, input_tokens, output_tokens, cache_read_tokens,
               cache_write_tokens, reasoning_tokens, cost_usd, events)
            SELECT date(ts_ms/1000, 'unixepoch', 'localtime') AS d, source, model_norm,
                   SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens),
                   SUM(cache_write_tokens), SUM(reasoning_tokens),
                   SUM(COALESCE(cost_usd, 0)), COUNT(*)
            FROM usage_events GROUP BY d, source, model_norm
            "#,
            [],
        )?;
        tx.commit()?;
        Ok(())
    }

    // ---------------------------------------------------------------- scan state

    pub fn get_scan_state(&self, source: &str, instance: &str, key: &str) -> Option<ScanState> {
        let conn = self.conn.lock();
        conn.query_row(
            "SELECT offset, mtime_ms, extra FROM scan_state WHERE source=?1 AND instance=?2 AND key=?3",
            params![source, instance, key],
            |r| {
                Ok(ScanState {
                    offset: r.get(0)?,
                    mtime_ms: r.get(1)?,
                    extra: r.get(2)?,
                })
            },
        )
        .optional()
        .ok()
        .flatten()
    }

    pub fn set_scan_state(
        &self,
        source: &str,
        instance: &str,
        key: &str,
        st: &ScanState,
    ) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO scan_state (source, instance, key, offset, mtime_ms, extra)
             VALUES (?1,?2,?3,?4,?5,?6)
             ON CONFLICT(source, instance, key) DO UPDATE SET
               offset=excluded.offset, mtime_ms=excluded.mtime_ms, extra=excluded.extra",
            params![source, instance, key, st.offset, st.mtime_ms, st.extra],
        )?;
        Ok(())
    }

    pub fn clear_scan_state(&self, source: &str, instance: Option<&str>) -> Result<()> {
        let conn = self.conn.lock();
        match instance {
            Some(i) => conn.execute(
                "DELETE FROM scan_state WHERE source=?1 AND instance=?2",
                params![source, i],
            )?,
            None => conn.execute("DELETE FROM scan_state WHERE source=?1", params![source])?,
        };
        Ok(())
    }

    // ------------------------------------------------------------- source status

    pub fn record_status(
        &self,
        source: &str,
        instance: &str,
        file_count: i64,
        skipped: i64,
        detected: &[String],
        error: Option<&str>,
    ) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "INSERT INTO source_status (source, instance, last_scan_ms, last_error, file_count, skipped_rows, detected_paths)
             VALUES (?1,?2,?3,?4,?5,?6,?7)
             ON CONFLICT(source, instance) DO UPDATE SET
               last_scan_ms=excluded.last_scan_ms, last_error=excluded.last_error,
               file_count=excluded.file_count, skipped_rows=excluded.skipped_rows,
               detected_paths=excluded.detected_paths",
            params![
                source,
                instance,
                now_ms(),
                error,
                file_count,
                skipped,
                serde_json::to_string(detected).unwrap_or_else(|_| "[]".into())
            ],
        )?;
        Ok(())
    }

    pub fn source_health(&self) -> Result<Vec<SourceHealth>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT source, instance, last_scan_ms, last_error, file_count, skipped_rows, detected_paths
             FROM source_status ORDER BY source, instance",
        )?;
        let rows = stmt.query_map([], |r| {
            let detected: String = r
                .get::<_, Option<String>>(6)?
                .unwrap_or_else(|| "[]".into());
            Ok(SourceHealth {
                source: r.get(0)?,
                instance: r.get(1)?,
                status: HealthStatus::Polling,
                detected_paths: serde_json::from_str(&detected).unwrap_or_default(),
                file_count: r.get(4)?,
                event_count: 0,
                last_scan_ms: r.get(2)?,
                last_event_ms: None,
                last_error: r.get(3)?,
                skipped_rows: r.get(5)?,
            })
        })?;
        let mut out: Vec<SourceHealth> = rows.collect::<rusqlite::Result<_>>()?;

        let mut counts = conn.prepare(
            "SELECT source, instance, COUNT(*), MAX(ts_ms) FROM usage_events GROUP BY source, instance",
        )?;
        let map: HashMap<(String, String), (i64, i64)> = counts
            .query_map([], |r| {
                Ok((
                    (r.get::<_, String>(0)?, r.get::<_, String>(1)?),
                    (r.get::<_, i64>(2)?, r.get::<_, i64>(3)?),
                ))
            })?
            .collect::<rusqlite::Result<_>>()?;
        for h in &mut out {
            if let Some((count, last)) = map.get(&(h.source.clone(), h.instance.clone())) {
                h.event_count = *count;
                h.last_event_ms = Some(*last);
            }
        }
        Ok(out)
    }

    // ------------------------------------------------------------------ queries

    pub fn totals_in_range(&self, from: i64, to: i64) -> Result<TokenBreakdown> {
        let conn = self.conn.lock();
        aggregate_row(&conn, "WHERE ts_ms >= ?1 AND ts_ms < ?2", params![from, to])
    }

    /// Same as [`totals_in_range`], optionally limited to the given agent ids.
    /// An empty `sources` list means every agent.
    pub fn totals_in_range_sources(
        &self,
        from: i64,
        to: i64,
        sources: &[String],
    ) -> Result<TokenBreakdown> {
        if sources.is_empty() {
            return self.totals_in_range(from, to);
        }
        let filter = UsageFilter {
            from: Some(from),
            to: Some(to),
            sources: Some(sources.to_vec()),
            instances: None,
            providers: None,
            models: None,
            search: None,
            unpriced_only: None,
        };
        let (where_sql, args) = filter.to_sql();
        let conn = self.conn.lock();
        aggregate_row(&conn, &where_sql, params_from_iter(args.iter()))
    }

    pub fn overview(&self, range: TimeRange) -> Result<OverviewStats> {
        let (today_start, today_end) = day_bounds(0);
        let (yest_start, yest_end) = day_bounds(-1);
        let (week_start, week_end) = week_bounds(0);
        let (lweek_start, lweek_end) = week_bounds(-1);

        let today = self.totals_in_range(today_start, today_end)?;
        let yesterday = self.totals_in_range(yest_start, yest_end)?;
        let this_week = self.totals_in_range(week_start, week_end)?;
        let last_week = self.totals_in_range(lweek_start, lweek_end)?;
        let range_totals = self.totals_in_range(range.from, range.to)?;

        let per_source = self.group_stats(
            "source",
            &UsageFilter {
                from: Some(range.from),
                to: Some(range.to),
                ..Default::default()
            },
        )?;

        Ok(OverviewStats {
            today,
            yesterday,
            this_week,
            last_week,
            range: range_totals,
            per_source,
        })
    }

    /// Aggregate by an arbitrary column (`source`, `provider`, `model_norm`, `project`,
    /// `instance`). The column name is chosen from a fixed allow-list by the caller.
    pub fn group_stats(&self, column: &str, filter: &UsageFilter) -> Result<Vec<GroupStat>> {
        let column = match column {
            "source" | "provider" | "model_norm" | "project" | "instance" | "surface" => column,
            _ => "source",
        };
        let (where_sql, args) = filter.to_sql();
        let conn = self.conn.lock();
        let sql = format!(
            "SELECT COALESCE({col}, '(unknown)'),
                    SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens),
                    SUM(cache_write_tokens), SUM(reasoning_tokens),
                    SUM(COALESCE(cost_usd,0)), COUNT(*),
                    SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END)
             FROM usage_events {where_sql}
             GROUP BY 1
             ORDER BY SUM(input_tokens) + SUM(output_tokens) + SUM(cache_read_tokens)
                      + SUM(cache_write_tokens) DESC",
            col = column,
            where_sql = where_sql
        );
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(args.iter()), |r| {
            let totals = TokenBreakdown {
                input_tokens: r.get(1)?,
                output_tokens: r.get(2)?,
                cache_read_tokens: r.get(3)?,
                cache_write_tokens: r.get(4)?,
                reasoning_tokens: r.get(5)?,
                cost_usd: r.get(6)?,
                events: r.get(7)?,
                unpriced_events: r.get(8)?,
                total_tokens: 0,
            };
            let unpriced: i64 = totals.unpriced_events;
            Ok((r.get::<_, String>(0)?, totals, unpriced))
        })?;

        let mut out: Vec<GroupStat> = Vec::new();
        for row in rows {
            let (key, mut totals, unpriced) = row?;
            totals.total_tokens = totals.input_tokens
                + totals.output_tokens
                + totals.cache_read_tokens
                + totals.cache_write_tokens;
            out.push(GroupStat {
                label: key.clone(),
                key,
                totals,
                share: 0.0,
                unpriced: unpriced > 0,
            });
        }
        let grand: i64 = out.iter().map(|g| g.totals.total_tokens).sum();
        if grand > 0 {
            for g in &mut out {
                g.share = g.totals.total_tokens as f64 / grand as f64;
            }
        }
        Ok(out)
    }

    /// Time series for the trend chart. `bucket` is `hour` or `day`; `group_by` picks
    /// the series key.
    /// Bucketed series, optionally restricted to one source.
    ///
    /// Scoping happens here rather than in the UI because the same model can be served
    /// through several agents; filtering a global series by model name client-side would
    /// attribute another agent's usage to this one.
    pub fn timeseries(
        &self,
        range: TimeRange,
        group_by: &str,
        bucket: &str,
        source: Option<&str>,
    ) -> Result<Vec<SeriesPoint>> {
        // Accepts the same column names as `group_stats`, so the two cannot disagree about
        // what "group by model" means.
        let group_col = match group_by {
            "model" | "model_norm" => "model_norm",
            "provider" => "provider",
            "instance" => "instance",
            "project" => "project",
            "surface" => "surface",
            "total" => "'total'",
            _ => "source",
        };
        // Bucket boundaries are computed in local time so "today" matches the user's clock.
        //
        // SQLite has no `'start of hour'` modifier (it returns NULL), so the hour is truncated
        // by reformatting to `YYYY-MM-DD HH:00:00` and parsing back. The `'utc'` modifier tells
        // unixepoch that the string is local wall time, yielding a correct UTC epoch for the chart.
        let bucket_expr = match bucket {
            "hour" => {
                "unixepoch(strftime('%Y-%m-%d %H:00:00', ts_ms/1000, 'unixepoch', 'localtime'), 'utc')"
            }
            "week" => {
                // Monday 00:00 local of the ISO-ish week containing the event.
                "unixepoch(date(ts_ms/1000, 'unixepoch', 'localtime', 'weekday 0', '-6 days'), 'utc')"
            }
            _ => "unixepoch(date(ts_ms/1000, 'unixepoch', 'localtime'), 'utc')",
        };
        let source_sql = if source.is_some() {
            " AND source = ?3"
        } else {
            ""
        };
        let conn = self.conn.lock();
        let sql = format!(
            "SELECT CAST({bucket_expr} AS INTEGER) AS b, COALESCE({group_col}, '(unknown)') AS k,
                    SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens),
                    SUM(cache_write_tokens), SUM(reasoning_tokens),
                    SUM(COALESCE(cost_usd,0)), COUNT(*), SUM(cost_usd IS NULL)
             FROM usage_events WHERE ts_ms >= ?1 AND ts_ms < ?2{source_sql}
             GROUP BY b, k ORDER BY b"
        );

        let mut args: Vec<Box<dyn rusqlite::ToSql>> =
            vec![Box::new(range.from), Box::new(range.to)];
        if let Some(s) = source {
            args.push(Box::new(s.to_string()));
        }

        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(args.iter()), |r| {
            let mut totals = TokenBreakdown {
                input_tokens: r.get(2)?,
                output_tokens: r.get(3)?,
                cache_read_tokens: r.get(4)?,
                cache_write_tokens: r.get(5)?,
                reasoning_tokens: r.get(6)?,
                cost_usd: r.get(7)?,
                events: r.get(8)?,
                unpriced_events: r.get(9)?,
                total_tokens: 0,
            };
            totals.total_tokens = totals.input_tokens
                + totals.output_tokens
                + totals.cache_read_tokens
                + totals.cache_write_tokens;
            Ok(SeriesPoint {
                // Local-time bucket start, converted back to epoch ms for the chart axis.
                bucket: r.get::<_, i64>(0)? * 1000,
                key: r.get(1)?,
                totals,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn usage_log(
        &self,
        filter: &UsageFilter,
        page: i64,
        page_size: i64,
    ) -> Result<Page<UsageRow>> {
        let (where_sql, args) = filter.to_sql();
        let conn = self.conn.lock();

        let total: i64 = conn.query_row(
            &format!("SELECT COUNT(*) FROM usage_events {where_sql}"),
            params_from_iter(args.iter()),
            |r| r.get(0),
        )?;

        let page_size = page_size.clamp(1, 5000);
        let sql = format!(
            "SELECT id, ts_ms, source, surface, instance, provider, model, model_norm, project,
                    session_id, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                    reasoning_tokens, cost_usd
             FROM usage_events {where_sql}
             ORDER BY ts_ms DESC, id DESC LIMIT {limit} OFFSET {offset}",
            limit = page_size,
            offset = (page.max(0)) * page_size
        );
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(args.iter()), map_usage_row)?;
        Ok(Page {
            rows: rows.collect::<rusqlite::Result<_>>()?,
            total,
            page,
            page_size,
        })
    }

    /// Full result set for CSV export, streamed through a callback so a 10^6-row export
    /// never materializes in memory.
    pub fn for_each_usage_row(
        &self,
        filter: &UsageFilter,
        mut f: impl FnMut(&UsageRow),
    ) -> Result<i64> {
        let (where_sql, args) = filter.to_sql();
        let conn = self.conn.lock();
        let sql = format!(
            "SELECT id, ts_ms, source, surface, instance, provider, model, model_norm, project,
                    session_id, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                    reasoning_tokens, cost_usd
             FROM usage_events {where_sql} ORDER BY ts_ms DESC"
        );
        let mut stmt = conn.prepare(&sql)?;
        let mut rows = stmt.query(params_from_iter(args.iter()))?;
        let mut n = 0;
        while let Some(row) = rows.next()? {
            let r = map_usage_row(row)?;
            f(&r);
            n += 1;
        }
        Ok(n)
    }

    /// Month buckets for bookkeeping exports. Keys are local `YYYY-MM`.
    pub fn monthly_stats(&self, filter: &UsageFilter) -> Result<Vec<MonthlyStat>> {
        let (where_sql, args) = filter.to_sql();
        let months: Vec<(String, TokenBreakdown)> = {
            let conn = self.conn.lock();
            let sql = format!(
                "SELECT strftime('%Y-%m', ts_ms/1000, 'unixepoch', 'localtime') AS month,
                        COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                        COALESCE(SUM(cache_read_tokens),0), COALESCE(SUM(cache_write_tokens),0),
                        COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(cost_usd),0), COUNT(*),
                        COALESCE(SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END),0)
                 FROM usage_events {where_sql}
                 GROUP BY 1
                 ORDER BY 1"
            );
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(params_from_iter(args.iter()), |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    TokenBreakdown {
                        input_tokens: r.get(1)?,
                        output_tokens: r.get(2)?,
                        cache_read_tokens: r.get(3)?,
                        cache_write_tokens: r.get(4)?,
                        reasoning_tokens: r.get(5)?,
                        cost_usd: r.get(6)?,
                        events: r.get(7)?,
                        unpriced_events: r.get(8)?,
                        total_tokens: 0,
                    },
                ))
            })?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
                .into_iter()
                .map(|(month, mut totals)| {
                    totals.total_tokens = totals.input_tokens
                        + totals.output_tokens
                        + totals.cache_read_tokens
                        + totals.cache_write_tokens;
                    (month, totals)
                })
                .collect()
        };

        let mut out = Vec::with_capacity(months.len());
        for (month, totals) in months {
            let by_source = self.monthly_by_source(filter, &month)?;
            out.push(MonthlyStat {
                month,
                totals,
                by_source,
            });
        }
        Ok(out)
    }

    fn monthly_by_source(&self, filter: &UsageFilter, month: &str) -> Result<Vec<GroupStat>> {
        let (where_sql, mut args) = filter.to_sql();
        args.push(Box::new(month.to_string()));
        let month_clause = format!(
            "strftime('%Y-%m', ts_ms/1000, 'unixepoch', 'localtime') = ?{}",
            args.len()
        );
        let full_where = if where_sql.is_empty() {
            format!("WHERE {month_clause}")
        } else {
            format!("{where_sql} AND {month_clause}")
        };
        let conn = self.conn.lock();
        let sql = format!(
            "SELECT COALESCE(source, '(unknown)'),
                    SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens),
                    SUM(cache_write_tokens), SUM(reasoning_tokens),
                    SUM(COALESCE(cost_usd,0)), COUNT(*),
                    SUM(CASE WHEN cost_usd IS NULL THEN 1 ELSE 0 END)
             FROM usage_events {full_where}
             GROUP BY 1
             ORDER BY SUM(input_tokens) + SUM(output_tokens) + SUM(cache_read_tokens)
                      + SUM(cache_write_tokens) DESC"
        );
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(args.iter()), |r| {
            Ok((
                r.get::<_, String>(0)?,
                TokenBreakdown {
                    input_tokens: r.get(1)?,
                    output_tokens: r.get(2)?,
                    cache_read_tokens: r.get(3)?,
                    cache_write_tokens: r.get(4)?,
                    reasoning_tokens: r.get(5)?,
                    cost_usd: r.get(6)?,
                    events: r.get(7)?,
                    unpriced_events: r.get(8)?,
                    total_tokens: 0,
                },
            ))
        })?;
        let mut pairs = Vec::new();
        let mut grand = 0i64;
        for row in rows {
            let (key, mut totals) = row?;
            totals.total_tokens = totals.input_tokens
                + totals.output_tokens
                + totals.cache_read_tokens
                + totals.cache_write_tokens;
            grand += totals.total_tokens;
            pairs.push((key, totals));
        }
        Ok(pairs
            .into_iter()
            .map(|(key, totals)| {
                let share = if grand > 0 {
                    totals.total_tokens as f64 / grand as f64
                } else {
                    0.0
                };
                let unpriced = totals.unpriced_events > 0;
                GroupStat {
                    label: key.clone(),
                    key,
                    totals,
                    share,
                    unpriced,
                }
            })
            .collect())
    }

    pub fn agent_stats(&self, source: &str, range: TimeRange) -> Result<AgentStats> {
        let filter = UsageFilter {
            from: Some(range.from),
            to: Some(range.to),
            sources: Some(vec![source.to_string()]),
            ..Default::default()
        };
        let totals = {
            let conn = self.conn.lock();
            aggregate_row(
                &conn,
                "WHERE source = ?1 AND ts_ms >= ?2 AND ts_ms < ?3",
                params![source, range.from, range.to],
            )?
        };
        let per_model = self.group_stats("model_norm", &filter)?;
        let per_project = self.group_stats("project", &filter)?;
        let per_instance = self.group_stats("instance", &filter)?;

        // A full year of daily totals drives the GitHub-style heat map, independent of
        // the currently selected range.
        let calendar = {
            let conn = self.conn.lock();
            let mut stmt = conn.prepare(
                "SELECT day, SUM(input_tokens + output_tokens + cache_read_tokens + cache_write_tokens)
                 FROM daily_rollup WHERE source = ?1 GROUP BY day ORDER BY day",
            )?;
            let rows = stmt.query_map(params![source], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
            })?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };

        Ok(AgentStats {
            source: source.to_string(),
            totals,
            per_model,
            per_project,
            per_instance,
            calendar,
        })
    }

    pub fn distinct_values(&self, column: &str) -> Result<Vec<String>> {
        let column = match column {
            "provider" | "model_norm" | "instance" | "source" | "project" => column,
            _ => return Ok(Vec::new()),
        };
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(&format!(
            "SELECT DISTINCT {column} FROM usage_events WHERE {column} IS NOT NULL ORDER BY 1"
        ))?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Events since a timestamp, used to warm the live-rate ring buffer at startup.
    pub fn recent_events(&self, since_ms: i64) -> Result<Vec<(i64, String, i64)>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT ts_ms, source, input_tokens + output_tokens + cache_read_tokens + cache_write_tokens
             FROM usage_events WHERE ts_ms >= ?1 ORDER BY ts_ms",
        )?;
        let rows = stmt.query_map(params![since_ms], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn delete_source(&self, source: &str, instance: Option<&str>) -> Result<()> {
        let mut conn = self.conn.lock();
        let days = {
            match instance {
                Some(instance) => {
                    let mut stmt = conn.prepare(
                        "SELECT DISTINCT date(ts_ms/1000, 'unixepoch', 'localtime')
                         FROM usage_events WHERE source=?1 AND instance=?2",
                    )?;
                    let rows =
                        stmt.query_map(params![source, instance], |row| row.get::<_, String>(0))?;
                    rows.collect::<rusqlite::Result<Vec<_>>>()?
                }
                None => {
                    let mut stmt = conn.prepare(
                        "SELECT DISTINCT date(ts_ms/1000, 'unixepoch', 'localtime')
                         FROM usage_events WHERE source=?1",
                    )?;
                    let rows = stmt.query_map(params![source], |row| row.get::<_, String>(0))?;
                    rows.collect::<rusqlite::Result<Vec<_>>>()?
                }
            }
        };
        let tx = conn.transaction()?;
        match instance {
            Some(i) => tx.execute(
                "DELETE FROM usage_events WHERE source=?1 AND instance=?2",
                params![source, i],
            )?,
            None => tx.execute("DELETE FROM usage_events WHERE source=?1", params![source])?,
        };
        rebuild_rollup_days_tx(&tx, &days)?;
        tx.commit()?;
        Ok(())
    }

    /// Re-normalize and re-price rows after the price table or a user override changes.
    ///
    /// Native-cost sources keep their recorded USD, but `model_norm` is still refreshed so
    /// a later exact price entry (e.g. `grok-4.6`) can unstick a stale family match.
    pub fn reprice(&self, pricer: &crate::pricing::Pricing) -> Result<usize> {
        let mut conn = self.conn.lock();
        let changes = {
            let mut stmt = conn.prepare(
                "SELECT id, source, model, model_norm, input_tokens, output_tokens,
                        cache_read_tokens, cache_write_tokens, cost_usd, ts_ms
                 FROM usage_events",
            )?;
            let it = stmt.query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, i64>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, i64>(7)?,
                    r.get::<_, Option<f64>>(8)?,
                    r.get::<_, i64>(9)?,
                ))
            })?;
            let mut changes = Vec::new();
            for row in it {
                let (id, source, model, old_norm, input, output, cread, cwrite, old_cost, ts_ms) =
                    row?;
                let new_norm = pricer.normalize(&model);
                let cost = if crate::pricing::source_has_native_cost(&source) {
                    old_cost
                } else {
                    pricer.cost(&new_norm, input, output, cread, cwrite)
                };
                if new_norm != old_norm || cost != old_cost {
                    changes.push((id, new_norm, cost, ts_ms));
                }
            }
            changes
        };
        if changes.is_empty() {
            return Ok(0);
        }

        let tx = conn.transaction()?;
        let mut touched = HashSet::new();
        {
            let mut stmt = tx.prepare_cached(
                "UPDATE usage_events SET model_norm = ?1, cost_usd = ?2 WHERE id = ?3",
            )?;
            for (id, model_norm, cost, ts_ms) in &changes {
                stmt.execute(params![model_norm, cost, id])?;
                if let Some(day) = day_for_timestamp(*ts_ms) {
                    touched.insert(day);
                }
            }
        }
        let mut touched: Vec<String> = touched.into_iter().collect();
        touched.sort();
        rebuild_rollup_days_tx(&tx, &touched)?;
        tx.commit()?;
        Ok(changes.len())
    }

    // -------------------------------------------------------- remote instances

    pub fn list_remote(&self) -> Result<Vec<crate::remote::RemoteInstance>> {
        let conn = self.conn.lock();
        let mut stmt = conn.prepare(
            "SELECT name, agent, host, port, username, auth_mode, key_path, remote_home,
                    remote_path, poll_secs, import_archives, enabled, secret_dpapi IS NOT NULL,
                    proxy_url
             FROM remote_instances ORDER BY name",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(crate::remote::RemoteInstance {
                name: r.get(0)?,
                agent: r.get(1)?,
                host: r.get(2)?,
                port: r.get(3)?,
                username: r.get(4)?,
                auth_mode: r.get(5)?,
                key_path: r.get(6)?,
                remote_home: r.get(7)?,
                remote_path: r.get(8)?,
                poll_secs: r.get(9)?,
                import_archives: r.get::<_, i64>(10)? == 1,
                enabled: r.get::<_, i64>(11)? == 1,
                has_secret: r.get::<_, i64>(12)? == 1,
                proxy_url: r.get(13)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn upsert_remote(
        &self,
        inst: &crate::remote::RemoteInstance,
        secret: Option<Vec<u8>>,
    ) -> Result<()> {
        let conn = self.conn.lock();
        // A None secret means "leave the stored one alone", so editing an instance without
        // retyping the password does not wipe it.
        if let Some(sec) = secret {
            conn.execute(
                "INSERT INTO remote_instances
                   (name, agent, host, port, username, auth_mode, key_path, secret_dpapi,
                    remote_home, remote_path, poll_secs, import_archives, enabled, proxy_url)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)
                 ON CONFLICT(name) DO UPDATE SET
                   agent=excluded.agent, host=excluded.host, port=excluded.port,
                   username=excluded.username, auth_mode=excluded.auth_mode,
                   key_path=excluded.key_path, secret_dpapi=excluded.secret_dpapi,
                   remote_home=excluded.remote_home, remote_path=excluded.remote_path,
                   poll_secs=excluded.poll_secs, import_archives=excluded.import_archives,
                   enabled=excluded.enabled, proxy_url=excluded.proxy_url",
                params![
                    inst.name,
                    inst.agent,
                    inst.host,
                    inst.port,
                    inst.username,
                    inst.auth_mode,
                    inst.key_path,
                    sec,
                    inst.remote_home,
                    inst.remote_path,
                    inst.poll_secs,
                    inst.import_archives as i64,
                    inst.enabled as i64,
                    inst.proxy_url
                ],
            )?;
        } else {
            conn.execute(
                "INSERT INTO remote_instances
                   (name, agent, host, port, username, auth_mode, key_path,
                    remote_home, remote_path, poll_secs, import_archives, enabled, proxy_url)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
                 ON CONFLICT(name) DO UPDATE SET
                   agent=excluded.agent, host=excluded.host, port=excluded.port,
                   username=excluded.username, auth_mode=excluded.auth_mode,
                   key_path=excluded.key_path, remote_home=excluded.remote_home,
                   remote_path=excluded.remote_path, poll_secs=excluded.poll_secs,
                   import_archives=excluded.import_archives, enabled=excluded.enabled,
                   proxy_url=excluded.proxy_url",
                params![
                    inst.name,
                    inst.agent,
                    inst.host,
                    inst.port,
                    inst.username,
                    inst.auth_mode,
                    inst.key_path,
                    inst.remote_home,
                    inst.remote_path,
                    inst.poll_secs,
                    inst.import_archives as i64,
                    inst.enabled as i64,
                    inst.proxy_url
                ],
            )?;
        }
        Ok(())
    }

    pub fn remote_secret(&self, name: &str) -> Result<Option<Vec<u8>>> {
        let conn = self.conn.lock();
        Ok(conn
            .query_row(
                "SELECT secret_dpapi FROM remote_instances WHERE name = ?1",
                params![name],
                |r| r.get::<_, Option<Vec<u8>>>(0),
            )
            .optional()?
            .flatten())
    }

    pub fn delete_remote(&self, name: &str) -> Result<()> {
        let mut conn = self.conn.lock();
        let days = {
            let mut stmt = conn.prepare(
                "SELECT DISTINCT date(ts_ms/1000, 'unixepoch', 'localtime')
                 FROM usage_events WHERE instance=?1",
            )?;
            let rows = stmt.query_map(params![name], |row| row.get::<_, String>(0))?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        let tx = conn.transaction()?;
        tx.execute(
            "DELETE FROM remote_instances WHERE name = ?1",
            params![name],
        )?;
        tx.execute(
            "DELETE FROM usage_events WHERE instance = ?1",
            params![name],
        )?;
        tx.execute("DELETE FROM scan_state WHERE instance = ?1", params![name])?;
        tx.execute(
            "DELETE FROM source_status WHERE instance = ?1",
            params![name],
        )?;
        rebuild_rollup_days_tx(&tx, &days)?;
        tx.commit()?;
        Ok(())
    }

    pub fn set_remote_home(&self, name: &str, home: &str) -> Result<()> {
        let conn = self.conn.lock();
        conn.execute(
            "UPDATE remote_instances SET remote_home = ?2 WHERE name = ?1",
            params![name, home],
        )?;
        Ok(())
    }
}

fn map_usage_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<UsageRow> {
    let cost: Option<f64> = r.get(15)?;
    Ok(UsageRow {
        id: r.get(0)?,
        ts_ms: r.get(1)?,
        source: r.get(2)?,
        surface: r.get(3)?,
        instance: r.get(4)?,
        provider: r.get(5)?,
        model: r.get(6)?,
        model_norm: r.get(7)?,
        project: r.get(8)?,
        session_id: r.get::<_, Option<String>>(9)?.unwrap_or_default(),
        input_tokens: r.get(10)?,
        output_tokens: r.get(11)?,
        cache_read_tokens: r.get(12)?,
        cache_write_tokens: r.get(13)?,
        reasoning_tokens: r.get(14)?,
        cost_usd: cost,
        unpriced: cost.is_none(),
    })
}

fn aggregate_row(
    conn: &Connection,
    where_sql: &str,
    args: impl rusqlite::Params,
) -> Result<TokenBreakdown> {
    let sql = format!(
        "SELECT COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                COALESCE(SUM(cache_read_tokens),0), COALESCE(SUM(cache_write_tokens),0),
                COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(cost_usd),0), COUNT(*),
                COALESCE(SUM(cost_usd IS NULL),0)
         FROM usage_events {where_sql}"
    );
    let mut b = conn.query_row(&sql, args, |r| {
        Ok(TokenBreakdown {
            input_tokens: r.get(0)?,
            output_tokens: r.get(1)?,
            cache_read_tokens: r.get(2)?,
            cache_write_tokens: r.get(3)?,
            reasoning_tokens: r.get(4)?,
            cost_usd: r.get(5)?,
            events: r.get(6)?,
            unpriced_events: r.get(7)?,
            total_tokens: 0,
        })
    })?;
    b.total_tokens = b.input_tokens + b.output_tokens + b.cache_read_tokens + b.cache_write_tokens;
    Ok(b)
}

impl UsageFilter {
    /// Build a parameterized WHERE clause. Values always go through bind parameters;
    /// only fixed column names are ever interpolated.
    fn to_sql(&self) -> (String, Vec<Box<dyn rusqlite::ToSql>>) {
        let mut clauses: Vec<String> = Vec::new();
        let mut args: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

        if let Some(from) = self.from {
            args.push(Box::new(from));
            clauses.push(format!("ts_ms >= ?{}", args.len()));
        }
        if let Some(to) = self.to {
            args.push(Box::new(to));
            clauses.push(format!("ts_ms < ?{}", args.len()));
        }
        for (col, values) in [
            ("source", &self.sources),
            ("instance", &self.instances),
            ("provider", &self.providers),
            ("model_norm", &self.models),
        ] {
            if let Some(vs) = values {
                if !vs.is_empty() {
                    let mut placeholders = Vec::new();
                    for v in vs {
                        args.push(Box::new(v.clone()));
                        placeholders.push(format!("?{}", args.len()));
                    }
                    clauses.push(format!("{col} IN ({})", placeholders.join(",")));
                }
            }
        }
        if let Some(q) = self.search.as_ref().filter(|s| !s.trim().is_empty()) {
            let like = format!("%{}%", q.trim());
            let base = args.len();
            args.push(Box::new(like.clone()));
            args.push(Box::new(like.clone()));
            args.push(Box::new(like));
            clauses.push(format!(
                "(model LIKE ?{} OR project LIKE ?{} OR session_id LIKE ?{})",
                base + 1,
                base + 2,
                base + 3
            ));
        }
        if self.unpriced_only == Some(true) {
            clauses.push("cost_usd IS NULL".into());
        }

        if clauses.is_empty() {
            (String::new(), args)
        } else {
            (format!("WHERE {}", clauses.join(" AND ")), args)
        }
    }
}

pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

fn days_touched(events: &[UsageEvent]) -> Vec<String> {
    let mut days: Vec<String> = events
        .iter()
        .filter_map(|e| day_for_timestamp(e.timestamp))
        .collect();
    days.sort();
    days.dedup();
    days
}

fn day_for_timestamp(timestamp: i64) -> Option<String> {
    Local
        .timestamp_millis_opt(timestamp)
        .single()
        .map(|d| d.format("%Y-%m-%d").to_string())
}

fn rebuild_rollup_days_tx(tx: &rusqlite::Transaction<'_>, days: &[String]) -> Result<()> {
    for day in days {
        tx.execute("DELETE FROM daily_rollup WHERE day = ?1", params![day])?;
        tx.execute(
            r#"
            INSERT INTO daily_rollup
              (day, source, model_norm, input_tokens, output_tokens, cache_read_tokens,
               cache_write_tokens, reasoning_tokens, cost_usd, events)
            SELECT date(ts_ms/1000, 'unixepoch', 'localtime') AS d, source, model_norm,
                   SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens),
                   SUM(cache_write_tokens), SUM(reasoning_tokens),
                   SUM(COALESCE(cost_usd, 0)), COUNT(*)
            FROM usage_events
            WHERE date(ts_ms/1000, 'unixepoch', 'localtime') = ?1
            GROUP BY d, source, model_norm
            "#,
            params![day],
        )?;
    }
    Ok(())
}

/// Local-midnight boundaries for `today + offset_days`.
pub fn day_bounds(offset_days: i64) -> (i64, i64) {
    let today = Local::now().date_naive();
    let day = today + chrono::Duration::days(offset_days);
    (
        start_of_day(day),
        start_of_day(day + chrono::Duration::days(1)),
    )
}

/// Monday-based week boundaries for `this week + offset_weeks`.
pub fn week_bounds(offset_weeks: i64) -> (i64, i64) {
    let today = Local::now().date_naive();
    let monday = today - chrono::Duration::days(today.weekday().num_days_from_monday() as i64)
        + chrono::Duration::weeks(offset_weeks);
    (
        start_of_day(monday),
        start_of_day(monday + chrono::Duration::weeks(1)),
    )
}

fn start_of_day(d: NaiveDate) -> i64 {
    let naive = d.and_hms_opt(0, 0, 0).unwrap();
    Local
        .from_local_datetime(&naive)
        .single()
        .map(|dt: DateTime<Local>| dt.timestamp_millis())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary_store(label: &str) -> (Store, PathBuf) {
        let path = std::env::temp_dir().join(format!(
            "glassusage-{label}-{}-{}.db",
            std::process::id(),
            now_ms()
        ));
        (Store::open(&path).expect("open temporary store"), path)
    }

    fn event(key: &str, timestamp: i64) -> UsageEvent {
        let mut event = UsageEvent::new("opencode", "cli", "local", key.to_string());
        event.model = "test-model".into();
        event.model_norm = "test-model".into();
        event.timestamp = timestamp;
        event.input_tokens = 10;
        event.output_tokens = 5;
        event.cost_usd = Some(0.25);
        event
    }

    fn cleanup(store: Store, path: PathBuf) {
        drop(store);
        std::fs::remove_file(&path).ok();
        std::fs::remove_file(path.with_extension("db-wal")).ok();
        std::fs::remove_file(path.with_extension("db-shm")).ok();
    }

    #[test]
    fn failed_event_write_does_not_advance_watermark() {
        let (store, path) = temporary_store("atomic-watermark");
        {
            let conn = store.conn.lock();
            conn.execute_batch(
                "CREATE TRIGGER reject_usage BEFORE INSERT ON usage_events
                 BEGIN SELECT RAISE(ABORT, 'injected write failure'); END;",
            )
            .unwrap();
        }
        let timestamp = Local
            .with_ymd_and_hms(2025, 1, 10, 12, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let pending = PendingScanState {
            source: "opencode".into(),
            instance: "local".into(),
            key: "db".into(),
            state: ScanState {
                offset: 42,
                mtime_ms: timestamp,
                extra: None,
            },
        };

        assert!(store
            .ingest_scan(&[event("one", timestamp)], WriteMode::Upsert, &[pending])
            .is_err());
        assert!(store.get_scan_state("opencode", "local", "db").is_none());
        cleanup(store, path);
    }

    #[test]
    fn upsert_updates_non_token_fields_and_both_rollup_days() {
        let (store, path) = temporary_store("upsert-rollup");
        let first_ts = Local
            .with_ymd_and_hms(2025, 1, 10, 12, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let second_ts = Local
            .with_ymd_and_hms(2025, 1, 11, 12, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        store
            .insert_events(&[event("same", first_ts)], WriteMode::Upsert)
            .unwrap();

        let mut changed = event("same", second_ts);
        changed.reasoning_tokens = 3;
        changed.cost_usd = Some(0.75);
        let outcome = store.insert_events(&[changed], WriteMode::Upsert).unwrap();
        assert_eq!(outcome.changed, 1);

        let conn = store.conn.lock();
        let old_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM daily_rollup WHERE day='2025-01-10'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let (reasoning, cost): (i64, f64) = conn
            .query_row(
                "SELECT reasoning_tokens, cost_usd FROM daily_rollup WHERE day='2025-01-11'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        drop(conn);
        assert_eq!(old_count, 0);
        assert_eq!(reasoning, 3);
        assert!((cost - 0.75).abs() < f64::EPSILON);
        cleanup(store, path);
    }

    #[test]
    fn deleting_source_rebuilds_affected_rollup() {
        let (store, path) = temporary_store("delete-rollup");
        let timestamp = Local
            .with_ymd_and_hms(2025, 1, 10, 12, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let first = event("first", timestamp);
        let mut second = event("second", timestamp);
        second.source = "claude".into();
        store
            .insert_events(&[first, second], WriteMode::InsertOrIgnore)
            .unwrap();
        store.delete_source("opencode", None).unwrap();

        let conn = store.conn.lock();
        let opencode: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM daily_rollup WHERE source='opencode'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let claude: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM daily_rollup WHERE source='claude'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        drop(conn);
        assert_eq!(opencode, 0);
        assert_eq!(claude, 1);
        cleanup(store, path);
    }

    #[test]
    fn repeated_upserts_in_one_batch_emit_incremental_live_deltas() {
        let (store, path) = temporary_store("batch-live-deltas");
        let timestamp = Local
            .with_ymd_and_hms(2025, 1, 10, 12, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let mut first = event("same", timestamp);
        first.input_tokens = 10;
        let mut second = first.clone();
        second.input_tokens = 15;

        let outcome = store
            .insert_events(&[first, second], WriteMode::Upsert)
            .unwrap();
        assert_eq!(outcome.changed, 2);
        assert_eq!(outcome.deltas.len(), 2);
        assert_eq!(outcome.deltas[0].tokens, 15);
        assert!(outcome.deltas[0].is_new_request);
        assert_eq!(outcome.deltas[1].tokens, 5);
        assert!(!outcome.deltas[1].is_new_request);
        cleanup(store, path);
    }

    #[test]
    fn reprice_renormalizes_stale_family_match_and_keeps_native_cost() {
        let (store, path) = temporary_store("reprice-norm");
        let timestamp = Local
            .with_ymd_and_hms(2025, 1, 10, 12, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let mut stale = event("pi-grok", timestamp);
        stale.source = "pi".into();
        stale.model = "grok-4.6".into();
        stale.model_norm = "grok-4".into();
        stale.cost_usd = Some(1.23);
        store
            .insert_events(&[stale], WriteMode::InsertOrIgnore)
            .unwrap();

        let dir = std::env::temp_dir().join(format!(
            "glassusage-reprice-pricing-{}-{}",
            std::process::id(),
            now_ms()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let pricing = crate::pricing::Pricing::new(&dir);
        assert_eq!(store.reprice(&pricing).unwrap(), 1);

        let conn = store.conn.lock();
        let (norm, cost): (String, f64) = conn
            .query_row(
                "SELECT model_norm, cost_usd FROM usage_events WHERE dedup_key='pi-grok'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        let rollup: String = conn
            .query_row(
                "SELECT model_norm FROM daily_rollup WHERE source='pi'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        drop(conn);
        assert_eq!(norm, "grok-4.6");
        assert!((cost - 1.23).abs() < f64::EPSILON);
        assert_eq!(rollup, "grok-4.6");
        cleanup(store, path);
        let _ = std::fs::remove_dir_all(dir);
    }
}
