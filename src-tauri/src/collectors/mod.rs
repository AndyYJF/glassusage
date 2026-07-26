//! Collector framework.
//!
//! Every agent implements [`Collector`]. Adding a new agent means adding one file here
//! and one line in [`all_collectors`]; nothing else in the app needs to change.

pub mod antigravity;
pub mod claude;
pub mod codex;
pub mod cursor;
pub mod hermes;
pub mod openclaw;
pub mod opencode;
pub mod protoscan;

use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::Result;

use crate::model::{UsageEvent, LOCAL_INSTANCE};
use crate::pricing::Pricing;
use crate::settings::AppSettings;
use crate::store::{Store, WriteMode};

/// Everything a collector needs for one scan pass.
pub struct ScanCtx<'a> {
    pub store: &'a Store,
    pub pricing: &'a Pricing,
    pub settings: &'a AppSettings,
    /// `"local"` or a remote instance name.
    pub instance: String,
    /// For remote instances, the downloaded snapshot directory to read instead of the
    /// usual home-relative paths.
    pub root_override: Option<PathBuf>,
}

impl<'a> ScanCtx<'a> {
    pub fn local(store: &'a Store, pricing: &'a Pricing, settings: &'a AppSettings) -> Self {
        Self {
            store,
            pricing,
            settings,
            instance: LOCAL_INSTANCE.to_string(),
            root_override: None,
        }
    }
}

#[derive(Debug, Default)]
pub struct ScanReport {
    pub events: Vec<UsageEvent>,
    pub files_seen: i64,
    /// Rows the parser could not understand. Non-zero means possible schema drift.
    pub skipped: i64,
    pub detected_paths: Vec<String>,
}

impl ScanReport {
    pub fn merge(&mut self, other: ScanReport) {
        self.events.extend(other.events);
        self.files_seen += other.files_seen;
        self.skipped += other.skipped;
        self.detected_paths.extend(other.detected_paths);
    }
}

pub trait Collector: Send + Sync {
    fn id(&self) -> &'static str;

    /// Human-readable name for the UI.
    fn label(&self) -> &'static str;

    /// Data roots that exist on this machine. Empty means "agent not installed".
    fn detect(&self, settings: &AppSettings) -> Vec<PathBuf>;

    /// Directories worth attaching a file watcher to. Sources that can only be polled
    /// (Cursor's HTTP API) return an empty list.
    fn watch_paths(&self, settings: &AppSettings) -> Vec<PathBuf> {
        self.detect(settings)
    }

    /// Whether new data shows up within seconds (file watcher) or only on a timer.
    fn is_realtime(&self) -> bool {
        true
    }

    /// How re-read rows reconcile with already-stored ones.
    fn write_mode(&self) -> WriteMode {
        WriteMode::InsertOrIgnore
    }

    /// Read everything new since the stored watermark.
    fn scan(&self, ctx: &ScanCtx) -> Result<ScanReport>;
}

pub fn all_collectors() -> Vec<Arc<dyn Collector>> {
    vec![
        Arc::new(claude::ClaudeCollector),
        Arc::new(codex::CodexCollector),
        Arc::new(cursor::CursorCollector),
        Arc::new(antigravity::AntigravityCollector),
        Arc::new(opencode::OpenCodeCollector),
        Arc::new(hermes::HermesCollector),
        Arc::new(openclaw::OpenClawCollector),
    ]
}

pub fn collector_by_id(id: &str) -> Option<Arc<dyn Collector>> {
    all_collectors().into_iter().find(|c| c.id() == id)
}

// ------------------------------------------------------------------ shared helpers

pub fn home_dir() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

/// Resolve an agent's root: explicit Settings override, then an environment variable the
/// agent itself honours, then the conventional path.
pub fn resolve_root(settings: &AppSettings, source: &str, env_var: Option<&str>, default: PathBuf) -> PathBuf {
    if let Some(p) = settings.custom_path(source) {
        return p;
    }
    if let Some(var) = env_var {
        if let Ok(v) = std::env::var(var) {
            let trimmed = v.trim();
            if !trimmed.is_empty() {
                return PathBuf::from(trimmed);
            }
        }
    }
    default
}

