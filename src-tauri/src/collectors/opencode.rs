//! OpenCode.
//!
//! v2+ keeps everything in `~/.local/share/opencode/opencode*.db`. The `message` table
//! is preferred over `session` because it yields a real time series; the per-session
//! rollup columns are only a fallback for databases without message rows.

use std::path::PathBuf;

use anyhow::Result;
use rusqlite::params;

use super::*;
use crate::model::{source, surface, UsageEvent};

pub struct OpenCodeCollector;

impl OpenCodeCollector {
    fn data_dirs(settings: &AppSettings) -> Vec<PathBuf> {
        if let Some(custom) = settings.custom_path(source::OPENCODE) {
            return vec![custom];
        }
        let mut dirs = Vec::new();
        if let Ok(v) = std::env::var("OPENCODE_DATA_DIR") {
            if !v.trim().is_empty() {
                dirs.push(PathBuf::from(v));
            }
        }
        if let Ok(v) = std::env::var("XDG_DATA_HOME") {
            if !v.trim().is_empty() {
                dirs.push(PathBuf::from(v).join("opencode"));
            }
        }
        dirs.push(home_dir().join(".local").join("share").join("opencode"));
        if let Some(local) = dirs::data_local_dir() {
            dirs.push(local.join("opencode"));
        }
        dirs.into_iter().filter(|p| p.is_dir()).collect()
    }

    /// All release channels ship their own database file next to each other.
    fn databases(settings: &AppSettings) -> Vec<PathBuf> {
        let mut out = Vec::new();
        for dir in Self::data_dirs(settings) {
            let Ok(entries) = std::fs::read_dir(&dir) else {
                continue;
            };
            for e in entries.filter_map(|e| e.ok()) {
                let name = e.file_name().to_string_lossy().to_string();
                if name.starts_with("opencode") && name.ends_with(".db") {
                    out.push(e.path());
                }
            }
        }
        out
    }
}

impl Collector for OpenCodeCollector {
    fn id(&self) -> &'static str {
        source::OPENCODE
    }

    fn label(&self) -> &'static str {
        "OpenCode"
    }

    fn write_mode(&self) -> WriteMode {
        WriteMode::Upsert
    }

    fn detect(&self, settings: &AppSettings) -> Vec<PathBuf> {
        Self::databases(settings)
    }

    fn watch_paths(&self, settings: &AppSettings) -> Vec<PathBuf> {
        Self::data_dirs(settings)
    }

    fn scan(&self, ctx: &ScanCtx) -> Result<ScanReport> {
        let dbs = match &ctx.root_override {
            Some(root) => find_files(root, |p| has_ext(p, "db")),
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

        for db_path in dbs {
            match scan_db(ctx, &db_path) {
                Ok(r) => report.merge(r),
                // A locked or mid-migration database should not fail the whole pass.
                Err(e) => {
                    report.skipped += 1;
                    tracing::warn!("opencode: {} -> {e}", db_path.display());
                }
            }
        }

        // Legacy on-disk message files, imported once.
        for dir in Self::data_dirs(ctx.settings) {
            let legacy = dir.join("storage").join("message");
            if legacy.is_dir() {
                if let Ok(r) = scan_legacy(ctx, &legacy) {
                    report.merge(r);
                }
            }
        }

        report.events = finalize(report.events, ctx.pricing);
        Ok(report)
    }
}

