//! Antigravity (IDE + CLI).
//!
//! # IDE
//!
//! Each conversation is a SQLite database under `~/.gemini/antigravity/conversations/`
//! whose `gen_metadata.data` column holds a protobuf blob per model generation. There is
//! no published schema, so the field numbers below were recovered from the wire format
//! and cross-checked against real databases. The decisive evidence was the identity
//!
//! ```text
//! field 3 == field 9 + field 10
//! ```
//!
//! holding on every row examined, which identifies field 3 as total output split into
//! reasoning (9) and answer text (10). Field 5 cannot be a subset of field 2 because
//! rows exist where it is an order of magnitude larger, so the two are disjoint: fresh
//! input and cache reads.
//!
//! Layout, relative to the blob root:
//!
//! | path        | meaning                                    |
//! |-------------|--------------------------------------------|
//! | `1.4.1`     | model enum (1016 = gemini pro, 1026 = opus) |
//! | `1.4.2`     | uncached input tokens                       |
//! | `1.4.3`     | total output tokens                         |
//! | `1.4.5`     | cache read tokens                           |
//! | `1.4.9`     | reasoning tokens (subset of output)         |
//! | `1.4.10`    | answer text tokens (subset of output)       |
//! | `1.4.11`    | request id — the dedup key                  |
//! | `1.9.4`     | `Timestamp { seconds, nanos }`              |
//! | `1.19`      | model routing label, e.g. `gemini-pro-c`    |
//! | root `4`    | trajectory/conversation uuid                |
//!
//! Any row that fails these expectations is counted as skipped rather than guessed at,
//! so schema drift shows up in the UI as a warning instead of wrong numbers.
//!
//! # CLI
//!
//! `~/.gemini/antigravity-cli/conversations/*.db` stores plain columns, so it is read
//! directly with a tolerant column probe.

use std::path::PathBuf;

use anyhow::Result;
use rusqlite::params;

use super::protoscan;
use super::*;
use crate::model::{source, surface, UsageEvent};

pub struct AntigravityCollector;

impl AntigravityCollector {
    fn gemini_home(settings: &AppSettings) -> PathBuf {
        resolve_root(
            settings,
            source::ANTIGRAVITY,
            Some("GEMINI_CLI_HOME"),
            home_dir().join(".gemini"),
        )
    }

    fn ide_dirs(settings: &AppSettings) -> Vec<PathBuf> {
        let home = Self::gemini_home(settings);
        ["antigravity", "antigravity-ide"]
            .iter()
            .map(|d| home.join(d).join("conversations"))
            .filter(|p| p.is_dir())
            .collect()
    }

    fn cli_dirs(settings: &AppSettings) -> Vec<PathBuf> {
        let home = Self::gemini_home(settings);
        [home.join("antigravity-cli").join("conversations")]
            .into_iter()
            .filter(|p| p.is_dir())
            .collect()
    }
}

impl Collector for AntigravityCollector {
    fn id(&self) -> &'static str {
        source::ANTIGRAVITY
    }

    fn label(&self) -> &'static str {
        "Antigravity"
    }

    fn detect(&self, settings: &AppSettings) -> Vec<PathBuf> {
        let mut v = Self::cli_dirs(settings);
        v.extend(Self::ide_dirs(settings));
        v
    }

    /// CLI rows carry running per-conversation totals that keep growing, so a re-read
    /// must replace the stored value. IDE rows are immutable, where upsert is a no-op.
    fn write_mode(&self) -> WriteMode {
        WriteMode::Upsert
    }

    fn scan(&self, ctx: &ScanCtx) -> Result<ScanReport> {
        let mut report = ScanReport::default();

        for dir in Self::cli_dirs(ctx.settings) {
            report.detected_paths.push(dir.to_string_lossy().to_string());
            for db in find_files(&dir, |p| has_ext(p, "db")) {
                report.files_seen += 1;
                match scan_cli_db(ctx, &db) {
                    Ok(r) => report.merge(r),
                    Err(e) => {
                        report.skipped += 1;
                        tracing::warn!("antigravity cli: {} -> {e}", db.display());
                    }
                }
            }
        }

        if ctx.settings.antigravity_ide_enabled {
            for dir in Self::ide_dirs(ctx.settings) {
                report.detected_paths.push(dir.to_string_lossy().to_string());
                for db in find_files(&dir, |p| has_ext(p, "db")) {
                    report.files_seen += 1;
                    match scan_ide_db(ctx, &db) {
                        Ok(r) => report.merge(r),
                        Err(e) => {
                            report.skipped += 1;
                            tracing::warn!("antigravity ide: {} -> {e}", db.display());
                        }
                    }
                }
            }
        } else {
            for dir in Self::ide_dirs(ctx.settings) {
                report.detected_paths.push(format!("{} (disabled)", dir.to_string_lossy()));
            }
        }

        report.events = finalize(report.events, ctx.pricing);
        Ok(report)
    }
}

