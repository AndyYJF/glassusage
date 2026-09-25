//! DeepSeek Harness (`dsh`).
//!
//! Official sessions live under `$DSH_HOME/sessions` (default `~/.dsh/sessions`).
//! Each session directory keeps generational logs: `session.jsonl.zstd` (v0) and
//! `session.vN.jsonl.zstd`. Only the highest generation is live; older files are
//! frozen migration snapshots and summing them would count the same calls twice.
//!
//! A log is concatenated Zstandard frames, one header frame then one frame per
//! append batch. Usage is folded like `@deepseek-ai/dsh-token-meter`'s `tokenUsage`
//! projection: `assistant/message` and `assistant/attempt` samples for the same
//! turn/step replace each other, `llm/retry-started` closes that slot so the retry
//! is added, and `compaction/summary` usage is added on its own. Reasoning is a
//! subset of output and is not added again. Model/provider come from the message
//! source or the last `request/header`.

use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};

use anyhow::Result;
use rayon::prelude::*;

use super::*;
use crate::model::{source, surface, PendingScanState, ScanState, UsageEvent};
use crate::store::{Store, WriteMode};

/// Bumped when the on-disk fold no longer matches previously stored dedup keys.
/// A lower marker wipes this instance's dsh rows once and rereads the latest
/// generation; v0 and v3 logs assign different `seq` values to the same call.
const FOLD_VERSION: i64 = 2;
const FOLD_MARKER: &str = "dsh-fold-version";

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
    /// `seq` of the assistant sample currently open for replacement.
    #[serde(default)]
    slot_seq: i64,
    #[serde(default)]
    slot_open: bool,
    #[serde(default)]
    slot_turn: Option<i64>,
    #[serde(default)]
    slot_step: Option<i64>,
    #[serde(default)]
    slot_input: i64,
    #[serde(default)]
    slot_output: i64,
    #[serde(default)]
    slot_cache_read: i64,
    #[serde(default)]
    slot_cache_write: i64,
    #[serde(default)]
    slot_reasoning: i64,
}

#[derive(Debug, Default, Clone)]
struct UsageFold {
    slot_seq: i64,
    slot_open: bool,
    slot_turn: Option<i64>,
    slot_step: Option<i64>,
    input: i64,
    output: i64,
    cache_read: i64,
    cache_write: i64,
    reasoning: i64,
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

    fn write_mode(&self) -> WriteMode {
        // A later sample for the same turn/step replaces the open slot's row.
        WriteMode::Upsert
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

        let mut report = ScanReport {
            detected_paths: if root.is_dir() {
                vec![root.to_string_lossy().to_string()]
            } else {
                Vec::new()
            },
            ..Default::default()
        };
        if stored_fold_version(ctx.store, &ctx.instance) < FOLD_VERSION {
            // v0 watermarks point at a different file than v3, and the two
            // generations number `seq` differently, so old rows cannot be reused.
            ctx.store.delete_source(source::DSH, Some(&ctx.instance))?;
            ctx.store
                .clear_scan_state(source::DSH, Some(&ctx.instance))?;
            report.states.push(fold_marker(&ctx.instance));
        }

        let files = choose_latest_logs(find_files(&root, is_session_log));
        let per_file: Vec<(
            PathBuf,
            JsonlChunk,
            FileMeta,
            UsageFold,
            Vec<UsageEvent>,
            i64,
        )> = files
            .par_iter()
            .filter_map(|path| parse_file(ctx, path))
            .collect();

        report.files_seen = files.len() as i64;
        for (path, chunk, meta, fold, events, skipped) in per_file {
            report.events.extend(events);
            report.skipped += skipped;
            report.states.push(PendingScanState {
                source: source::DSH.to_string(),
                instance: ctx.instance.clone(),
                key: path.to_string_lossy().to_string(),
                state: ScanState {
                    offset: chunk.new_offset,
                    mtime_ms: chunk.mtime_ms,
                    extra: serde_json::to_string(&file_state(&meta, &fold, chunk.new_line_no)).ok(),
                },
            });
        }

        report.events = finalize(report.events, ctx.pricing);
        Ok(report)
    }
}

fn is_session_log(path: &Path) -> bool {
    session_log_rank(path).is_some()
}

/// `(generation, is_zstd)`. v0 is `session.jsonl[.zstd]`; later gens are `session.vN.jsonl[.zstd]`.
fn session_log_rank(path: &Path) -> Option<(u32, bool)> {
    let name = path.file_name()?.to_str()?;
    let zstd = name.ends_with(".zstd") || name.ends_with(".zst");
    let base = name
        .strip_suffix(".zstd")
        .or_else(|| name.strip_suffix(".zst"))
        .unwrap_or(name);
    if base == "session.jsonl" {
        return Some((0, zstd));
    }
    let ver = base
        .strip_prefix("session.v")?
        .strip_suffix(".jsonl")?
        .parse()
        .ok()?;
    Some((ver, zstd))
}

