//! Normalized data model shared by every collector and the IPC layer.

use serde::{Deserialize, Serialize};

/// Stable identifiers for each supported agent. Kept as `&'static str` on the wire so
/// the frontend can use them directly as object keys and icon lookups.
pub mod source {
    pub const CLAUDE: &str = "claude";
    pub const CODEX: &str = "codex";
    pub const CURSOR: &str = "cursor";
    pub const ANTIGRAVITY: &str = "antigravity";
    pub const OPENCODE: &str = "opencode";
    pub const HERMES: &str = "hermes";
    pub const OPENCLAW: &str = "openclaw";
    pub const PI: &str = "pi";
    pub const KIMI: &str = "kimi";

    pub const ALL: &[&str] = &[
        CLAUDE,
        CODEX,
        CURSOR,
        ANTIGRAVITY,
        OPENCODE,
        HERMES,
        OPENCLAW,
        PI,
        KIMI,
    ];
}

/// Which shape of the product produced the event. Purely a label: the same underlying
/// transcript is never counted twice just because two surfaces can read it.
pub mod surface {
    pub const CLI: &str = "cli";
    pub const DESKTOP: &str = "desktop";
    pub const IDE: &str = "ide";
    pub const CLOUD: &str = "cloud";
}

pub const LOCAL_INSTANCE: &str = "local";

/// A single billable interaction, normalized across all sources.
///
/// `reasoning_tokens` is a **subset** of `output_tokens` for every source that reports
/// it (Codex `reasoning_output_tokens`, OpenCode `tokens.reasoning`, Antigravity field 9),
/// so it is never added into the total. See [`UsageEvent::total_tokens`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageEvent {
    pub source: String,
    pub surface: String,
    pub instance: String,
    pub session_id: String,
    pub project: Option<String>,
    pub model: String,
    pub model_norm: String,
    pub provider: Option<String>,
    pub timestamp: i64,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_write_tokens: i64,
    pub reasoning_tokens: i64,
    pub cost_usd: Option<f64>,
    pub dedup_key: String,
}

impl UsageEvent {
    pub fn new(source: &str, surface: &str, instance: &str, dedup_key: String) -> Self {
        Self {
            source: source.to_string(),
            surface: surface.to_string(),
            instance: instance.to_string(),
            session_id: String::new(),
            project: None,
            model: String::new(),
            model_norm: String::new(),
            provider: None,
            timestamp: 0,
            input_tokens: 0,
            output_tokens: 0,
            cache_read_tokens: 0,
            cache_write_tokens: 0,
            reasoning_tokens: 0,
            cost_usd: None,
            dedup_key,
        }
    }

    /// Billable token total. Reasoning is excluded because every upstream source reports
    /// it as a component of `output_tokens`; adding it would double count.
    pub fn total_tokens(&self) -> i64 {
        self.input_tokens + self.output_tokens + self.cache_read_tokens + self.cache_write_tokens
    }

    pub fn is_empty(&self) -> bool {
        self.total_tokens() == 0
    }
}

/// Incremental watermark for one file or database.
#[derive(Debug, Clone, Default)]
pub struct ScanState {
    pub offset: i64,
    pub mtime_ms: i64,
    pub extra: Option<String>,
}

