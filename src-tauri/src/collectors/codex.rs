//! Codex (CLI + Desktop).
//!
//! On Windows the desktop app and the CLI share `%USERPROFILE%\.codex`, so one parser
//! covers both. Rollout files record `token_count` events carrying a **running session
//! total**; the per-call amount is the difference between consecutive totals.

use std::path::PathBuf;

use anyhow::Result;
use rayon::prelude::*;

use super::*;
use crate::model::{source, surface, UsageEvent};

pub struct CodexCollector;

/// Running per-file state carried across scan passes in `scan_state.extra`.
#[derive(Debug, Default, serde::Serialize, serde::Deserialize)]
struct CodexState {
    offset: i64,
    line_no: i64,
    /// Previous cumulative totals, for differencing.
    #[serde(default)]
    prev: CumulativeTokens,
    #[serde(default)]
    model: String,
    #[serde(default)]
    provider: String,
    #[serde(default)]
    session_id: String,
    #[serde(default)]
    project: Option<String>,
}

#[derive(Debug, Default, Clone, Copy, serde::Serialize, serde::Deserialize)]
struct CumulativeTokens {
    input: i64,
    cached_input: i64,
    cache_write: i64,
    output: i64,
    reasoning: i64,
}

impl CumulativeTokens {
    fn from_json(v: &serde_json::Value) -> Self {
        let n = |k: &str| v.get(k).and_then(|x| x.as_i64()).unwrap_or(0);
        Self {
            input: n("input_tokens"),
            cached_input: n("cached_input_tokens"),
            cache_write: n("cache_write_input_tokens"),
            output: n("output_tokens"),
            reasoning: n("reasoning_output_tokens"),
        }
    }

    fn sum(&self) -> i64 {
        self.input + self.output + self.cache_write
    }

    fn delta(&self, prev: &Self) -> Self {
        Self {
            input: (self.input - prev.input).max(0),
            cached_input: (self.cached_input - prev.cached_input).max(0),
            cache_write: (self.cache_write - prev.cache_write).max(0),
            output: (self.output - prev.output).max(0),
            reasoning: (self.reasoning - prev.reasoning).max(0),
        }
    }

    fn is_zero(&self) -> bool {
        self.input == 0 && self.output == 0 && self.cached_input == 0 && self.cache_write == 0
    }
}

impl CodexCollector {
    fn home(settings: &AppSettings) -> PathBuf {
        resolve_root(settings, source::CODEX, Some("CODEX_HOME"), home_dir().join(".codex"))
    }

    fn roots(settings: &AppSettings) -> Vec<PathBuf> {
        let home = Self::home(settings);
        [home.join("sessions"), home.join("archived_sessions")]
            .into_iter()
            .filter(|p| p.is_dir())
            .collect()
    }
}

impl Collector for CodexCollector {
    fn id(&self) -> &'static str {
        source::CODEX
    }

    fn label(&self) -> &'static str {
        "Codex"
    }

    fn detect(&self, settings: &AppSettings) -> Vec<PathBuf> {
        Self::roots(settings)
    }

    fn scan(&self, ctx: &ScanCtx) -> Result<ScanReport> {
        let roots = Self::roots(ctx.settings);
        if roots.is_empty() {
            return Ok(ScanReport::default());
        }
        let files: Vec<PathBuf> = roots
            .iter()
            .flat_map(|r| find_files(r, |p| has_ext(p, "jsonl")))
            .collect();

        let results: Vec<(PathBuf, CodexState, Vec<UsageEvent>, i64)> = files
            .par_iter()
            .filter_map(|path| parse_file(ctx, path))
            .collect();

        let mut report = ScanReport {
            files_seen: files.len() as i64,
            detected_paths: roots.iter().map(|p| p.to_string_lossy().to_string()).collect(),
            ..Default::default()
        };
        for (path, state, events, skipped) in results {
            report.events.extend(events);
            report.skipped += skipped;
            let _ = ctx.store.set_scan_state(
                source::CODEX,
                &ctx.instance,
                &path.to_string_lossy(),
                &crate::model::ScanState {
                    offset: state.offset,
                    mtime_ms: mtime_ms(path.as_path()),
                    extra: serde_json::to_string(&state).ok(),
                },
            );
        }
        report.events = finalize(report.events, ctx.pricing);
        Ok(report)
    }
}