/// One log per session directory: the highest generation, preferring zstd on a tie.
fn choose_latest_logs(files: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut best: std::collections::HashMap<PathBuf, (u32, bool, PathBuf)> =
        std::collections::HashMap::new();
    for path in files {
        let Some(parent) = path.parent() else {
            continue;
        };
        let Some(rank) = session_log_rank(&path) else {
            continue;
        };
        let replace = match best.get(parent) {
            None => true,
            Some((ver, zstd, _)) => rank.0 > *ver || (rank.0 == *ver && rank.1 && !*zstd),
        };
        if replace {
            best.insert(parent.to_path_buf(), (rank.0, rank.1, path));
        }
    }
    let mut out: Vec<_> = best.into_values().map(|(_, _, path)| path).collect();
    out.sort();
    out
}

fn stored_fold_version(store: &Store, instance: &str) -> i64 {
    store
        .get_scan_state(source::DSH, instance, FOLD_MARKER)
        .and_then(|s| s.extra)
        .and_then(|extra| serde_json::from_str::<serde_json::Value>(&extra).ok())
        .and_then(|v| v.get("fold_version").and_then(|x| x.as_i64()))
        .unwrap_or(0)
}

fn fold_marker(instance: &str) -> PendingScanState {
    PendingScanState {
        source: source::DSH.to_string(),
        instance: instance.to_string(),
        key: FOLD_MARKER.to_string(),
        state: ScanState {
            offset: FOLD_VERSION,
            mtime_ms: 0,
            extra: Some(format!(r#"{{"fold_version":{FOLD_VERSION}}}"#)),
        },
    }
}

fn parse_file(
    ctx: &ScanCtx,
    path: &Path,
) -> Option<(
    PathBuf,
    JsonlChunk,
    FileMeta,
    UsageFold,
    Vec<UsageEvent>,
    i64,
)> {
    let key = path.to_string_lossy().to_string();
    let stored = ctx.store.get_scan_state(source::DSH, &ctx.instance, &key);
    let size = file_size(path);
    let truncated = stored.as_ref().is_some_and(|s| size < s.offset);
    let mut meta = if truncated {
        FileMeta::default()
    } else {
        match &stored {
            Some(s) => s
                .extra
                .as_deref()
                .map(file_meta_from_extra)
                .unwrap_or_default(),
            None => FileMeta::default(),
        }
    };
    let mut fold = if truncated {
        UsageFold::default()
    } else {
        match &stored {
            Some(s) => s.extra.as_deref().map(fold_from_extra).unwrap_or_default(),
            None => UsageFold::default(),
        }
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
        apply_entry(
            &v,
            &ctx.instance,
            &mut meta,
            &fallback_session,
            &mut fold,
            &mut events,
        );
    }

    Some((path.to_path_buf(), chunk, meta, fold, events, skipped))
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

fn apply_entry(
    entry: &serde_json::Value,
    instance: &str,
    meta: &mut FileMeta,
    fallback_session: &str,
    fold: &mut UsageFold,
    events: &mut Vec<UsageEvent>,
) {
    match entry.get("type").and_then(|t| t.as_str()).unwrap_or("") {
        "session" => apply_session_header(entry, meta),
        "request/header" => apply_request_header(entry, meta),
        "llm/retry-started" => note_retry(entry, fold),
        "compaction/summary" => {
            if let Some(event) = event_from_compaction(entry, instance, meta, fallback_session) {
                events.push(event);
            }
        }
        "assistant/message" | "assistant/attempt" => {
            if let Some(event) = event_from_folded(entry, instance, meta, fallback_session, fold) {
                events.push(event);
            }
        }
        _ => {}
    }
}

fn note_retry(entry: &serde_json::Value, fold: &mut UsageFold) {
    let data = entry.get("data");
    let turn = data.and_then(|d| d.get("turn")).and_then(|x| x.as_i64());
    let step = data.and_then(|d| d.get("step")).and_then(|x| x.as_i64());
    if fold.slot_open && fold.slot_turn == turn && fold.slot_step == step {
        fold.slot_open = false;
    }
}

fn event_from_folded(
    entry: &serde_json::Value,
    instance: &str,
    meta: &FileMeta,
    fallback_session: &str,
    fold: &mut UsageFold,
) -> Option<UsageEvent> {
    let usage = parsed_usage(usage_of(entry)?)?;
    let seq = entry.get("seq").and_then(|x| x.as_i64())?;
    let data = entry.get("data").unwrap_or(entry);
    let turn = data.get("turn").and_then(|x| x.as_i64());
    let step = data.get("step").and_then(|x| x.as_i64());
    let same = fold.slot_open && turn.is_some() && fold.slot_turn == turn && fold.slot_step == step;
    if same && fold.matches(&usage) {
        return None;
    }
    let slot_seq = if same { fold.slot_seq } else { seq };
    if !same {
        fold.slot_open = true;
        fold.slot_turn = turn;
        fold.slot_step = step;
        fold.slot_seq = seq;
    }
    fold.remember(&usage);
    event_from_usage(
        entry,
        &format!("s:{slot_seq}"),
        &usage,
        instance,
        meta,
        fallback_session,
    )
}

fn event_from_compaction(
    entry: &serde_json::Value,
    instance: &str,
    meta: &FileMeta,
    fallback_session: &str,
) -> Option<UsageEvent> {
    let usage = parsed_usage(entry.get("data")?.get("usage")?)?;
    let seq = entry.get("seq").and_then(|x| x.as_i64())?;
    event_from_usage(
        entry,
        &format!("c:{seq}"),
        &usage,
        instance,
        meta,
        fallback_session,
    )
}

/// Last provider usage sample on an assistant settlement.
///
/// `assistant/message` prefers `data.usage`. Both message and attempt fall back
/// to the last `usage` chunk in `data.stream`, matching dsh-token-meter.
fn usage_of(entry: &serde_json::Value) -> Option<&serde_json::Value> {
    let ty = entry.get("type").and_then(|t| t.as_str())?;
    let data = entry.get("data")?;
    if ty == "assistant/message" {
        if let Some(usage) = data.get("usage").filter(|u| u.is_object()) {
            return Some(usage);
        }
    }
    if ty == "assistant/message" || ty == "assistant/attempt" {
        return last_stream_usage(data.get("stream")?);
    }
    None
}

fn last_stream_usage(stream: &serde_json::Value) -> Option<&serde_json::Value> {
    stream.as_array()?.iter().rev().find_map(|item| {
        if item.get("type").and_then(|t| t.as_str()) != Some("chunk") {
            return None;
        }
        let chunk = item.get("chunk")?;
        if chunk.get("type").and_then(|t| t.as_str()) != Some("usage") {
            return None;
        }
        chunk.get("usage").filter(|u| u.is_object())
    })
}

fn event_from_usage(
    entry: &serde_json::Value,
    slot: &str,
    usage: &ParsedUsage,
    instance: &str,
    meta: &FileMeta,
    fallback_session: &str,
) -> Option<UsageEvent> {
    let data = entry.get("data").unwrap_or(entry);
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
        format!("{session_id}:{slot}"),
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

fn fold_from_extra(extra: &str) -> UsageFold {
    serde_json::from_str::<DshFileState>(extra)
        .map(|s| UsageFold {
            slot_seq: s.slot_seq,
            slot_open: s.slot_open,
            slot_turn: s.slot_turn,
            slot_step: s.slot_step,
            input: s.slot_input,
            output: s.slot_output,
            cache_read: s.slot_cache_read,
            cache_write: s.slot_cache_write,
            reasoning: s.slot_reasoning,
        })
        .unwrap_or_default()
}

fn file_state(meta: &FileMeta, fold: &UsageFold, line_no: i64) -> DshFileState {
    DshFileState {
        line_no,
        session_id: meta.session_id.clone(),
        project: meta.project.clone(),
        model: meta.model.clone(),
        provider: meta.provider.clone(),
        slot_seq: fold.slot_seq,
        slot_open: fold.slot_open,
        slot_turn: fold.slot_turn,
        slot_step: fold.slot_step,
        slot_input: fold.input,
        slot_output: fold.output,
        slot_cache_read: fold.cache_read,
        slot_cache_write: fold.cache_write,
        slot_reasoning: fold.reasoning,
    }
}

impl UsageFold {
    fn matches(&self, usage: &ParsedUsage) -> bool {
        self.input == usage.input
            && self.output == usage.output
            && self.cache_read == usage.cache_read
            && self.cache_write == usage.cache_write
            && self.reasoning == usage.reasoning
    }

    fn remember(&mut self, usage: &ParsedUsage) {
        self.input = usage.input;
        self.output = usage.output;
        self.cache_read = usage.cache_read;
        self.cache_write = usage.cache_write;
        self.reasoning = usage.reasoning;
    }
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

    fn replay(lines: &[&str]) -> Vec<UsageEvent> {
        replay_with(
            FileMeta {
                session_id: "session-abc".into(),
                project: Some("dsh".into()),
                ..Default::default()
            },
            lines,
        )
    }

    fn replay_with(mut meta: FileMeta, lines: &[&str]) -> Vec<UsageEvent> {
        let mut fold = UsageFold::default();
        let mut events = Vec::new();
        for line in lines {
            apply_entry(
                &usage_json(line),
                "local",
                &mut meta,
                "session-abc",
                &mut fold,
                &mut events,
            );
        }
        events
    }

    fn sum_tokens(events: &[UsageEvent]) -> i64 {
        events.iter().map(|e| e.total_tokens()).sum()
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
        let e = replay(&[
            r#"{"type":"assistant/message","seq":159,"time":1786626078104,"data":{"turn":1,"step":1,"message":{"source":{"kind":"model","provider":"deepseek-official","model":"deepseek-v4-flash"}},"usage":{"inputTokens":10,"outputTokens":4,"cacheReadTokens":2,"reasoningTokens":1}}}"#,
        ])
        .pop()
        .unwrap();
        assert_eq!(e.dedup_key, "session-abc:s:159");
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
        let events = replay_with(
            meta,
            &[
                r#"{"type":"assistant/message","seq":1,"time":1,"data":{"turn":1,"step":1,"usage":{"inputTokens":3,"outputTokens":1}}}"#,
            ],
        );
        let e = events.last().unwrap();
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
            ..Default::default()
        })
        .unwrap();
        let meta = file_meta_from_extra(&extra);
        assert_eq!(meta.model, "deepseek-v4-flash");
        assert_eq!(line_no_from_extra(Some(&extra)), 12);
    }

    #[test]
    fn keeps_only_the_highest_session_generation() {
        let paths = vec![
            PathBuf::from("root/sess/session.jsonl.zstd"),
            PathBuf::from("root/sess/session.v3.jsonl.zstd"),
            PathBuf::from("root/sess/session.v1.jsonl.zstd"),
            PathBuf::from("root/other/session.jsonl"),
            PathBuf::from("root/other/session.jsonl.zstd"),
        ];
        let chosen = choose_latest_logs(paths);
        assert_eq!(chosen.len(), 2);
        assert!(chosen.iter().any(|p| p.ends_with("session.v3.jsonl.zstd")));
        assert!(chosen.iter().any(|p| p.ends_with("session.jsonl.zstd")));
        assert!(!chosen.iter().any(|p| p.ends_with("session.v1.jsonl.zstd")));
        assert!(!chosen.iter().any(|p| p.ends_with("session.jsonl")));
    }

    #[test]
    fn same_turn_replaces_and_retry_adds() {
        let replaced = replay(&[
            r#"{"type":"assistant/attempt","seq":10,"time":1,"data":{"turn":1,"step":1,"stream":[{"type":"chunk","chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":10,"cacheReadTokens":1000}}}]}}"#,
            r#"{"type":"assistant/message","seq":11,"time":2,"data":{"turn":1,"step":1,"usage":{"inputTokens":120,"outputTokens":12,"cacheReadTokens":4000}}}"#,
        ]);
        assert_eq!(replaced.len(), 2);
        assert_eq!(replaced[0].dedup_key, replaced[1].dedup_key);
        assert_eq!(replaced[1].input_tokens, 120);
        assert_eq!(replaced[1].cache_read_tokens, 4000);
        assert_eq!(sum_tokens(&replaced[1..]), 120 + 12 + 4000);

        let retried = replay(&[
            r#"{"type":"assistant/attempt","seq":10,"time":1,"data":{"turn":1,"step":1,"stream":[{"type":"chunk","chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":10}}}]}}"#,
            r#"{"type":"llm/retry-started","seq":11,"data":{"turn":1,"step":1}}"#,
            r#"{"type":"assistant/message","seq":12,"time":2,"data":{"turn":1,"step":1,"usage":{"inputTokens":80,"outputTokens":8}}}"#,
        ]);
        assert_eq!(retried.len(), 2);
        assert_ne!(retried[0].dedup_key, retried[1].dedup_key);
        assert_eq!(sum_tokens(&retried), 100 + 10 + 80 + 8);
    }

    #[test]
    fn compaction_adds_without_closing_the_slot() {
        let events = replay(&[
            r#"{"type":"assistant/message","seq":1,"time":1,"data":{"turn":1,"step":1,"usage":{"inputTokens":10,"outputTokens":1}}}"#,
            r#"{"type":"compaction/summary","seq":2,"time":2,"data":{"usage":{"inputTokens":5000,"outputTokens":200,"cacheReadTokens":40000}}}"#,
            r#"{"type":"assistant/message","seq":3,"time":3,"data":{"turn":1,"step":1,"usage":{"inputTokens":12,"outputTokens":2}}}"#,
        ]);
        assert_eq!(events.len(), 3);
        assert_eq!(events[0].dedup_key, events[2].dedup_key);
        assert_eq!(events[1].dedup_key, "session-abc:c:2");
        assert_eq!(events[1].cache_read_tokens, 40000);
        // Replacement drops the first 11 tokens; compaction stays.
        assert_eq!(
            sum_tokens(&[events[1].clone(), events[2].clone()]),
            5000 + 200 + 40000 + 12 + 2
        );
    }
}
