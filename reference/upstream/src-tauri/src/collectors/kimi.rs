//! Kimi Code CLI (Moonshot).
//!
//! Current builds write per-turn `usage.record` lines under
//! `~/.kimi-code/sessions/<workDirKey>/<sessionId>/agents/<agent>/wire.jsonl`.
//! Session-scoped records are cumulative totals and must be ignored.
//!
//! Older kimi-cli builds used `~/.kimi/sessions/**/wire.jsonl` and emitted
//! `StatusUpdate` messages with a `token_usage` payload. Both shapes are accepted.

use std::path::{Path, PathBuf};

use anyhow::Result;
use rayon::prelude::*;

use super::*;
use crate::model::{source, surface, UsageEvent};

pub struct KimiCollector;

impl KimiCollector {
    fn data_roots(settings: &AppSettings) -> Vec<PathBuf> {
        if let Some(custom) = settings.custom_path(source::KIMI) {
            return vec![custom];
        }
        let mut roots = Vec::new();
        if let Ok(v) = std::env::var("KIMI_CODE_HOME") {
            let trimmed = v.trim();
            if !trimmed.is_empty() {
                roots.push(PathBuf::from(trimmed));
            }
        }
        if let Ok(v) = std::env::var("KIMI_DATA_DIR") {
            for part in v.split(',') {
                let trimmed = part.trim();
                if !trimmed.is_empty() {
                    roots.push(PathBuf::from(trimmed));
                }
            }
        }
        if roots.is_empty() {
            roots.push(home_dir().join(".kimi-code"));
            let legacy = home_dir().join(".kimi");
            if legacy.is_dir() {
                roots.push(legacy);
            }
        }
        roots.into_iter().filter(|p| p.exists()).collect()
    }

    fn sessions_dirs(settings: &AppSettings) -> Vec<PathBuf> {
        Self::data_roots(settings)
            .into_iter()
            .map(|r| r.join("sessions"))
            .filter(|p| p.is_dir())
            .collect()
    }
}

impl Collector for KimiCollector {
    fn id(&self) -> &'static str {
        source::KIMI
    }

    fn label(&self) -> &'static str {
        "Kimi Code"
    }

    fn write_mode(&self) -> WriteMode {
        // StatusUpdate rows for the same message_id can grow as a turn streams.
        WriteMode::Upsert
    }

    fn detect(&self, settings: &AppSettings) -> Vec<PathBuf> {
        Self::sessions_dirs(settings)
    }

    fn watch_paths(&self, settings: &AppSettings) -> Vec<PathBuf> {
        self.detect(settings)
    }

    fn scan(&self, ctx: &ScanCtx) -> Result<ScanReport> {
        let roots: Vec<PathBuf> = match &ctx.root_override {
            Some(root) => vec![root.clone()],
            None => Self::sessions_dirs(ctx.settings),
        };
        if roots.is_empty() {
            return Ok(ScanReport::default());
        }

        let projects = project_index(ctx.settings, &roots);

        let files: Vec<PathBuf> = roots
            .iter()
            .flat_map(|r| find_files(r, |p| p.file_name().is_some_and(|n| n == "wire.jsonl")))
            .collect();

        let per_file: Vec<(PathBuf, JsonlChunk, Vec<UsageEvent>, i64)> = files
            .par_iter()
            .filter_map(|path| {
                let chunk = read_new_lines(ctx.store, source::KIMI, &ctx.instance, path).ok()?;
                if chunk.lines.is_empty() {
                    return None;
                }
                let loc = location_from_path(path);
                let project = loc
                    .session_id
                    .as_deref()
                    .and_then(|id| projects.get(id).cloned())
                    .or_else(|| loc.project.clone());
                let (events, skipped) = parse_lines(&chunk, &loc, project, &ctx.instance);
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
                source::KIMI,
                &ctx.instance,
                &path,
                &chunk,
            ));
        }

        report.events = finalize(report.events, ctx.pricing);
        Ok(report)
    }
}

#[derive(Debug, Default, Clone)]
struct WireLocation {
    session_id: Option<String>,
    agent: String,
    project: Option<String>,
}

/// `.../<workDirKey>/<sessionId>/agents/<agent>/wire.jsonl`
/// or legacy `.../<group>/<sessionId>/wire.jsonl`.
fn location_from_path(path: &Path) -> WireLocation {
    let mut loc = WireLocation {
        agent: "main".into(),
        ..Default::default()
    };
    let parts: Vec<_> = path.iter().filter_map(|s| s.to_str()).collect();
    if let Some(i) = parts.iter().rposition(|p| *p == "agents") {
        if let Some(agent) = parts.get(i + 1) {
            loc.agent = (*agent).to_string();
        }
        if i >= 1 {
            loc.session_id = Some(parts[i - 1].to_string());
        }
        if i >= 2 {
            loc.project = project_from_workdir_key(parts[i - 2]);
        }
        return loc;
    }
    if let Some(name) = path
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|s| s.to_str())
    {
        loc.session_id = Some(name.to_string());
    }
    loc
}

