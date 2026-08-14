//! DeepSeek Harness (`dsh`).
//!
//! Official sessions live under `$DSH_HOME/sessions` (default `~/.dsh/sessions`) as
//! `**/session.jsonl.zstd`: concatenated Zstandard frames, one header frame then one
//! frame per append batch. Each decoded line is a session event. Provider usage is on
//! `assistant/message.data.usage`; reasoning is a subset of output and is not added
//! again. Model/provider come from the message source or the last `request/header`.

use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};

use anyhow::Result;
use rayon::prelude::*;

use super::*;
use crate::model::{source, surface, PendingScanState, ScanState, UsageEvent};

pub struct DshCollector;

#[derive(Debug, Default, Clone)]
struct FileMeta {
    session_id: String,
    project: Option<String>,
    model: String,
    provider: String,
}

#[derive(Debug, Default, Clone, serde::Serialize, serde::Deserialize)]
struct DshFileState {
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

impl DshCollector {
    fn sessions_dir(settings: &AppSettings) -> PathBuf {
        if let Some(custom) = settings.custom_path(source::DSH) {
            return custom;
        }
        if let Ok(v) = std::env::var("DSH_HOME") {
            let trimmed = v.trim();
            if !trimmed.is_empty() {
                return PathBuf::from(trimmed).join("sessions");
            }
        }
        home_dir().join(".dsh").join("sessions")
    }
}

impl Collector for DshCollector {
    fn id(&self) -> &'static str {
        source::DSH
    }

    fn label(&self) -> &'static str {
        "DeepSeek Harness"
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