pub fn mtime_ms(path: &Path) -> i64 {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn file_size(path: &Path) -> i64 {
    std::fs::metadata(path).map(|m| m.len() as i64).unwrap_or(0)
}

/// Parse the several timestamp shapes these agents use: RFC3339 strings, epoch seconds,
/// epoch milliseconds, and fractional epoch seconds.
pub fn parse_timestamp(v: &serde_json::Value) -> Option<i64> {
    match v {
        serde_json::Value::String(s) => chrono::DateTime::parse_from_rfc3339(s)
            .ok()
            .map(|d| d.timestamp_millis())
            .or_else(|| {
                chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S%.f")
                    .ok()
                    .map(|d| d.and_utc().timestamp_millis())
            }),
        serde_json::Value::Number(n) => {
            let f = n.as_f64()?;
            Some(normalize_epoch(f))
        }
        _ => None,
    }
}

/// Coerce a numeric epoch of unknown unit into milliseconds.
pub fn normalize_epoch(v: f64) -> i64 {
    if v > 1e17 {
        (v / 1e6) as i64 // nanoseconds
    } else if v > 1e14 {
        (v / 1e3) as i64 // microseconds
    } else if v > 1e11 {
        v as i64 // already milliseconds
    } else {
        (v * 1000.0) as i64 // seconds, possibly fractional
    }
}

/// Turn a working directory into a short project label.
pub fn project_label(cwd: &str) -> Option<String> {
    let cwd = cwd.trim().trim_end_matches(['/', '\\']);
    if cwd.is_empty() {
        return None;
    }
    Path::new(cwd)
        .file_name()
        .and_then(|s| s.to_str())
        .map(|s| s.to_string())
        .or_else(|| Some(cwd.to_string()))
}

/// Fill in `model_norm` and `cost_usd`, then drop zero-token rows.
pub fn finalize(events: Vec<UsageEvent>, pricing: &Pricing) -> Vec<UsageEvent> {
    events
        .into_iter()
        .filter(|e| !e.is_empty())
        .map(|mut e| {
            if e.model_norm.is_empty() {
                e.model_norm = pricing.normalize(&e.model);
            }
            if e.cost_usd.is_none() {
                e.cost_usd = pricing.cost(
                    &e.model_norm,
                    e.input_tokens,
                    e.output_tokens,
                    e.cache_read_tokens,
                    e.cache_write_tokens,
                );
            }
            e
        })
        .collect()
}

/// Open someone else's SQLite database without any chance of writing to it.
///
/// `mode=ro` plus a busy timeout is the combination that survives the owning agent
/// holding a write lock. WAL files are left in place so rusqlite can replay them.
pub fn open_sqlite_ro(path: &Path) -> Result<rusqlite::Connection> {
    use rusqlite::OpenFlags;
    let conn = rusqlite::Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    conn.busy_timeout(std::time::Duration::from_secs(2))?;
    Ok(conn)
}

/// True when the table exists, so a schema change downgrades to "no data" rather than
/// an error banner.
pub fn table_exists(conn: &rusqlite::Connection, table: &str) -> bool {
    conn.query_row(
        "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = ?1",
        [table],
        |_| Ok(()),
    )
    .is_ok()
}

pub fn column_exists(conn: &rusqlite::Connection, table: &str, column: &str) -> bool {
    let mut stmt = match conn.prepare(&format!("PRAGMA table_info(\"{table}\")")) {
        Ok(s) => s,
        Err(_) => return false,
    };
    // The result has to be produced while `stmt` is still alive, since the row iterator
    // borrows it.
    let found = match stmt.query_map([], |r| r.get::<_, String>(1)) {
        Ok(rows) => rows
            .filter_map(|r| r.ok())
            .any(|c| c.eq_ignore_ascii_case(column)),
        Err(_) => false,
    };
    found
}

/// One incremental read of an append-only JSONL file.
pub struct JsonlChunk {
    /// `(absolute line number, line text)` for every **complete** line added since the
    /// last read. A trailing partial line is deliberately left for the next pass.
    pub lines: Vec<(i64, String)>,
    pub new_offset: i64,
    pub new_line_no: i64,
    pub mtime_ms: i64,
}

/// Read the bytes appended to a JSONL file since its stored watermark.
///
/// Rotation and truncation are detected by comparing the stored offset against the
/// current size; when the file shrank, the watermark resets and the file is re-read.
/// Since the writer may be mid-line, only content up to the final newline is consumed.
pub fn read_new_lines(store: &Store, source: &str, instance: &str, path: &Path) -> Result<JsonlChunk> {
    use std::io::{Read, Seek, SeekFrom};

    let key = path.to_string_lossy().to_string();
    let state = store.get_scan_state(source, instance, &key).unwrap_or_default();
    let size = file_size(path);
    let mtime = mtime_ms(path);

    let (mut offset, mut line_no) = if size < state.offset {
        (0, 0)
    } else {
        (
            state.offset,
            state.extra.as_deref().and_then(|s| s.parse::<i64>().ok()).unwrap_or(0),
        )
    };

    if offset >= size {
        return Ok(JsonlChunk {
            lines: Vec::new(),
            new_offset: offset,
            new_line_no: line_no,
            mtime_ms: mtime,
        });
    }

    let mut f = std::fs::File::open(path)?;
    f.seek(SeekFrom::Start(offset as u64))?;
    let mut buf = Vec::with_capacity((size - offset).clamp(0, 64 * 1024 * 1024) as usize);
    f.take((size - offset) as u64).read_to_end(&mut buf)?;

    let last_newline = match buf.iter().rposition(|b| *b == b'\n') {
        Some(i) => i + 1,
        None => {
            // Nothing but a partial line so far; wait for the writer to finish it.
            return Ok(JsonlChunk {
                lines: Vec::new(),
                new_offset: offset,
                new_line_no: line_no,
                mtime_ms: mtime,
            });
        }
    };
    let consumed = &buf[..last_newline];
    offset += last_newline as i64;

    let mut lines = Vec::new();
    for raw in String::from_utf8_lossy(consumed).lines() {
        line_no += 1;
        let t = raw.trim();
        if !t.is_empty() {
            lines.push((line_no, t.to_string()));
        }
    }

    Ok(JsonlChunk {
        lines,
        new_offset: offset,
        new_line_no: line_no,
        mtime_ms: mtime,
    })
}

pub fn commit_scan_state(store: &Store, source: &str, instance: &str, path: &Path, chunk: &JsonlChunk) {
    let key = path.to_string_lossy().to_string();
    let _ = store.set_scan_state(
        source,
        instance,
        &key,
        &crate::model::ScanState {
            offset: chunk.new_offset,
            mtime_ms: chunk.mtime_ms,
            extra: Some(chunk.new_line_no.to_string()),
        },
    );
}

/// Recursively list files under `root` whose name matches `pred`.
pub fn find_files(root: &Path, pred: impl Fn(&Path) -> bool) -> Vec<PathBuf> {
    if !root.exists() {
        return Vec::new();
    }
    walkdir::WalkDir::new(root)
        .follow_links(false)
        .max_depth(8)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .map(|e| e.into_path())
        .filter(|p| pred(p))
        .collect()
}

pub fn has_ext(p: &Path, ext: &str) -> bool {
    p.extension().and_then(|e| e.to_str()).map(|e| e.eq_ignore_ascii_case(ext)).unwrap_or(false)
}

pub fn file_stem(p: &Path) -> String {
    p.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string()
}

pub fn sha_key(parts: &[&str]) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    for p in parts {
        h.update(p.as_bytes());
        h.update([0u8]);
    }
    let digest = h.finalize();
    digest[..12].iter().map(|b| format!("{b:02x}")).collect()
}