fn project_from_workdir_key(key: &str) -> Option<String> {
    let rest = key.strip_prefix("wd_")?;
    Some(rest.to_string())
}

fn project_index(
    settings: &AppSettings,
    session_roots: &[PathBuf],
) -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    let mut index_files: Vec<PathBuf> = session_roots
        .iter()
        .filter_map(|sessions| {
            sessions
                .parent()
                .map(|root| root.join("session_index.jsonl"))
        })
        .collect();
    if index_files.is_empty() {
        for root in KimiCollector::data_roots(settings) {
            index_files.push(root.join("session_index.jsonl"));
        }
    }
    for path in index_files {
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        for line in text.lines() {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
                continue;
            };
            let Some(id) = v.get("sessionId").and_then(|x| x.as_str()) else {
                continue;
            };
            if let Some(label) = v
                .get("workDir")
                .and_then(|x| x.as_str())
                .and_then(project_label)
            {
                out.insert(id.to_string(), label);
            }
        }
    }
    out
}

fn parse_lines(
    chunk: &JsonlChunk,
    loc: &WireLocation,
    project: Option<String>,
    instance: &str,
) -> (Vec<UsageEvent>, i64) {
    let mut by_key: std::collections::HashMap<String, UsageEvent> =
        std::collections::HashMap::new();
    let mut order: Vec<String> = Vec::new();
    let mut skipped = 0i64;
    let session = loc.session_id.clone().unwrap_or_else(|| "unknown".into());

    for (line_no, line) in &chunk.lines {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            skipped += 1;
            continue;
        };
        let Some(parsed) = parse_usage_line(&v) else {
            continue;
        };
        if parsed.input + parsed.output + parsed.cache_read + parsed.cache_write == 0 {
            continue;
        }

        // StatusUpdate rows share a message_id while a turn streams, so that key
        // must stay stable. usage.record has no id; time alone can collide, so
        // the absolute line number is part of the key.
        let dedup_key = if let Some(id) = parsed.message_id.as_deref() {
            format!("{session}:{}:{id}", loc.agent)
        } else if let Some(ts) = parsed.time_ms {
            format!("{session}:{}:{ts}:{line_no}", loc.agent)
        } else {
            format!("{session}:{}:{line_no}", loc.agent)
        };

        let mut e = UsageEvent::new(source::KIMI, surface::CLI, instance, dedup_key.clone());
        e.session_id = session.clone();
        e.project = project.clone();
        e.model = parsed.model.unwrap_or_else(|| "unknown".into());
        e.provider = Some("moonshot".into());
        e.timestamp = parsed.time_ms.unwrap_or_else(crate::store::now_ms);
        e.input_tokens = parsed.input;
        e.output_tokens = parsed.output;
        e.cache_read_tokens = parsed.cache_read;
        e.cache_write_tokens = parsed.cache_write;

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

struct KimiUsage {
    input: i64,
    output: i64,
    cache_read: i64,
    cache_write: i64,
    model: Option<String>,
    time_ms: Option<i64>,
    message_id: Option<String>,
}

fn parse_usage_line(v: &serde_json::Value) -> Option<KimiUsage> {
    match v.get("type").and_then(|t| t.as_str()) {
        Some("usage.record") => parse_usage_record(v),
        _ => parse_status_update(v),
    }
}

fn parse_usage_record(v: &serde_json::Value) -> Option<KimiUsage> {
    let scope = v
        .get("usageScope")
        .and_then(|s| s.as_str())
        .unwrap_or("turn");
    if scope != "turn" {
        return None;
    }
    let usage = v.get("usage")?;
    Some(KimiUsage {
        input: usage_i64(usage, &["inputOther", "input_other"]),
        output: usage_i64(usage, &["output"]),
        cache_read: usage_i64(usage, &["inputCacheRead", "input_cache_read"]),
        cache_write: usage_i64(usage, &["inputCacheCreation", "input_cache_creation"]),
        model: v
            .get("model")
            .and_then(|x| x.as_str())
            .map(|s| s.to_string()),
        time_ms: v.get("time").and_then(parse_timestamp),
        message_id: None,
    })
}

fn parse_status_update(v: &serde_json::Value) -> Option<KimiUsage> {
    let message = v.get("message").unwrap_or(v);
    let is_status = message.get("type").and_then(|t| t.as_str()) == Some("StatusUpdate")
        || v.get("type").and_then(|t| t.as_str()) == Some("StatusUpdate");
    if !is_status {
        return None;
    }
    let payload = message.get("payload").unwrap_or(message);
    let usage = payload
        .get("token_usage")
        .or_else(|| payload.get("tokenUsage"))?;
    Some(KimiUsage {
        input: usage_i64(usage, &["input_other", "inputOther"]),
        output: usage_i64(usage, &["output"]),
        cache_read: usage_i64(usage, &["input_cache_read", "inputCacheRead"]),
        cache_write: usage_i64(usage, &["input_cache_creation", "inputCacheCreation"]),
        model: v
            .get("model")
            .or_else(|| payload.get("model"))
            .and_then(|x| x.as_str())
            .map(|s| s.to_string()),
        time_ms: v
            .get("timestamp")
            .or_else(|| v.get("time"))
            .and_then(parse_timestamp),
        message_id: payload
            .get("message_id")
            .or_else(|| payload.get("messageId"))
            .and_then(|x| x.as_str())
            .map(|s| s.to_string()),
    })
}

fn usage_i64(usage: &serde_json::Value, keys: &[&str]) -> i64 {
    keys.iter()
        .find_map(|k| usage.get(*k).and_then(|x| x.as_i64()))
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn loc() -> WireLocation {
        WireLocation {
            session_id: Some("session_abc".into()),
            agent: "main".into(),
            project: Some("kimi".into()),
        }
    }

    #[test]
    fn counts_turn_usage_record() {
        let line = r#"{"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":2924,"output":247,"inputCacheRead":18944,"inputCacheCreation":0},"usageScope":"turn","time":1786676166398}"#;
        let chunk = JsonlChunk {
            lines: vec![(1, line.into())],
            new_offset: line.len() as i64,
            new_line_no: 1,
            mtime_ms: 0,
        };
        let (events, skipped) = parse_lines(&chunk, &loc(), Some("kimi".into()), "local");
        assert_eq!(skipped, 0);
        assert_eq!(events.len(), 1);
        let e = &events[0];
        assert_eq!(e.input_tokens, 2924);
        assert_eq!(e.output_tokens, 247);
        assert_eq!(e.cache_read_tokens, 18944);
        assert_eq!(e.model, "kimi-code/k3");
        assert_eq!(e.dedup_key, "session_abc:main:1786676166398:1");
        assert_eq!(e.provider.as_deref(), Some("moonshot"));
    }

    #[test]
    fn same_timestamp_turn_records_stay_distinct() {
        let line = r#"{"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":1,"output":2,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":100}"#;
        let chunk = JsonlChunk {
            lines: vec![(4, line.into()), (5, line.into())],
            new_offset: 2,
            new_line_no: 5,
            mtime_ms: 0,
        };
        let (events, _) = parse_lines(&chunk, &loc(), None, "local");
        assert_eq!(events.len(), 2);
        // `time: 100` is treated as epoch seconds and stored as milliseconds.
        assert_eq!(events[0].dedup_key, "session_abc:main:100000:4");
        assert_eq!(events[1].dedup_key, "session_abc:main:100000:5");
    }

    #[test]
    fn status_update_dedup_stays_stable_across_lines() {
        let line = r#"{"timestamp":1770983426.420942,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":1,"output":2,"input_cache_read":0,"input_cache_creation":0},"message_id":"chatcmpl-xxx"}}}"#;
        let chunk = JsonlChunk {
            lines: vec![(8, line.into()), (9, line.into())],
            new_offset: 2,
            new_line_no: 9,
            mtime_ms: 0,
        };
        let (events, _) = parse_lines(&chunk, &loc(), None, "local");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].dedup_key, "session_abc:main:chatcmpl-xxx");
    }

    #[test]
    fn ignores_session_scoped_totals() {
        let line = r#"{"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":100,"output":20,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"session","time":1}"#;
        let chunk = JsonlChunk {
            lines: vec![(1, line.into())],
            new_offset: 1,
            new_line_no: 1,
            mtime_ms: 0,
        };
        let (events, _) = parse_lines(&chunk, &loc(), None, "local");
        assert!(events.is_empty());
    }

    #[test]
    fn parses_legacy_status_update() {
        let line = r#"{"timestamp":1770983426.420942,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":1562,"output":2463,"input_cache_read":3,"input_cache_creation":4},"message_id":"chatcmpl-xxx"}}}"#;
        let parsed = parse_usage_line(&serde_json::from_str(line).unwrap()).unwrap();
        assert_eq!(parsed.input, 1562);
        assert_eq!(parsed.output, 2463);
        assert_eq!(parsed.cache_read, 3);
        assert_eq!(parsed.cache_write, 4);
        assert_eq!(parsed.message_id.as_deref(), Some("chatcmpl-xxx"));
    }

    #[test]
    fn location_from_kimi_code_path() {
        let path = Path::new(
            r"C:\Users\x\.kimi-code\sessions\wd_kimi_2885694a324d\session_072c141c-3591-467a-89f6-e095f98b90c5\agents\main\wire.jsonl",
        );
        let loc = location_from_path(path);
        assert_eq!(
            loc.session_id.as_deref(),
            Some("session_072c141c-3591-467a-89f6-e095f98b90c5")
        );
        assert_eq!(loc.agent, "main");
        assert_eq!(loc.project.as_deref(), Some("kimi_2885694a324d"));
    }
}