        let files: Vec<PathBuf> = find_files(&root, is_session_log);
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
                source: source::DSH.to_string(),
                instance: ctx.instance.clone(),
                key: path.to_string_lossy().to_string(),
                state: ScanState {
                    offset: chunk.new_offset,
                    mtime_ms: chunk.mtime_ms,
                    extra: serde_json::to_string(&DshFileState {
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

fn is_session_log(path: &Path) -> bool {
    let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
    name == "session.jsonl.zstd" || name == "session.jsonl"
}

fn parse_file(
    ctx: &ScanCtx,
    path: &Path,
) -> Option<(PathBuf, JsonlChunk, FileMeta, Vec<UsageEvent>, i64)> {
    let key = path.to_string_lossy().to_string();
    let stored = ctx.store.get_scan_state(source::DSH, &ctx.instance, &key);
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

    let chunk = if is_zstd(path) {
        read_new_zstd_lines(ctx.store, source::DSH, &ctx.instance, path).ok()?
    } else {
        read_new_lines(ctx.store, source::DSH, &ctx.instance, path).ok()?
    };
    if chunk.lines.is_empty() {
        return None;
    }

    if meta.session_id.is_empty() {
        if let Some(id) = session_id_from_dir(path) {
            meta.session_id = id;
        }
        if meta.project.is_none() {
            meta.project = project_from_session_path(path);
        }
    }

    let fallback_session = if meta.session_id.is_empty() {
        file_stem(path.parent().unwrap_or(path))
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
        match v.get("type").and_then(|t| t.as_str()).unwrap_or("") {
            "session" => apply_session_header(&v, &mut meta),
            "request/header" => apply_request_header(&v, &mut meta),
            "assistant/message" => {
                if let Some(e) = event_from_assistant(&v, &ctx.instance, &meta, &fallback_session) {
                    events.push(e);
                }
            }
            _ => {}
        }
    }

    Some((path.to_path_buf(), chunk, meta, events, skipped))
}

fn apply_session_header(v: &serde_json::Value, meta: &mut FileMeta) {
    if let Some(id) = v.get("id").and_then(|x| x.as_str()) {
        meta.session_id = id.to_string();
    }
    if let Some(cwd) = v.get("cwd").and_then(|x| x.as_str()) {
        meta.project = project_label(cwd);
    }
}

fn apply_request_header(v: &serde_json::Value, meta: &mut FileMeta) {
    let config = v
        .get("data")
        .and_then(|d| d.get("header"))
        .and_then(|h| h.get("config"));
    let Some(config) = config else {
        return;
    };
    if let Some(m) = config.get("model").and_then(|x| x.as_str()) {
        if !m.is_empty() {
            meta.model = m.to_string();
        }
    }
    if let Some(p) = config.get("provider").and_then(|x| x.as_str()) {
        if !p.is_empty() {
            meta.provider = p.to_string();
        }
    }
}

fn event_from_assistant(
    entry: &serde_json::Value,
    instance: &str,
    meta: &FileMeta,
    fallback_session: &str,
) -> Option<UsageEvent> {
    let data = entry.get("data").unwrap_or(entry);
    let usage = parsed_usage(data.get("usage")?)?;
    let seq = entry.get("seq").and_then(|x| x.as_i64())?;
    let session_id = if meta.session_id.is_empty() {
        fallback_session.to_string()
    } else {
        meta.session_id.clone()
    };
    let source = data.get("message").and_then(|m| m.get("source"));
    let model = source
        .and_then(|s| s.get("model"))
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
    let provider = source
        .and_then(|s| s.get("provider"))
        .and_then(|x| x.as_str())
        .map(|s| s.to_string())
        .or_else(|| {
            if meta.provider.is_empty() {
                None
            } else {
                Some(meta.provider.clone())
            }
        });

    let mut e = UsageEvent::new(
        source::DSH,
        surface::CLI,
        instance,
        format!("{session_id}:{seq}"),
    );
    e.session_id = session_id;
    e.project = meta.project.clone();
    e.model = model;
    e.provider = provider;
    e.timestamp = entry
        .get("time")
        .and_then(parse_timestamp)
        .unwrap_or_else(crate::store::now_ms);
    e.input_tokens = usage.input;
    e.output_tokens = usage.output;
    e.cache_read_tokens = usage.cache_read;
    e.cache_write_tokens = usage.cache_write;
    e.reasoning_tokens = usage.reasoning;
    Some(e)
}

struct ParsedUsage {
    input: i64,
    output: i64,
    cache_read: i64,
    cache_write: i64,
    reasoning: i64,
}

fn parsed_usage(usage: &serde_json::Value) -> Option<ParsedUsage> {
    let n = |keys: &[&str]| {
        keys.iter()
            .find_map(|k| usage.get(*k).and_then(|x| x.as_i64()))
            .unwrap_or(0)
    };
    let input = n(&["inputTokens", "uncachedInputTokens", "input"]);
    let output = n(&["outputTokens", "output"]);
    let cache_read = n(&["cacheReadTokens", "cacheRead"]);
    let cache_write = n(&["cacheWriteTokens", "cacheWrite"]);
    let reasoning = n(&["reasoningTokens", "reasoning"]);
    if input + output + cache_read + cache_write + reasoning == 0 {
        return None;
    }
    Some(ParsedUsage {
        input,
        output,
        cache_read,
        cache_write,
        reasoning,
    })
}

fn file_meta_from_extra(extra: &str) -> FileMeta {
    serde_json::from_str::<DshFileState>(extra)
        .map(|s| FileMeta {
            session_id: s.session_id,
            project: s.project,
            model: s.model,
            provider: s.provider,
        })
        .unwrap_or_default()
}

fn is_zstd(path: &Path) -> bool {
    path.file_name()
        .and_then(|s| s.to_str())
        .is_some_and(|n| n.ends_with(".zstd") || n.ends_with(".zst"))
}

fn session_id_from_dir(path: &Path) -> Option<String> {
    path.parent()
        .and_then(|p| p.file_name())
        .and_then(|s| s.to_str())
        .map(|s| s.to_string())
}

fn project_from_session_path(path: &Path) -> Option<String> {
    let project_dir = path.parent()?.parent()?;
    let name = project_dir.file_name()?.to_str()?;
    let trimmed = name.trim_matches('-');
    if trimmed.is_empty() || trimmed == "_no-cwd" {
        return None;
    }
    trimmed.rsplit('-').next().map(|s| s.to_string())
}

const ZSTD_MAGIC: [u8; 4] = [0x28, 0xB5, 0x2F, 0xFD];

/// Incremental read of concatenated Zstandard frames.
///
/// Each complete frame is one append batch. A trailing incomplete frame is left
/// for the next pass, matching [`read_new_lines`]'s partial-line rule.
fn read_new_zstd_lines(
    store: &Store,
    source: &str,
    instance: &str,
    path: &Path,
) -> Result<JsonlChunk> {
    let key = path.to_string_lossy().to_string();
    let state = store
        .get_scan_state(source, instance, &key)
        .unwrap_or_default();
    let size = file_size(path);
    let mtime = mtime_ms(path);

    let (offset, mut line_no) = if size < state.offset {
        (0, 0)
    } else {
        (state.offset, line_no_from_extra(state.extra.as_deref()))
    };

    if offset >= size {
        return Ok(JsonlChunk {
            lines: Vec::new(),
            new_offset: offset,
            new_line_no: line_no,
            mtime_ms: mtime,
        });
    }

    let bytes = std::fs::read(path)?;
    if offset as usize > bytes.len() {
        return Ok(JsonlChunk {
            lines: Vec::new(),
            new_offset: offset,
            new_line_no: line_no,
            mtime_ms: mtime,
        });
    }
    let (consumed, frames) = decode_complete_frames(&bytes[offset as usize..]);
    let mut lines = Vec::new();
    for text in frames {
        for raw in text.lines() {
            line_no += 1;
            let t = raw.trim();
            if !t.is_empty() {
                lines.push((line_no, t.to_string()));
            }
        }
    }
    Ok(JsonlChunk {
        lines,
        new_offset: offset + consumed,
        new_line_no: line_no,
        mtime_ms: mtime,
    })
}

fn decode_complete_frames(buf: &[u8]) -> (i64, Vec<String>) {
    let mut pos = 0usize;
    let mut frames = Vec::new();
    while pos < buf.len() {
        let Some(rel) = find_magic(&buf[pos..]) else {
            break;
        };
        let start = pos + rel;
        if start > pos && frames.is_empty() && pos == 0 {
            // Leading garbage before the first magic: skip it so a truncated
            // prefix cannot stall the watermark.
            pos = start;
            continue;
        }
        let next = find_magic(&buf[start + 4..]).map(|n| start + 4 + n);
        let end = next.unwrap_or(buf.len());
        match decode_one_frame(&buf[start..end]) {
            Some(text) => {
                frames.push(text);
                pos = end;
            }
            None => {
                // Incomplete trailing frame: wait for the writer to finish it.
                break;
            }
        }
    }
    (pos as i64, frames)
}

fn find_magic(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == ZSTD_MAGIC)
}

fn decode_one_frame(frame: &[u8]) -> Option<String> {
    let mut decoder = ruzstd::decoding::StreamingDecoder::new(Cursor::new(frame)).ok()?;
    let mut out = Vec::new();
    decoder.read_to_end(&mut out).ok()?;
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn usage_json(raw: &str) -> serde_json::Value {
        serde_json::from_str(raw).unwrap()
    }

    fn hex_bytes(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn counts_assistant_message_usage() {
        let usage = parsed_usage(&usage_json(
            r#"{"inputTokens":8783,"outputTokens":139,"cacheReadTokens":0,"reasoningTokens":82}"#,
        ))
        .unwrap();
        assert_eq!(usage.input, 8783);
        assert_eq!(usage.output, 139);
        assert_eq!(usage.reasoning, 82);
        assert_eq!(usage.cache_read, 0);
    }

    #[test]
    fn skips_zero_usage() {
        assert!(parsed_usage(&usage_json(r#"{"inputTokens":0,"outputTokens":0}"#)).is_none());
    }

    #[test]
    fn assistant_event_uses_session_and_seq() {
        let entry = usage_json(
            r#"{"type":"assistant/message","seq":159,"time":1786626078104,"data":{"message":{"source":{"kind":"model","provider":"deepseek-official","model":"deepseek-v4-flash"}},"usage":{"inputTokens":10,"outputTokens":4,"cacheReadTokens":2,"reasoningTokens":1}}}"#,
        );
        let meta = FileMeta {
            session_id: "session-abc".into(),
            project: Some("dsh".into()),
            model: String::new(),
            provider: String::new(),
        };
        let e = event_from_assistant(&entry, "local", &meta, "session-abc").unwrap();
        assert_eq!(e.dedup_key, "session-abc:159");
        assert_eq!(e.model, "deepseek-v4-flash");
        assert_eq!(e.provider.as_deref(), Some("deepseek-official"));
        assert_eq!(e.input_tokens, 10);
        assert_eq!(e.output_tokens, 4);
        assert_eq!(e.reasoning_tokens, 1);
        assert_eq!(e.cache_read_tokens, 2);
        assert_eq!(e.project.as_deref(), Some("dsh"));
    }

    #[test]
    fn request_header_fills_model_when_message_has_none() {
        let mut meta = FileMeta::default();
        apply_request_header(
            &usage_json(
                r#"{"type":"request/header","data":{"header":{"config":{"provider":"deepseek-official","model":"deepseek-v4-flash"}}}}"#,
            ),
            &mut meta,
        );
        let entry = usage_json(
            r#"{"type":"assistant/message","seq":1,"time":1,"data":{"usage":{"inputTokens":3,"outputTokens":1}}}"#,
        );
        let e = event_from_assistant(&entry, "local", &meta, "s").unwrap();
        assert_eq!(e.model, "deepseek-v4-flash");
        assert_eq!(e.provider.as_deref(), Some("deepseek-official"));
    }

    #[test]
    fn project_label_from_cwd_slug() {
        let path = Path::new(
            r"C:\Users\x\.dsh\sessions\--C-Users-AndyYan-dsh--\session-95258bb5-ade4-48ec-b16a-740cd18cbbf1\session.jsonl.zstd",
        );
        assert_eq!(project_from_session_path(path).as_deref(), Some("dsh"));
        assert_eq!(
            session_id_from_dir(path).as_deref(),
            Some("session-95258bb5-ade4-48ec-b16a-740cd18cbbf1")
        );
    }

    #[test]
    fn decodes_concatenated_zstd_frames() {
        let bytes = hex_bytes(
            "28b52ffd20329101007b2274797065223a2273657373696f6e222c226964223a227331222c22637764223a22433a5c70726f6a5c64656d6f227d0a28b52ffd206595020052c51117a0b539e4034482a7dd6fff0712fb5f61da6849801a3246426b8dd8957c05fa4803c9d8a59031c36586cecdc3470829683d667d052dd0fbac80fcf50c8b726ffe345ad560cd020200685ad3732928",
        );
        let (consumed, frames) = decode_complete_frames(&bytes);
        assert_eq!(consumed as usize, bytes.len());
        assert_eq!(frames.len(), 2);
        assert!(frames[0].contains(r#""type":"session""#));
        assert!(frames[1].contains(r#""type":"assistant/message""#));
    }

    #[test]
    fn extra_round_trips_line_no_and_model() {
        let extra = serde_json::to_string(&DshFileState {
            line_no: 12,
            session_id: "session-abc".into(),
            project: Some("dsh".into()),
            model: "deepseek-v4-flash".into(),
            provider: "deepseek-official".into(),
        })
        .unwrap();
        let meta = file_meta_from_extra(&extra);
        assert_eq!(meta.model, "deepseek-v4-flash");
        assert_eq!(line_no_from_extra(Some(&extra)), 12);
    }
}
