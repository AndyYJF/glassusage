//! Claude Code (CLI + Desktop).
//!
//! Both surfaces run the same engine and write the same transcripts under
//! `~/.claude/projects/<cwd-slug>/<session>.jsonl`, so one parser covers both. The
//! Desktop app additionally writes session metadata containing a `cliSessionId`; that is
//! used only to *label* a session as desktop, never to count it a second time.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use anyhow::Result;
use rayon::prelude::*;

use super::*;
use crate::model::{source, surface, UsageEvent};

pub struct ClaudeCollector;

impl ClaudeCollector {
    fn config_root(settings: &AppSettings) -> PathBuf {
        resolve_root(
            settings,
            source::CLAUDE,
            Some("CLAUDE_CONFIG_DIR"),
            home_dir().join(".claude"),
        )
    }

    /// Transcript directories. `transcripts/` is a legacy sibling of `projects/` that
    /// some builds still write to.
    fn transcript_roots(settings: &AppSettings) -> Vec<PathBuf> {
        let base = Self::config_root(settings);
        [base.join("projects"), base.join("transcripts")]
            .into_iter()
            .filter(|p| p.is_dir())
            .collect()
    }

    /// Desktop session-metadata directories, including the MSIX-redirected variant used
    /// by the Microsoft Store build.
    fn desktop_meta_roots() -> Vec<PathBuf> {
        let mut roots = Vec::new();
        if let Some(appdata) = dirs::config_dir() {
            roots.push(appdata.join("Claude").join("claude-code-sessions"));
        }
        if let Some(local) = dirs::data_local_dir() {
            let packages = local.join("Packages");
            if let Ok(entries) = std::fs::read_dir(&packages) {
                for e in entries.filter_map(|e| e.ok()) {
                    let name = e.file_name().to_string_lossy().to_string();
                    if name.starts_with("Claude_") {
                        roots.push(
                            e.path()
                                .join("LocalCache")
                                .join("Roaming")
                                .join("Claude")
                                .join("claude-code-sessions"),
                        );
                    }
                }
            }
        }
        roots.into_iter().filter(|p| p.is_dir()).collect()
    }

    /// Session ids that the Desktop app claims, so those transcripts get the desktop badge.
    fn desktop_session_ids() -> HashSet<String> {
        let mut ids = HashSet::new();
        for root in Self::desktop_meta_roots() {
            for file in find_files(&root, |p| has_ext(p, "json")) {
                let Ok(text) = std::fs::read_to_string(&file) else {
                    continue;
                };
                let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
                    continue;
                };
                collect_cli_session_ids(&v, &mut ids);
            }
        }
        ids
    }
}

fn collect_cli_session_ids(v: &serde_json::Value, out: &mut HashSet<String>) {
    match v {
        serde_json::Value::Object(map) => {
            for (k, val) in map {
                if k == "cliSessionId" {
                    if let Some(s) = val.as_str() {
                        out.insert(s.to_string());
                    }
                } else {
                    collect_cli_session_ids(val, out);
                }
            }
        }
        serde_json::Value::Array(items) => {
            items.iter().for_each(|i| collect_cli_session_ids(i, out))
        }
        _ => {}
    }
}

