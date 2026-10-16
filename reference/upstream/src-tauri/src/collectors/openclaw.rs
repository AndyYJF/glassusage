//! OpenClaw.
//!
//! Each agent keeps an append-only transcript in its own SQLite database; older releases
//! (and the `.clawdbot` / `.moltbot` legacy roots) wrote the same records as JSONL. Both
//! share one row parser, and the JSONL archives are imported only once.

use std::path::PathBuf;

use anyhow::Result;
use rusqlite::params;

use super::*;
use crate::model::{source, surface, UsageEvent};

pub struct OpenClawCollector;

impl OpenClawCollector {
    fn roots(settings: &AppSettings) -> Vec<PathBuf> {
        if let Some(custom) = settings.custom_path(source::OPENCLAW) {
            return vec![custom];
        }
        let home = home_dir();
        [".openclaw", ".clawdbot", ".moltbot"]
            .iter()
            .map(|d| home.join(d))
            .filter(|p| p.is_dir())
            .collect()
    }

    /// `<root>/agents/<agentId>/agent/*.sqlite`
    pub fn databases_under(root: &std::path::Path) -> Vec<PathBuf> {
        let agents = root.join("agents");
        let mut out = Vec::new();
        if let Ok(entries) = std::fs::read_dir(&agents) {
            for e in entries.filter_map(|e| e.ok()) {
                let dir = e.path().join("agent");
                if let Ok(files) = std::fs::read_dir(&dir) {
                    for f in files.filter_map(|f| f.ok()) {
                        let p = f.path();
                        if has_ext(&p, "sqlite") || has_ext(&p, "db") {
                            out.push(p);
                        }
                    }
                }
            }
        }
        if out.is_empty() {
            out = find_files(root, |p| has_ext(p, "sqlite"));
        }
        out
    }

    fn archives_under(root: &std::path::Path) -> Vec<PathBuf> {
        find_files(&root.join("agents"), |p| has_ext(p, "jsonl"))
    }
}

impl Collector for OpenClawCollector {
    fn id(&self) -> &'static str {
        source::OPENCLAW
    }

    fn label(&self) -> &'static str {
        "OpenClaw"
    }

    fn detect(&self, settings: &AppSettings) -> Vec<PathBuf> {
        Self::roots(settings)
            .iter()
            .flat_map(|r| Self::databases_under(r))
            .collect()
    }

    fn watch_paths(&self, settings: &AppSettings) -> Vec<PathBuf> {
        Self::roots(settings)
    }

    fn scan(&self, ctx: &ScanCtx) -> Result<ScanReport> {
        let roots = match &ctx.root_override {
            Some(root) => vec![root.clone()],
            None => Self::roots(ctx.settings),
        };
        let mut report = ScanReport::default();

        for root in &roots {
            report
                .detected_paths
                .push(root.to_string_lossy().to_string());

            for db in Self::databases_under(root) {
                report.files_seen += 1;
                match scan_db(ctx, &db) {
                    Ok(r) => report.merge(r),
                    Err(e) => {
                        report.skipped += 1;
                        tracing::warn!("openclaw: {} -> {e}", db.display());
                    }
                }
            }

            // Session / archive JSONL. Track each file by mtime+size so new remote
            // sessions are picked up on later polls (events still dedupe on insert).
            for jsonl in Self::archives_under(root) {
                report.files_seen += 1;
                let key = format!("jsonl:{}", jsonl.to_string_lossy());
                let mtime = mtime_ms(&jsonl);
                let size = std::fs::metadata(&jsonl)
                    .map(|m| m.len() as i64)
                    .unwrap_or(0);
                if let Some(prev) = ctx
                    .store
                    .get_scan_state(source::OPENCLAW, &ctx.instance, &key)
                {
                    if prev.mtime_ms == mtime && prev.offset == size {
                        continue;
                    }
                }

                let Ok(text) = std::fs::read_to_string(&jsonl) else {
                    report.skipped += 1;
                    continue;
                };
                let mut session_project = None;
                for line in text.lines() {
                    match parse_entry(line, &ctx.instance, &mut session_project) {
                        ParseOutcome::Event(e) => report.events.push(*e),
                        ParseOutcome::Skip => {}
                        ParseOutcome::Bad => report.skipped += 1,
                    }
                }
                report.states.push(crate::model::PendingScanState {
                    source: source::OPENCLAW.to_string(),
                    instance: ctx.instance.clone(),
                    key,
                    state: crate::model::ScanState {
                        offset: size,
                        mtime_ms: mtime,
                        extra: Some("jsonl".into()),
                    },
                });
            }
        }

        report.events = finalize(report.events, ctx.pricing);
        Ok(report)
    }
}