/// A watermark that must advance only after the events discovered by the same scan have
/// been persisted. Keeping this alongside [`UsageEvent`] lets the store commit both in one
/// SQLite transaction, so a disk/full/schema error cannot make a later scan skip data.
#[derive(Debug, Clone)]
pub struct PendingScanState {
    pub source: String,
    pub instance: String,
    pub key: String,
    pub state: ScanState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HealthStatus {
    /// File watcher attached, updates arrive within seconds.
    Live,
    /// Detected, but refreshed on a timer.
    Polling,
    /// Data directory not found on this machine.
    Missing,
    /// Detected but the last scan failed.
    Error,
    /// Turned off by the user in Settings.
    Disabled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceHealth {
    pub source: String,
    pub instance: String,
    pub status: HealthStatus,
    pub detected_paths: Vec<String>,
    pub file_count: i64,
    pub event_count: i64,
    pub last_scan_ms: Option<i64>,
    pub last_event_ms: Option<i64>,
    pub last_error: Option<String>,
    /// Rows the parser had to skip (bad JSON, unknown schema). Surfaced so schema drift
    /// shows up as a warning instead of silently under-reporting.
    pub skipped_rows: i64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenBreakdown {
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_write_tokens: i64,
    pub reasoning_tokens: i64,
    pub total_tokens: i64,
    pub cost_usd: f64,
    pub events: i64,
    /// Events whose model has no known price. `cost_usd` excludes them, so a caller must
    /// show this to avoid presenting an understated total as if it were complete.
    #[serde(default)]
    pub unpriced_events: i64,
}

impl Default for TokenBreakdown {
    fn default() -> Self {
        Self {
            input_tokens: 0,
            output_tokens: 0,
            cache_read_tokens: 0,
            cache_write_tokens: 0,
            reasoning_tokens: 0,
            total_tokens: 0,
            cost_usd: 0.0,
            events: 0,
            unpriced_events: 0,
        }
    }
}

impl TokenBreakdown {
    /// Share of input that was served from cache rather than re-processed.
    pub fn cache_hit_rate(&self) -> f64 {
        let denom = self.input_tokens + self.cache_read_tokens + self.cache_write_tokens;
        if denom == 0 {
            0.0
        } else {
            self.cache_read_tokens as f64 / denom as f64
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimeRange {
    pub from: i64,
    pub to: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeriesPoint {
    pub bucket: i64,
    pub key: String,
    #[serde(flatten)]
    pub totals: TokenBreakdown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageRow {
    pub id: i64,
    pub ts_ms: i64,
    pub source: String,
    pub surface: String,
    pub instance: String,
    pub provider: Option<String>,
    pub model: String,
    pub model_norm: String,
    pub project: Option<String>,
    pub session_id: String,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_write_tokens: i64,
    pub reasoning_tokens: i64,
    pub cost_usd: Option<f64>,
    /// True when no price entry matched, so cost is displayed greyed out.
    pub unpriced: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UsageFilter {
    pub from: Option<i64>,
    pub to: Option<i64>,
    pub sources: Option<Vec<String>>,
    pub instances: Option<Vec<String>>,
    pub providers: Option<Vec<String>>,
    pub models: Option<Vec<String>>,
    pub search: Option<String>,
    /// When true, only rows with `cost_usd IS NULL`.
    pub unpriced_only: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MonthlyStat {
    pub month: String,
    #[serde(flatten)]
    pub totals: TokenBreakdown,
    pub by_source: Vec<GroupStat>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Page<T> {
    pub rows: Vec<T>,
    pub total: i64,
    pub page: i64,
    pub page_size: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GroupStat {
    pub key: String,
    pub label: String,
    #[serde(flatten)]
    pub totals: TokenBreakdown,
    pub share: f64,
    pub unpriced: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OverviewStats {
    pub today: TokenBreakdown,
    pub yesterday: TokenBreakdown,
    pub this_week: TokenBreakdown,
    pub last_week: TokenBreakdown,
    pub range: TokenBreakdown,
    pub per_source: Vec<GroupStat>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentStats {
    pub source: String,
    pub totals: TokenBreakdown,
    pub per_model: Vec<GroupStat>,
    pub per_project: Vec<GroupStat>,
    pub per_instance: Vec<GroupStat>,
    /// (day `YYYY-MM-DD`, total tokens) for the calendar heat map.
    pub calendar: Vec<(String, i64)>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct LiveRates {
    pub rpm: f64,
    pub tpm: f64,
    pub cost_today: f64,
    pub tokens_today: i64,
    pub per_source: Vec<LiveSource>,
    /// 60 one-second buckets of token counts, oldest first, for the sparkline.
    pub spark60: Vec<i64>,
    /// Today's cost scoped to the budget-alert agent list (all agents when empty).
    #[serde(default)]
    pub budget_cost_today: f64,
    /// Today's tokens scoped to the budget-alert agent list.
    #[serde(default)]
    pub budget_tokens_today: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveSource {
    pub source: String,
    pub rpm: f64,
    pub tpm: f64,
    /// True when the source produced an event in the last 5 minutes.
    pub active: bool,
    /// Polling sources get a different indicator animation, since their events arrive
    /// in batches and the instantaneous rate is backfilled from event timestamps.
    pub polling: bool,
}
