//! Hermes Agent.
//!
//! `sessions` rows accumulate totals while a session runs, so this is a snapshot source:
//! the whole table is re-read each pass and rows are upserted keyed by session id.
//! The same code serves remote instances by pointing `root_override` at a downloaded
//! snapshot directory.

use std::path::PathBuf;

use anyhow::Result;

use super::*;
use crate::model::{source, surface, UsageEvent};

pub struct HermesCollector;

impl HermesCollector {
    /// `HERMES_HOME` may list several roots separated by commas or the platform path
    /// separator, matching the behaviour of the ccusage adapter.
    fn homes(settings: &AppSettings) -> Vec<PathBuf> {
        if let Some(custom) = settings.custom_path(source::HERMES) {
            return vec![custom];
        }
        if let Ok(v) = std::env::var("HERMES_HOME") {
            let parts: Vec<PathBuf> = v
                .split([',', ';'])
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .map(PathBuf::from)
                .collect();
            if !parts.is_empty() {
                return parts;
            }
        }
        vec![home_dir().join(".hermes")]
    }

    /// The root database plus every profile database.
    pub fn databases_under(root: &std::path::Path) -> Vec<PathBuf> {
        let mut out = Vec::new();
        let main = root.join("state.db");
        if main.is_file() {
            out.push(main);
        }
        let profiles = root.join("profiles");
        if let Ok(entries) = std::fs::read_dir(&profiles) {
            for e in entries.filter_map(|e| e.ok()) {
                let db = e.path().join("state.db");
                if db.is_file() {
                    out.push(db);
                }
            }
        }
        out
    }

    fn databases(settings: &AppSettings) -> Vec<PathBuf> {
        Self::homes(settings)
            .iter()
            .flat_map(|r| Self::databases_under(r))
            .collect()
    }
}

impl Collector for HermesCollector {
    fn id(&self) -> &'static str {
        source::HERMES
    }

    fn label(&self) -> &'static str {
        "Hermes Agent"
    }

    fn detect(&self, settings: &AppSettings) -> Vec<PathBuf> {
        Self::databases(settings)
    }

    fn watch_paths(&self, settings: &AppSettings) -> Vec<PathBuf> {
        Self::homes(settings)
            .into_iter()
            .filter(|p| p.is_dir())
            .collect()
    }

    /// Session rows keep growing while a session is live, so the latest read wins.
    fn write_mode(&self) -> WriteMode {
        WriteMode::Upsert
    }

    fn scan(&self, ctx: &ScanCtx) -> Result<ScanReport> {
        let dbs = match &ctx.root_override {
            Some(root) => {
                let mut v = Self::databases_under(root);
                // Remote snapshots may land as a flat set of .db files.
                if v.is_empty() {
                    v = find_files(root, |p| has_ext(p, "db"));
                }
                v
            }
            None => Self::databases(ctx.settings),
        };

        let mut report = ScanReport {
            files_seen: dbs.len() as i64,
            detected_paths: dbs
                .iter()
                .map(|p| p.to_string_lossy().to_string())
                .collect(),
            ..Default::default()
        };
        for db in &dbs {
            match scan_db(ctx, db) {
                Ok(r) => report.merge(r),
                Err(e) => {
                    report.skipped += 1;
                    tracing::warn!("hermes: {} -> {e}", db.display());
                }
            }
        }
        report.events = finalize(report.events, ctx.pricing);
        Ok(report)
    }
}

fn scan_db(ctx: &ScanCtx, db_path: &std::path::Path) -> Result<ScanReport> {
    let conn = open_sqlite_ro(db_path)?;
    if !table_exists(&conn, "sessions") {
        anyhow::bail!("unsupported Hermes schema: missing sessions table");
    }

    // Column names have shifted across Hermes versions; probe rather than assume so a
    // rename degrades one field instead of the whole source.
    let has = |c: &str| column_exists(&conn, "sessions", c);
    let col = |c: &str, fallback: &str| {
        if has(c) {
            c.to_string()
        } else {
            fallback.to_string()
        }
    };

    let sql = format!(
        "SELECT id,
                {source_col}, {model_col}, {started}, {input}, {output},
                {cread}, {cwrite}, {reasoning}, {actual}, {estimated}, {provider}
         FROM sessions",
        source_col = if has("source") { "source" } else { "''" },
        model_col = if has("model") { "model" } else { "''" },
        started = col("started_at", "0"),
        input = col("input_tokens", "0"),
        output = col("output_tokens", "0"),
        cread = col("cache_read_tokens", "0"),
        cwrite = col("cache_write_tokens", "0"),
        reasoning = col("reasoning_tokens", "0"),
        actual = if has("actual_cost_usd") {
            "actual_cost_usd"
        } else {
            "NULL"
        },
        estimated = if has("estimated_cost_usd") {
            "estimated_cost_usd"
        } else {
            "NULL"
        },
        provider = if has("billing_provider") {
            "billing_provider"
        } else {
            "NULL"
        },
    );

    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, Option<String>>(1)?,
            r.get::<_, Option<String>>(2)?,
            r.get::<_, Option<f64>>(3)?,
            r.get::<_, i64>(4)?,
            r.get::<_, i64>(5)?,
            r.get::<_, i64>(6)?,
            r.get::<_, i64>(7)?,
            r.get::<_, i64>(8)?,
            r.get::<_, Option<f64>>(9)?,
            r.get::<_, Option<f64>>(10)?,
            r.get::<_, Option<String>>(11)?,
        ))
    })?;

    let mut report = ScanReport::default();
    for row in rows {
        let (
            id,
            src,
            model,
            started,
            input,
            output,
            cread,
            cwrite,
            reasoning,
            actual,
            estimated,
            provider,
        ) = row?;
        let mut e = UsageEvent::new(source::HERMES, surface::CLI, &ctx.instance, id.clone());
        e.session_id = id;
        e.project = src.and_then(|s| project_label(&s));
        e.model = model.unwrap_or_else(|| "unknown".into());
        e.input_tokens = input;
        e.output_tokens = output;
        e.cache_read_tokens = cread;
        e.cache_write_tokens = cwrite;
        e.reasoning_tokens = reasoning;
        if e.is_empty() {
            continue;
        }
        // Real billed amount beats an estimate, which beats computing from the price table.
        e.cost_usd = actual
            .filter(|c| *c > 0.0)
            .or_else(|| estimated.filter(|c| *c > 0.0));
        e.provider = provider;
        // `started_at` is REAL epoch seconds.
        e.timestamp = started
            .map(super::normalize_epoch)
            .unwrap_or_else(crate::store::now_ms);
        report.events.push(e);
    }
    Ok(report)
}
