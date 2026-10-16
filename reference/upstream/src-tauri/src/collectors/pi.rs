//! Pi (`@earendil-works/pi-coding-agent`).
//!
//! Sessions are JSONL trees under `~/.pi/agent/sessions/<cwd-slug>/<timestamp>_<uuid>.jsonl`.
//! Assistant, compaction, branch-summary and tool-result rows can all carry a `usage`
//! object. Pi reports `reasoning` separately from `output` (unlike Claude/Codex), so
//! reasoning is folded into `output_tokens` to keep GlassUsage's "reasoning ⊆ output"
//! invariant and still count the tokens.

use std::path::{Path, PathBuf};

use anyhow::Result;
use rayon::prelude::*;

use super::*;
use crate::model::{source, surface, PendingScanState, ScanState, UsageEvent};

pub struct PiCollector;

#[derive(Debug, Default, Clone)]
struct FileMeta {
    session_id: String,
    project: Option<String>,
    model: String,
    provider: String,
}

/// Carried in `scan_state.extra` so incremental chunks still know the last
/// model / provider / session after the header has scrolled out of the window.
#[derive(Debug, Default, Clone, serde::Serialize, serde::Deserialize)]
struct PiFileState {
    line_no: i64,
    #[serde(default)]
    session_id: String,
    #[serde(default)]
    project: Option<String>,
    #[serde(default)]
    model: String,
    #[serde(default)]
    provider: String,
}

impl PiCollector {
    fn sessions_dir(settings: &AppSettings) -> PathBuf {
        if let Some(custom) = settings.custom_path(source::PI) {
            return custom;
        }
        if let Ok(v) = std::env::var("PI_CODING_AGENT_SESSION_DIR") {
            let trimmed = v.trim();
            if !trimmed.is_empty() {
                return PathBuf::from(trimmed);
            }
        }
        let agent_dir = std::env::var("PI_CODING_AGENT_DIR")
            .ok()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home_dir().join(".pi").join("agent"));
        agent_dir.join("sessions")
    }
}

impl Collector for PiCollector {
    fn id(&self) -> &'static str {
        source::PI
    }

    fn label(&self) -> &'static str {
        "Pi"
    }

    fn detect(&self, settings: &AppSettings) -> Vec<PathBuf> {
        let dir = Self::sessions_dir(settings);
        if dir.is_dir() {
            vec![dir]
        } else {
            Vec::new()
        }
    }

    fn watch_paths(&self, settings: &AppSettings) -> Vec<PathBuf> {
        self.detect(settings)
    }

    fn scan(&self, ctx: &ScanCtx) -> Result<ScanReport> {
        let root = match &ctx.root_override {
            Some(root) => root.clone(),
            None => Self::sessions_dir(ctx.settings),
        };
        if !root.exists() {
            return Ok(ScanReport::default());
        }

        let files: Vec<PathBuf> = find_files(&root, |p| has_ext(p, "jsonl"));
        let per_file: Vec<(PathBuf, JsonlChunk, FileMeta, Vec<UsageEvent>, i64)> = files
            .par_iter()
            .filter_map(|path| parse_file(ctx, path))
            .collect();

        let mut report = ScanReport {
            files_seen: files.len() as i64,
            detected_paths: if root.is_dir() {
                vec![root.to_string_lossy().to_string()]
            } else {
                Vec::new()
            },
            ..Default::default()
        };

        for (path, chunk, meta, events, skipped) in per_file {
            report.events.extend(events);
            report.skipped += skipped;
            report.states.push(PendingScanState {
                source: source::PI.to_string(),
                instance: ctx.instance.clone(),
                key: path.to_string_lossy().to_string(),
                state: ScanState {
                    offset: chunk.new_offset,
                    mtime_ms: chunk.mtime_ms,
                    extra: serde_json::to_string(&PiFileState {
                        line_no: chunk.new_line_no,
                        session_id: meta.session_id,
                        project: meta.project,
                        model: meta.model,
                        provider: meta.provider,
                    })
                    .ok(),
                },
            });
        }

        report.events = finalize(report.events, ctx.pricing);
        Ok(report)
    }
}