fn scan_db(ctx: &ScanCtx, db_path: &std::path::Path) -> Result<ScanReport> {
    let conn = open_sqlite_ro(db_path)?;

    // Table and column naming has moved around across releases, so the transcript table
    // is discovered rather than hard-coded.
    let Some((table, id_col, data_col, order_col)) = find_transcript_table(&conn) else {
        return Ok(ScanReport::default());
    };

    let key = format!("sqlite:{}", db_path.to_string_lossy());
    let state = ctx
        .store
        .get_scan_state(source::OPENCLAW, &ctx.instance, &key)
        .unwrap_or_default();
    let watermark = state.offset;
    let mut high_water = watermark;

    let sql = format!(
        "SELECT \"{id_col}\", \"{data_col}\", \"{order_col}\" FROM \"{table}\"
         WHERE \"{order_col}\" >= ?1 ORDER BY \"{order_col}\""
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params![watermark], |r| {
        Ok((
            r.get::<_, Option<String>>(0)?.unwrap_or_default(),
            r.get::<_, Option<String>>(1)?.unwrap_or_default(),
            r.get::<_, i64>(2)?,
        ))
    })?;

    let mut report = ScanReport::default();
    let mut project = None;
    for row in rows {
        let (id, data, seq) = row?;
        high_water = high_water.max(seq);
        match parse_entry(&data, &ctx.instance, &mut project) {
            ParseOutcome::Event(e) => {
                let mut e = *e;
                if !id.is_empty() {
                    e.dedup_key = id;
                }
                report.events.push(e);
            }
            ParseOutcome::Skip => {}
            ParseOutcome::Bad => report.skipped += 1,
        }
    }

    if high_water > watermark {
        report.states.push(crate::model::PendingScanState {
            source: source::OPENCLAW.to_string(),
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

/// Locate `(table, id column, JSON column, monotonic ordering column)`.
fn find_transcript_table(conn: &rusqlite::Connection) -> Option<(String, String, String, String)> {
    let mut stmt = conn
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
        .ok()?;
    let tables: Vec<String> = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .ok()?
        .filter_map(|r| r.ok())
        .collect();

    for candidate in [
        "transcript",
        "entries",
        "messages",
        "transcript_entries",
        "events",
    ] {
        if let Some(t) = tables.iter().find(|t| t.eq_ignore_ascii_case(candidate)) {
            let data = ["data", "json", "payload", "content", "body"]
                .iter()
                .find(|c| column_exists(conn, t, c))?
                .to_string();
            let id = ["id", "entry_id", "uuid", "rowid"]
                .iter()
                .find(|c| column_exists(conn, t, c))
                .map(|s| s.to_string())
                .unwrap_or_else(|| "rowid".into());
            let order = ["seq", "rowid", "created_at", "timestamp", "ts"]
                .iter()
                .find(|c| column_exists(conn, t, c))
                .map(|s| s.to_string())
                .unwrap_or_else(|| "rowid".into());
            return Some((t.clone(), id, data, order));
        }
    }
    None
}

enum ParseOutcome {
    Event(Box<UsageEvent>),
    Skip,
    Bad,
}

/// One transcript row. Supports:
/// - legacy `{ "type":"message", "message":{ "role":"assistant", "usage":{…} } }`
/// - current OpenClaw trajectory `{ "type":"model.completed", "data":{ "usage"| "promptCache.lastCallUsage" } }`
fn parse_entry(line: &str, instance: &str, project: &mut Option<String>) -> ParseOutcome {
    let line = line.trim();
    if line.is_empty() {
        return ParseOutcome::Skip;
    }
    let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
        return ParseOutcome::Bad;
    };

    // Current OpenClaw session traces (`.trajectory.jsonl`).
    if v.get("traceSchema")
        .and_then(|x| x.as_str())
        .is_some_and(|s| s.starts_with("openclaw"))
        || v.get("type")
            .and_then(|x| x.as_str())
            .is_some_and(|t| t.contains('.'))
    {
        return parse_trajectory(&v, instance, project);
    }

    let entry_type = v.get("type").and_then(|x| x.as_str()).unwrap_or("");
    if entry_type == "session" {
        if let Some(cwd) = v.get("cwd").and_then(|x| x.as_str()) {
            *project = project_label(cwd);
        }
        return ParseOutcome::Skip;
    }
    if entry_type != "message" {
        return ParseOutcome::Skip;
    }
    let Some(message) = v.get("message") else {
        return ParseOutcome::Skip;
    };
    if message.get("role").and_then(|x| x.as_str()) != Some("assistant") {
        return ParseOutcome::Skip;
    }
    let Some(usage) = message.get("usage").or_else(|| v.get("usage")) else {
        return ParseOutcome::Skip;
    };

    let n = |k: &str| usage.get(k).and_then(|x| x.as_i64()).unwrap_or(0);
    let mut e = UsageEvent::new(
        source::OPENCLAW,
        surface::CLI,
        instance,
        v.get("id")
            .and_then(|x| x.as_str())
            .unwrap_or_default()
            .to_string(),
    );
    e.input_tokens = n("inputTokens");
    e.output_tokens = n("outputTokens");
    e.cache_read_tokens = n("cacheReadTokens");
    e.cache_write_tokens = n("cacheWriteTokens");
    e.reasoning_tokens = n("reasoningTokens");
    if e.is_empty() {
        return ParseOutcome::Skip;
    }

    e.model = v
        .get("model")
        .or_else(|| message.get("model"))
        .and_then(|x| x.as_str())
        .unwrap_or("unknown")
        .to_string();
    e.provider = v
        .get("provider")
        .and_then(|x| x.as_str())
        .map(|s| s.to_string());
    e.session_id = v
        .get("sessionId")
        .or_else(|| v.get("session_id"))
        .and_then(|x| x.as_str())
        .unwrap_or_default()
        .to_string();
    e.project = project.clone();
    e.timestamp = v
        .get("timestamp")
        .or_else(|| v.get("time"))
        .or_else(|| v.get("createdAt"))
        .and_then(parse_timestamp)
        .unwrap_or_else(crate::store::now_ms);
    if e.dedup_key.is_empty() {
        e.dedup_key = sha_key(&[
            &e.session_id,
            &e.model,
            &e.timestamp.to_string(),
            &e.total_tokens().to_string(),
        ]);
    }
    ParseOutcome::Event(Box::new(e))
}

fn parse_trajectory(
    v: &serde_json::Value,
    instance: &str,
    project: &mut Option<String>,
) -> ParseOutcome {
    let entry_type = v.get("type").and_then(|x| x.as_str()).unwrap_or("");

    if entry_type == "session.started" {
        if let Some(cwd) = v
            .get("workspaceDir")
            .and_then(|x| x.as_str())
            .or_else(|| v.pointer("/data/workspaceDir").and_then(|x| x.as_str()))
        {
            *project = project_label(cwd);
        }
        return ParseOutcome::Skip;
    }

    if entry_type != "model.completed" {
        return ParseOutcome::Skip;
    }

    // Prefer the per-call delta; `data.usage` is a running total for the turn.
    let usage = v
        .pointer("/data/promptCache/lastCallUsage")
        .or_else(|| v.pointer("/data/usage"))
        .or_else(|| v.get("usage"));
    let Some(usage) = usage else {
        return ParseOutcome::Skip;
    };

    let n = |camel: &str, snake: &str| {
        usage
            .get(camel)
            .or_else(|| usage.get(snake))
            .and_then(|x| x.as_i64())
            .unwrap_or(0)
    };

    let mut e = UsageEvent::new(source::OPENCLAW, surface::CLI, instance, String::new());
    e.input_tokens = n("input", "inputTokens");
    e.output_tokens = n("output", "outputTokens");
    e.cache_read_tokens = n("cacheRead", "cacheReadTokens");
    e.cache_write_tokens = n("cacheWrite", "cacheWriteTokens");
    e.reasoning_tokens = n("reasoningTokens", "reasoning_tokens");
    if e.is_empty() {
        return ParseOutcome::Skip;
    }

    e.model = v
        .get("modelId")
        .or_else(|| v.get("model"))
        .and_then(|x| x.as_str())
        .unwrap_or("unknown")
        .to_string();
    e.provider = v
        .get("provider")
        .and_then(|x| x.as_str())
        .map(|s| s.to_string());
    e.session_id = v
        .get("sessionId")
        .or_else(|| v.get("traceId"))
        .and_then(|x| x.as_str())
        .unwrap_or_default()
        .to_string();
    if project.is_none() {
        if let Some(cwd) = v.get("workspaceDir").and_then(|x| x.as_str()) {
            *project = project_label(cwd);
        }
    }
    e.project = project.clone();
    e.timestamp = v
        .get("ts")
        .or_else(|| v.get("timestamp"))
        .and_then(parse_timestamp)
        .unwrap_or_else(crate::store::now_ms);

    let seq = v
        .get("seq")
        .and_then(|x| x.as_i64())
        .map(|n| n.to_string())
        .unwrap_or_default();
    e.dedup_key = if !e.session_id.is_empty() && !seq.is_empty() {
        format!("{}:{}", e.session_id, seq)
    } else {
        sha_key(&[
            &e.session_id,
            &e.model,
            &e.timestamp.to_string(),
            &e.total_tokens().to_string(),
        ])
    };

    ParseOutcome::Event(Box::new(e))
}