/// Decode `gen_metadata` blobs from one conversation database.
fn scan_ide_db(ctx: &ScanCtx, db_path: &std::path::Path) -> Result<ScanReport> {
    let key = format!("ide:{}", db_path.to_string_lossy());
    let state = ctx
        .store
        .get_scan_state(source::ANTIGRAVITY, &ctx.instance, &key)
        .unwrap_or_default();

    // `gen_metadata` is append-only and keyed by a dense `idx`, so the highest index
    // already read is a sufficient watermark. A shrinking table means the conversation
    // was rewritten, which re-reads from the start.
    let conn = open_sqlite_ro(db_path)?;
    if !table_exists(&conn, "gen_metadata") {
        return Ok(ScanReport::default());
    }
    let max_idx: i64 = conn
        .query_row("SELECT COALESCE(MAX(idx), -1) FROM gen_metadata", [], |r| r.get(0))
        .unwrap_or(-1);
    let watermark = if max_idx + 1 < state.offset { -1 } else { state.offset - 1 };
    if max_idx <= watermark {
        return Ok(ScanReport::default());
    }

    let conversation = file_stem(db_path);
    let mut stmt = conn.prepare("SELECT idx, data FROM gen_metadata WHERE idx > ?1 ORDER BY idx")?;
    let rows = stmt.query_map(params![watermark], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?))
    })?;

    let mut report = ScanReport::default();
    for row in rows.filter_map(|r| r.ok()) {
        let (idx, blob) = row;
        match decode_generation(&blob, &conversation, idx, &ctx.instance) {
            Some(e) => report.events.push(e),
            None => report.skipped += 1,
        }
    }

    let _ = ctx.store.set_scan_state(
        source::ANTIGRAVITY,
        &ctx.instance,
        &key,
        &crate::model::ScanState {
            offset: max_idx + 1,
            mtime_ms: mtime_ms(db_path),
            extra: None,
        },
    );
    Ok(report)
}

fn decode_generation(blob: &[u8], conversation: &str, idx: i64, instance: &str) -> Option<UsageEvent> {
    let root = protoscan::decode(blob)?;
    let outer = root.message(1)?;
    let usage = outer.message(4)?;

    let input = usage.varint(2);
    let output = usage.varint(3);
    let cache_read = usage.varint(5);
    let reasoning = usage.varint(9);
    let text = usage.varint(10);
    if input + output + cache_read == 0 {
        return None;
    }
    // Guard against reading a differently-shaped blob as usage: on this schema total
    // output always decomposes into reasoning plus answer text.
    if output != reasoning + text {
        return None;
    }

    let request_id = usage.string(11).filter(|s| !s.is_empty());
    let model = outer
        .string(19)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| format!("antigravity-model-{}", usage.varint(1)));

    let timestamp = outer
        .path(&[9, 4])
        .map(|t| t.varint(1) * 1000 + t.varint(2) / 1_000_000)
        .filter(|ts| *ts > 0)
        .unwrap_or_else(crate::store::now_ms);

    let dedup_key = match request_id {
        Some(id) => format!("ide:{id}"),
        None => format!("ide:{conversation}:{idx}"),
    };

    let mut e = UsageEvent::new(source::ANTIGRAVITY, surface::IDE, instance, dedup_key);
    e.session_id = root.string(4).unwrap_or_else(|| conversation.to_string());
    e.model = model;
    e.provider = Some("google".into());
    e.timestamp = timestamp;
    e.input_tokens = input;
    e.output_tokens = output;
    e.cache_read_tokens = cache_read;
    e.reasoning_tokens = reasoning;
    Some(e)
}