impl Collector for ClaudeCollector {
    fn id(&self) -> &'static str {
        source::CLAUDE
    }

    fn label(&self) -> &'static str {
        "Claude Code"
    }

    fn detect(&self, settings: &AppSettings) -> Vec<PathBuf> {
        let mut roots = Self::transcript_roots(settings);
        roots.extend(Self::desktop_meta_roots());
        roots
    }

    fn watch_paths(&self, settings: &AppSettings) -> Vec<PathBuf> {
        Self::transcript_roots(settings)
    }

    /// A streamed assistant message is written as several lines that share a message id;
    /// later lines carry the final, larger token counts. Upsert lets a message that
    /// straddles two scan passes settle on its final value instead of sticking at the
    /// first partial reading.
    fn write_mode(&self) -> WriteMode {
        WriteMode::Upsert
    }

    fn scan(&self, ctx: &ScanCtx) -> Result<ScanReport> {
        let roots = Self::transcript_roots(ctx.settings);
        if roots.is_empty() {
            return Ok(ScanReport::default());
        }
        let desktop_ids = Self::desktop_session_ids();

        let files: Vec<PathBuf> = roots
            .iter()
            .flat_map(|r| find_files(r, |p| has_ext(p, "jsonl")))
            .collect();

        // Cold start over a large ~/.claude tree is I/O bound across many small files,
        // so files are parsed in parallel and merged afterwards.
        let per_file: Vec<(PathBuf, JsonlChunk, Vec<UsageEvent>, i64)> = files
            .par_iter()
            .filter_map(|path| {
                let chunk = read_new_lines(ctx.store, source::CLAUDE, &ctx.instance, path).ok()?;
                if chunk.lines.is_empty() {
                    return None;
                }
                let (events, skipped) = parse_lines(&chunk, path, &desktop_ids, &ctx.instance);
                Some((path.clone(), chunk, events, skipped))
            })
            .collect();

        let mut report = ScanReport {
            files_seen: files.len() as i64,
            detected_paths: roots
                .iter()
                .map(|p| p.to_string_lossy().to_string())
                .collect(),
            ..Default::default()
        };

        for (path, chunk, events, skipped) in per_file {
            report.events.extend(events);
            report.skipped += skipped;
            report.states.push(pending_scan_state(
                source::CLAUDE,
                &ctx.instance,
                &path,
                &chunk,
            ));
        }

        report.events = finalize(report.events, ctx.pricing);
        Ok(report)
    }
}

/// Parse one chunk, collapsing streamed duplicates.
fn parse_lines(
    chunk: &JsonlChunk,
    path: &std::path::Path,
    desktop_ids: &HashSet<String>,
    instance: &str,
) -> (Vec<UsageEvent>, i64) {
    let stem = file_stem(path);
    // Last entry per dedup key wins: output_tokens grows monotonically across the lines
    // of one streamed message, so the final line holds the true value.
    let mut by_key: HashMap<String, UsageEvent> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    let mut skipped = 0i64;

    for (_line_no, line) in &chunk.lines {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            skipped += 1;
            continue;
        };
        if v.get("type").and_then(|t| t.as_str()) != Some("assistant") {
            continue;
        }
        let Some(message) = v.get("message") else {
            continue;
        };
        let Some(usage) = message.get("usage") else {
            continue;
        };

        let num = |k: &str| usage.get(k).and_then(|x| x.as_i64()).unwrap_or(0);
        let input = num("input_tokens");
        let output = num("output_tokens");
        let cache_write = num("cache_creation_input_tokens");
        let cache_read = num("cache_read_input_tokens");
        if input + output + cache_write + cache_read == 0 {
            continue;
        }

        // `requestId` is present in some builds and absent in others; the message id
        // alone is sufficient to collapse the lines of one streamed response.
        let message_id = message
            .get("id")
            .and_then(|x| x.as_str())
            .unwrap_or_else(|| v.get("uuid").and_then(|x| x.as_str()).unwrap_or(""));
        let request_id = v
            .get("requestId")
            .or_else(|| v.get("request_id"))
            .and_then(|x| x.as_str())
            .unwrap_or("");
        if message_id.is_empty() && request_id.is_empty() {
            skipped += 1;
            continue;
        }
        let dedup_key = format!("{stem}:{message_id}:{request_id}");

        let session_id = v
            .get("sessionId")
            .or_else(|| v.get("session_id"))
            .and_then(|x| x.as_str())
            .unwrap_or(&stem)
            .to_string();

        let surface_label = if desktop_ids.contains(&session_id) {
            surface::DESKTOP
        } else {
            surface::CLI
        };

        let mut e = UsageEvent::new(source::CLAUDE, surface_label, instance, dedup_key.clone());
        e.session_id = session_id;
        e.project = v
            .get("cwd")
            .and_then(|x| x.as_str())
            .and_then(project_label);
        e.model = message
            .get("model")
            .and_then(|x| x.as_str())
            .unwrap_or("unknown")
            .to_string();
        e.provider = Some("anthropic".into());
        e.timestamp = v
            .get("timestamp")
            .and_then(parse_timestamp)
            .unwrap_or_else(crate::store::now_ms);
        e.input_tokens = input;
        e.output_tokens = output;
        e.cache_read_tokens = cache_read;
        e.cache_write_tokens = cache_write;

        if by_key.insert(dedup_key.clone(), e).is_none() {
            order.push(dedup_key);
        }
    }

    let events = order
        .into_iter()
        .filter_map(|k| by_key.remove(&k))
        .collect();
    (events, skipped)
}