fn parse_file(
    ctx: &ScanCtx,
    path: &Path,
) -> Option<(PathBuf, JsonlChunk, FileMeta, Vec<UsageEvent>, i64)> {
    let key = path.to_string_lossy().to_string();
    let stored = ctx.store.get_scan_state(source::PI, &ctx.instance, &key);
    let size = file_size(path);
    let mut meta = match &stored {
        Some(s) if size < s.offset => FileMeta::default(),
        Some(s) => s
            .extra
            .as_deref()
            .map(file_meta_from_extra)
            .unwrap_or_default(),
        None => FileMeta::default(),
    };

    let chunk = read_new_lines(ctx.store, source::PI, &ctx.instance, path).ok()?;
    if chunk.lines.is_empty() {
        return None;
    }

    if meta.session_id.is_empty() {
        if let Some((id, project)) = peek_session_header(path) {
            meta.session_id = id;
            meta.project = project;
        } else if let Some(id) = session_id_from_filename(path) {
            meta.session_id = id;
        }
    }

    let fallback_session = if meta.session_id.is_empty() {
        file_stem(path)
    } else {
        meta.session_id.clone()
    };

    let mut events = Vec::new();
    let mut skipped = 0i64;

    for (_line_no, line) in &chunk.lines {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            skipped += 1;
            continue;
        };
        let typ = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
        match typ {
            "session" => {
                if let Some(id) = v.get("id").and_then(|x| x.as_str()) {
                    meta.session_id = id.to_string();
                }
                if let Some(cwd) = v.get("cwd").and_then(|x| x.as_str()) {
                    meta.project = project_label(cwd);
                }
            }
            "model_change" => {
                if let Some(m) = v.get("modelId").and_then(|x| x.as_str()) {
                    meta.model = m.to_string();
                }
                if let Some(p) = v.get("provider").and_then(|x| x.as_str()) {
                    meta.provider = p.to_string();
                }
            }
            "message" => {
                let Some(message) = v.get("message") else {
                    continue;
                };
                let role = message.get("role").and_then(|x| x.as_str()).unwrap_or("");
                if role == "assistant" {
                    if let Some(m) = message.get("model").and_then(|x| x.as_str()) {
                        meta.model = m.to_string();
                    }
                    if let Some(p) = message.get("provider").and_then(|x| x.as_str()) {
                        meta.provider = p.to_string();
                    }
                }
                let usage_src = match role {
                    "assistant" | "toolResult" => message,
                    _ => continue,
                };
                if let Some(e) =
                    event_from_usage(&v, usage_src, &ctx.instance, &meta, &fallback_session, role)
                {
                    events.push(e);
                }
            }
            "compaction" | "branch_summary" => {
                if let Some(e) =
                    event_from_usage(&v, &v, &ctx.instance, &meta, &fallback_session, typ)
                {
                    events.push(e);
                }
            }
            _ => {}
        }
    }

    Some((path.to_path_buf(), chunk, meta, events, skipped))
}

fn file_meta_from_extra(extra: &str) -> FileMeta {
    serde_json::from_str::<PiFileState>(extra)
        .map(|s| FileMeta {
            session_id: s.session_id,
            project: s.project,
            model: s.model,
            provider: s.provider,
        })
        .unwrap_or_default()
}

fn event_from_usage(
    entry: &serde_json::Value,
    usage_holder: &serde_json::Value,
    instance: &str,
    meta: &FileMeta,
    fallback_session: &str,
    kind: &str,
) -> Option<UsageEvent> {
    let usage = parsed_usage(usage_holder.get("usage")?)?;
    let entry_id = entry.get("id").and_then(|x| x.as_str()).unwrap_or("");
    if entry_id.is_empty() {
        return None;
    }
    let session_id = if meta.session_id.is_empty() {
        fallback_session.to_string()
    } else {
        meta.session_id.clone()
    };
    let dedup_key = format!("{session_id}:{entry_id}:{kind}");

    let mut e = UsageEvent::new(source::PI, surface::CLI, instance, dedup_key);
    e.session_id = session_id;
    e.project = meta.project.clone();
    e.model = usage_holder
        .get("model")
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .unwrap_or_else(|| {
            if meta.model.is_empty() {
                "unknown".into()
            } else {
                meta.model.clone()
            }
        });
    e.provider = usage_holder
        .get("provider")
        .and_then(|x| x.as_str())
        .map(|s| s.to_string())
        .or_else(|| {
            if meta.provider.is_empty() {
                None
            } else {
                Some(meta.provider.clone())
            }
        });
    e.timestamp = entry
        .get("timestamp")
        .and_then(parse_timestamp)
        .or_else(|| usage_holder.get("timestamp").and_then(parse_timestamp))
        .unwrap_or_else(crate::store::now_ms);
    e.input_tokens = usage.input;
    e.output_tokens = usage.output;
    e.cache_read_tokens = usage.cache_read;
    e.cache_write_tokens = usage.cache_write;
    e.reasoning_tokens = usage.reasoning;
    e.cost_usd = usage.cost;
    Some(e)
}

struct ParsedUsage {
    input: i64,
    output: i64,
    cache_read: i64,
    cache_write: i64,
    reasoning: i64,
    cost: Option<f64>,
}

fn parsed_usage(usage: &serde_json::Value) -> Option<ParsedUsage> {
    let n = |keys: &[&str]| {
        keys.iter()
            .find_map(|k| usage.get(*k).and_then(|x| x.as_i64()))
            .unwrap_or(0)
    };
    let input = n(&["input", "input_tokens"]);
    let raw_output = n(&["output", "output_tokens"]);
    let cache_read = n(&["cacheRead", "cache_read", "cache_read_tokens"]);
    let cache_write = n(&["cacheWrite", "cache_write", "cache_write_tokens"]);
    let reasoning = n(&["reasoning", "reasoning_tokens"]);
    if input + raw_output + cache_read + cache_write + reasoning == 0 {
        return None;
    }
    // Pi reports reasoning beside output, not inside it. Fold it in so totals and the
    // "reasoning ⊆ output" UI contract both stay honest.
    Some(ParsedUsage {
        input,
        output: raw_output + reasoning,
        cache_read,
        cache_write,
        reasoning,
        cost: usage
            .get("cost")
            .and_then(|c| c.get("total").or_else(|| c.as_f64().map(|_| c)))
            .and_then(|c| c.as_f64())
            .filter(|c| *c > 0.0),
    })
}