fn parse_file(ctx: &ScanCtx, path: &std::path::Path) -> Option<(PathBuf, CodexState, Vec<UsageEvent>, i64)> {
    let key = path.to_string_lossy().to_string();
    let stored = ctx.store.get_scan_state(source::CODEX, &ctx.instance, &key);

    let size = file_size(path);
    let mut state: CodexState = stored
        .as_ref()
        .and_then(|s| s.extra.as_deref())
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default();
    // Truncation or rotation: start over so the cumulative baseline is not stale.
    if size < state.offset {
        state = CodexState::default();
    }
    if state.offset >= size {
        return None;
    }

    let chunk = read_lines_from(path, state.offset, state.line_no).ok()?;
    if chunk.lines.is_empty() {
        return None;
    }

    let stem = file_stem(path);
    let mut events = Vec::new();
    let mut skipped = 0i64;

    for (line_no, line) in &chunk.lines {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            skipped += 1;
            continue;
        };
        let line_type = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
        let payload = v.get("payload");

        match line_type {
            "session_meta" => {
                if let Some(p) = payload {
                    if let Some(s) = p.get("session_id").or_else(|| p.get("id")).and_then(|x| x.as_str()) {
                        state.session_id = s.to_string();
                    }
                    if let Some(s) = p.get("model_provider").and_then(|x| x.as_str()) {
                        state.provider = s.to_string();
                    }
                    if let Some(c) = p.get("cwd").and_then(|x| x.as_str()) {
                        state.project = project_label(c);
                    }
                }
            }
            // The model can change mid-session; both of these announce the new one.
            "turn_context" => {
                if let Some(m) = payload.and_then(|p| p.get("model")).and_then(|x| x.as_str()) {
                    state.model = m.to_string();
                }
            }
            "event_msg" => {
                let ptype = payload.and_then(|p| p.get("type")).and_then(|x| x.as_str()).unwrap_or("");
                match ptype {
                    "thread_settings_applied" => {
                        if let Some(ts) = payload.and_then(|p| p.get("thread_settings")) {
                            if let Some(m) = ts.get("model").and_then(|x| x.as_str()) {
                                state.model = m.to_string();
                            }
                            if let Some(p) = ts.get("model_provider_id").and_then(|x| x.as_str()) {
                                state.provider = p.to_string();
                            }
                            if let Some(c) = ts.get("cwd").and_then(|x| x.as_str()) {
                                state.project = project_label(c);
                            }
                        }
                    }
                    "token_count" => {
                        let Some(info) = payload.and_then(|p| p.get("info")) else {
                            continue;
                        };
                        // Prefer differencing the cumulative counter: it is immune to
                        // repeated snapshots of the same turn. `last_token_usage` is the
                        // fallback for builds that omit the running total.
                        let delta = match info.get("total_token_usage") {
                            Some(total) => {
                                let cum = CumulativeTokens::from_json(total);
                                // A smaller total means the session was rolled back or
                                // compacted; re-baseline rather than emit a negative.
                                let d = if cum.sum() < state.prev.sum() {
                                    state.prev = cum;
                                    continue;
                                } else {
                                    cum.delta(&state.prev)
                                };
                                state.prev = cum;
                                d
                            }
                            None => match info.get("last_token_usage") {
                                Some(last) => CumulativeTokens::from_json(last),
                                None => continue,
                            },
                        };
                        if delta.is_zero() {
                            continue;
                        }

                        let mut e = UsageEvent::new(
                            source::CODEX,
                            surface::CLI,
                            &ctx.instance,
                            format!("{stem}:{line_no}"),
                        );
                        e.session_id = if state.session_id.is_empty() {
                            stem.clone()
                        } else {
                            state.session_id.clone()
                        };
                        e.project = state.project.clone();
                        e.model = if state.model.is_empty() {
                            "unknown".into()
                        } else {
                            state.model.clone()
                        };
                        e.provider = Some(if state.provider.is_empty() {
                            "openai".into()
                        } else {
                            state.provider.clone()
                        });
                        e.timestamp = v
                            .get("timestamp")
                            .and_then(parse_timestamp)
                            .unwrap_or_else(crate::store::now_ms);
                        // `cached_input_tokens` is a subset of `input_tokens`, so the
                        // uncached remainder is what gets billed at the input rate.
                        e.input_tokens = (delta.input - delta.cached_input).max(0);
                        e.cache_read_tokens = delta.cached_input;
                        e.cache_write_tokens = delta.cache_write;
                        e.output_tokens = delta.output;
                        e.reasoning_tokens = delta.reasoning;
                        events.push(e);
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }

    state.offset = chunk.new_offset;
    state.line_no = chunk.new_line_no;
    Some((path.to_path_buf(), state, events, skipped))
}

/// Same incremental semantics as [`read_new_lines`], but the watermark lives inside the
/// collector's own JSON state blob rather than the generic `offset` column.
fn read_lines_from(path: &std::path::Path, offset: i64, line_no: i64) -> Result<JsonlChunk> {
    use std::io::{Read, Seek, SeekFrom};

    let size = file_size(path);
    let mtime = mtime_ms(path);
    let mut f = std::fs::File::open(path)?;
    f.seek(SeekFrom::Start(offset as u64))?;
    let mut buf = Vec::with_capacity((size - offset).clamp(0, 64 * 1024 * 1024) as usize);
    f.take((size - offset) as u64).read_to_end(&mut buf)?;

    let Some(last) = buf.iter().rposition(|b| *b == b'\n').map(|i| i + 1) else {
        return Ok(JsonlChunk {
            lines: Vec::new(),
            new_offset: offset,
            new_line_no: line_no,
            mtime_ms: mtime,
        });
    };

    let mut lines = Vec::new();
    let mut n = line_no;
    for raw in String::from_utf8_lossy(&buf[..last]).lines() {
        n += 1;
        let t = raw.trim();
        if !t.is_empty() {
            lines.push((n, t.to_string()));
        }
    }
    Ok(JsonlChunk {
        lines,
        new_offset: offset + last as i64,
        new_line_no: n,
        mtime_ms: mtime,
    })
}