/// The CLI database uses ordinary columns; names are probed so a rename degrades one
/// field rather than the source.
fn scan_cli_db(ctx: &ScanCtx, db_path: &std::path::Path) -> Result<ScanReport> {
    let conn = open_sqlite_ro(db_path)?;

    let Some(table) = ["conversations", "messages", "generations", "turns", "usage"]
        .iter()
        .find(|t| table_exists(&conn, t))
        .map(|s| s.to_string())
    else {
        // Newer CLI builds reuse the IDE protobuf layout.
        return if table_exists(&conn, "gen_metadata") {
            scan_ide_db(ctx, db_path)
        } else {
            Ok(ScanReport::default())
        };
    };

    let pick = |candidates: &[&str]| -> Option<String> {
        candidates
            .iter()
            .find(|c| column_exists(&conn, &table, c))
            .map(|s| s.to_string())
    };
    let expr = |candidates: &[&str]| pick(candidates).unwrap_or_else(|| "0".to_string());

    let id_col = pick(&["id", "uuid", "conversation_id"]).unwrap_or_else(|| "rowid".into());
    let sql = format!(
        "SELECT \"{id}\", {input}, {output}, {cread}, {cwrite}, {reasoning}, {model}, {ts}
         FROM \"{table}\"",
        id = id_col,
        input = expr(&["input_tokens", "prompt_tokens", "tokens_input"]),
        output = expr(&["output_tokens", "completion_tokens", "tokens_output"]),
        cread = expr(&["cache_read_tokens", "cached_tokens", "tokens_cache_read"]),
        cwrite = expr(&["cache_write_tokens", "tokens_cache_write"]),
        reasoning = expr(&["reasoning_tokens", "thoughts_tokens"]),
        model = pick(&["model", "model_name", "model_id"]).unwrap_or_else(|| "''".into()),
        ts = pick(&["updated_at", "created_at", "timestamp", "time_created"]).unwrap_or_else(|| "0".into()),
    );

    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, Option<String>>(0)?.unwrap_or_default(),
            r.get::<_, i64>(1)?,
            r.get::<_, i64>(2)?,
            r.get::<_, i64>(3)?,
            r.get::<_, i64>(4)?,
            r.get::<_, i64>(5)?,
            r.get::<_, Option<String>>(6)?,
            r.get::<_, Option<f64>>(7)?,
        ))
    })?;

    let stem = file_stem(db_path);
    let mut report = ScanReport::default();
    for row in rows.filter_map(|r| r.ok()) {
        let (id, input, output, cread, cwrite, reasoning, model, ts) = row;
        let mut e = UsageEvent::new(
            source::ANTIGRAVITY,
            surface::CLI,
            &ctx.instance,
            format!("cli:{stem}:{id}"),
        );
        e.session_id = if id.is_empty() { stem.clone() } else { id };
        e.model = model.filter(|m| !m.is_empty()).unwrap_or_else(|| "unknown".into());
        e.provider = Some("google".into());
        e.input_tokens = input;
        e.output_tokens = output;
        e.cache_read_tokens = cread;
        e.cache_write_tokens = cwrite;
        e.reasoning_tokens = reasoning;
        if e.is_empty() {
            continue;
        }
        e.timestamp = ts.map(normalize_epoch).filter(|t| *t > 0).unwrap_or_else(crate::store::now_ms);
        report.events.push(e);
    }
    Ok(report)
}