fn scan_db(ctx: &ScanCtx, db_path: &std::path::Path) -> Result<ScanReport> {
    let conn = open_sqlite_ro(db_path)?;
    let key = format!("sqlite:{}", db_path.to_string_lossy());
    let state = ctx
        .store
        .get_scan_state(source::OPENCODE, &ctx.instance, &key)
        .unwrap_or_default();
    let watermark = state.offset;

    let mut report = ScanReport::default();
    let mut high_water = watermark;

    if table_exists(&conn, "message") {
        // `session` supplies the project directory that message rows omit.
        let mut dirs = std::collections::HashMap::<String, String>::new();
        if table_exists(&conn, "session") {
            let mut stmt = conn.prepare("SELECT id, directory FROM session")?;
            let rows =
                stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
            dirs = rows.collect::<rusqlite::Result<_>>()?;
        }

        let mut stmt = conn.prepare(
            "SELECT id, session_id, time_created, time_updated, data
             FROM message WHERE time_updated >= ?1 ORDER BY time_updated",
        )?;
        let rows = stmt.query_map(params![watermark], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, String>(4)?,
            ))
        })?;

        for row in rows {
            let (id, session_id, created, updated, data) = row?;
            high_water = high_water.max(updated);

            let Ok(v) = serde_json::from_str::<serde_json::Value>(&data) else {
                report.skipped += 1;
                continue;
            };
            if v.get("role").and_then(|x| x.as_str()) != Some("assistant") {
                continue;
            }
            let Some(tokens) = v.get("tokens") else {
                continue;
            };
            let n = |path: &[&str]| -> i64 {
                let mut cur = tokens;
                for p in path {
                    match cur.get(p) {
                        Some(next) => cur = next,
                        None => return 0,
                    }
                }
                cur.as_i64().unwrap_or(0)
            };

            let mut e = UsageEvent::new(source::OPENCODE, surface::CLI, &ctx.instance, id.clone());
            e.session_id = session_id.clone();
            e.input_tokens = n(&["input"]);
            e.output_tokens = n(&["output"]);
            e.reasoning_tokens = n(&["reasoning"]);
            e.cache_read_tokens = n(&["cache", "read"]);
            e.cache_write_tokens = n(&["cache", "write"]);
            if e.is_empty() {
                continue;
            }

            e.model = v
                .get("model")
                .and_then(|m| m.get("modelID"))
                .or_else(|| v.get("modelID"))
                .and_then(|x| x.as_str())
                .unwrap_or("unknown")
                .to_string();
            e.provider = v
                .get("model")
                .and_then(|m| m.get("providerID"))
                .or_else(|| v.get("providerID"))
                .and_then(|x| x.as_str())
                .map(|s| s.to_string());
            e.project = v
                .get("path")
                .and_then(|p| p.get("cwd"))
                .and_then(|x| x.as_str())
                .map(|s| s.to_string())
                .or_else(|| dirs.get(&session_id).cloned())
                .and_then(|c| project_label(&c));
            e.timestamp = v
                .get("time")
                .and_then(|t| t.get("created"))
                .and_then(parse_timestamp)
                .unwrap_or(created);
            // `cost` is frequently 0 even for paid calls, so only a positive value is
            // trusted; otherwise the price table fills it in.
            e.cost_usd = v.get("cost").and_then(|x| x.as_f64()).filter(|c| *c > 0.0);
            report.events.push(e);
        }
    } else if table_exists(&conn, "session") {
        // No message table: fall back to session rollups (one event per session).
        let mut stmt = conn.prepare(
            "SELECT id, directory, model, cost, tokens_input, tokens_output, tokens_reasoning,
                    tokens_cache_read, tokens_cache_write, time_created, time_updated
             FROM session WHERE time_updated >= ?1",
        )?;
        let rows = stmt.query_map(params![watermark], |r| {
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
                r.get::<_, i64>(9)?,
                r.get::<_, i64>(10)?,
            ))
        })?;
        for row in rows {
            let (id, dir, model, cost, ti, to, tr, tcr, tcw, created, updated) = row?;
            high_water = high_water.max(updated);
            let mut e = UsageEvent::new(
                source::OPENCODE,
                surface::CLI,
                &ctx.instance,
                format!("session:{id}"),
            );
            e.session_id = id;
            e.project = dir.as_deref().and_then(project_label);
            e.model = model.unwrap_or_else(|| "unknown".into());
            e.input_tokens = ti;
            e.output_tokens = to;
            e.reasoning_tokens = tr;
            e.cache_read_tokens = tcr;
            e.cache_write_tokens = tcw;
            e.cost_usd = cost.filter(|c| *c > 0.0);
            e.timestamp = created;
            report.events.push(e);
        }
    } else {
        anyhow::bail!("unsupported OpenCode schema: missing message and session tables");
    }

    if high_water > watermark {
        report.states.push(crate::model::PendingScanState {
            source: source::OPENCODE.to_string(),
            instance: ctx.instance.clone(),
            key,
            state: crate::model::ScanState {
                offset: high_water,
                mtime_ms: mtime_ms(db_path),
                extra: None,
            },
        });
    }
    Ok(report)
}

/// Pre-v2 layout: one JSON file per message under `storage/message/<sessionID>/`.
fn scan_legacy(ctx: &ScanCtx, dir: &std::path::Path) -> Result<ScanReport> {
    let key = format!("legacy:{}", dir.to_string_lossy());
    if ctx
        .store
        .get_scan_state(source::OPENCODE, &ctx.instance, &key)
        .is_some()
    {
        return Ok(ScanReport::default());
    }
    let mut report = ScanReport::default();
    for file in find_files(dir, |p| has_ext(p, "json")) {
        let Ok(text) = std::fs::read_to_string(&file) else {
            continue;
        };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
            report.skipped += 1;
            continue;
        };
        if v.get("role").and_then(|x| x.as_str()) != Some("assistant") {
            continue;
        }
        let Some(tokens) = v.get("tokens") else {
            continue;
        };
        let n = |path: &[&str]| -> i64 {
            let mut cur = tokens;
            for p in path {
                match cur.get(p) {
                    Some(next) => cur = next,
                    None => return 0,
                }
            }
            cur.as_i64().unwrap_or(0)
        };
        let id = v
            .get("id")
            .and_then(|x| x.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| file_stem(&file));
        let mut e = UsageEvent::new(source::OPENCODE, surface::CLI, &ctx.instance, id.clone());
        e.session_id = v
            .get("sessionID")
            .and_then(|x| x.as_str())
            .unwrap_or_default()
            .to_string();
        e.input_tokens = n(&["input"]);
        e.output_tokens = n(&["output"]);
        e.reasoning_tokens = n(&["reasoning"]);
        e.cache_read_tokens = n(&["cache", "read"]);
        e.cache_write_tokens = n(&["cache", "write"]);
        if e.is_empty() {
            continue;
        }
        e.model = v
            .get("modelID")
            .and_then(|x| x.as_str())
            .unwrap_or("unknown")
            .to_string();
        e.provider = v
            .get("providerID")
            .and_then(|x| x.as_str())
            .map(|s| s.to_string());
        e.timestamp = v
            .get("time")
            .and_then(|t| t.get("created"))
            .and_then(parse_timestamp)
            .unwrap_or_else(crate::store::now_ms);
        report.events.push(e);
    }
    report.states.push(crate::model::PendingScanState {
        source: source::OPENCODE.to_string(),
        instance: ctx.instance.clone(),
        key,
        state: crate::model::ScanState {
            offset: 1,
            mtime_ms: crate::store::now_ms(),
            extra: Some("imported".into()),
        },
    });
    Ok(report)
}