fn peek_session_header(path: &Path) -> Option<(String, Option<String>)> {
    use std::io::{BufRead, BufReader};
    let file = std::fs::File::open(path).ok()?;
    let mut first = String::new();
    BufReader::new(file).read_line(&mut first).ok()?;
    let v: serde_json::Value = serde_json::from_str(first.trim()).ok()?;
    if v.get("type").and_then(|t| t.as_str()) != Some("session") {
        return None;
    }
    let id = v.get("id").and_then(|x| x.as_str())?.to_string();
    let project = v
        .get("cwd")
        .and_then(|x| x.as_str())
        .and_then(project_label);
    Some((id, project))
}

fn session_id_from_filename(path: &Path) -> Option<String> {
    let stem = file_stem(path);
    stem.rsplit_once('_').map(|(_, id)| id.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn usage_json(raw: &str) -> serde_json::Value {
        serde_json::from_str(raw).unwrap()
    }

    #[test]
    fn folds_reasoning_into_output() {
        let usage = parsed_usage(&usage_json(
            r#"{"input":10,"output":4,"cacheRead":2,"cacheWrite":0,"reasoning":7,"totalTokens":16,"cost":{"total":0.12}}"#,
        ))
        .unwrap();
        assert_eq!(usage.input, 10);
        assert_eq!(usage.output, 11);
        assert_eq!(usage.reasoning, 7);
        assert_eq!(usage.cache_read, 2);
        assert_eq!(usage.cost, Some(0.12));
    }

    #[test]
    fn skips_zero_usage() {
        assert!(parsed_usage(&usage_json(r#"{"input":0,"output":0}"#)).is_none());
    }

    #[test]
    fn assistant_event_uses_entry_id_as_dedup() {
        let entry = usage_json(
            r#"{"type":"message","id":"a1b2c3d4","timestamp":"2026-08-14T10:01:21.596Z","message":{"role":"assistant","provider":"xai","model":"grok-4.6","usage":{"input":5,"output":1,"cacheRead":0,"cacheWrite":0,"reasoning":2,"cost":{"total":0.01}}}}"#,
        );
        let message = entry.get("message").unwrap();
        let meta = FileMeta {
            session_id: "sess-1".into(),
            project: Some("pi".into()),
            model: String::new(),
            provider: String::new(),
        };
        let e = event_from_usage(&entry, message, "local", &meta, "sess-1", "assistant").unwrap();
        assert_eq!(e.dedup_key, "sess-1:a1b2c3d4:assistant");
        assert_eq!(e.model, "grok-4.6");
        assert_eq!(e.provider.as_deref(), Some("xai"));
        assert_eq!(e.output_tokens, 3);
        assert_eq!(e.reasoning_tokens, 2);
        assert_eq!(e.cost_usd, Some(0.01));
        assert_eq!(e.project.as_deref(), Some("pi"));
    }

    #[test]
    fn session_id_falls_back_to_filename_uuid() {
        let path = Path::new(
            r"C:\Users\x\.pi\agent\sessions\--cwd--\2026-08-14T10-00-54-251Z_019fffb7-a8eb-7ffb-a395-fa37eea491a0.jsonl",
        );
        assert_eq!(
            session_id_from_filename(path).as_deref(),
            Some("019fffb7-a8eb-7ffb-a395-fa37eea491a0")
        );
    }

    #[test]
    fn extra_round_trips_last_model_for_later_chunks() {
        let extra = serde_json::to_string(&PiFileState {
            line_no: 42,
            session_id: "sess-1".into(),
            project: Some("pi".into()),
            model: "grok-4.6".into(),
            provider: "xai".into(),
        })
        .unwrap();
        let meta = file_meta_from_extra(&extra);
        assert_eq!(meta.model, "grok-4.6");
        assert_eq!(meta.provider, "xai");
        assert_eq!(line_no_from_extra(Some(&extra)), 42);

        let entry = usage_json(
            r#"{"type":"compaction","id":"cmp-1","timestamp":"2026-08-14T10:02:00Z","usage":{"input":1,"output":2}}"#,
        );
        let e = event_from_usage(&entry, &entry, "local", &meta, "sess-1", "compaction").unwrap();
        assert_eq!(e.model, "grok-4.6");
        assert_eq!(e.provider.as_deref(), Some("xai"));
        assert_eq!(e.dedup_key, "sess-1:cmp-1:compaction");
    }

    #[test]
    fn bare_integer_extra_does_not_wipe_line_no() {
        assert_eq!(line_no_from_extra(Some("17")), 17);
        assert_eq!(file_meta_from_extra("17").model, "");
    }
}
