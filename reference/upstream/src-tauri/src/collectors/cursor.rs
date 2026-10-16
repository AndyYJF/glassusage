//! Cursor.
//!
//! Cursor does not write readable token counts locally — `state.vscdb` only stores cents
//! — so usage comes from the account API. Three credential shapes are accepted:
//!
//!   A. Access token from Cursor's local `state.vscdb` (channel A)
//!   B. `WorkosCursorSessionToken` cookie pasted from cursor.com (channel B)
//!   C. Team Admin API key from cursor.com/dashboard → API Keys (`key_…`)
//!
//! The dashboard endpoint lives on `cursor.com` (not the old `api2.cursor.sh`, which
//! now 404s). POST calls need an `Origin: https://cursor.com` header or CSRF rejects them.
//! Every failure degrades to a status message on the Cursor tile rather than an error dialog.

use std::path::PathBuf;
use std::sync::Mutex;

use anyhow::{anyhow, Result};
use serde::Deserialize;

use super::*;
use crate::model::{source, surface, UsageEvent};

/// Personal / Pro dashboard (cookie or bearer). Replaces the retired api2.cursor.sh path.
const DASHBOARD_EVENTS_URL: &str = "https://cursor.com/api/dashboard/get-filtered-usage-events";
/// Team Admin API (Basic auth with an API key).
const TEAM_EVENTS_URL: &str = "https://api.cursor.com/teams/filtered-usage-events";
const USAGE_SUMMARY_URL: &str = "https://cursor.com/api/usage-summary";
const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) GlassUsage/0.1";
const ORIGIN: &str = "https://cursor.com";

pub struct CursorCollector;

/// Results fetched by the async poller, handed to the synchronous collector pass.
static PENDING: Mutex<Option<Vec<UsageEvent>>> = Mutex::new(None);
static LAST_ERROR: Mutex<Option<String>> = Mutex::new(None);

pub fn stash_events(events: Vec<UsageEvent>) {
    let mut slot = PENDING.lock().unwrap();
    slot.get_or_insert_with(Vec::new).extend(events);
}

pub fn set_error(msg: Option<String>) {
    *LAST_ERROR.lock().unwrap() = msg;
}

pub fn take_error() -> Option<String> {
    LAST_ERROR.lock().unwrap().clone()
}

impl CursorCollector {
    pub fn state_db(settings: &AppSettings) -> Option<PathBuf> {
        if let Some(custom) = settings.custom_path(source::CURSOR) {
            return Some(custom);
        }
        let p = dirs::config_dir()?
            .join("Cursor")
            .join("User")
            .join("globalStorage")
            .join("state.vscdb");
        p.is_file().then_some(p)
    }

    /// Channel A: lift the access token Cursor already persisted. Opened read-only and
    /// closed immediately so the running editor is never blocked.
    pub fn access_token(settings: &AppSettings) -> Option<String> {
        let db = Self::state_db(settings)?;
        let conn = open_sqlite_ro(&db).ok()?;
        if !table_exists(&conn, "ItemTable") {
            return None;
        }
        let token: Option<String> = conn
            .query_row(
                "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'",
                [],
                |r| r.get(0),
            )
            .ok();
        token
            .map(|t| t.trim().trim_matches('"').to_string())
            .filter(|t| !t.is_empty())
    }
}

impl Collector for CursorCollector {
    fn id(&self) -> &'static str {
        source::CURSOR
    }

    fn label(&self) -> &'static str {
        "Cursor"
    }

    fn detect(&self, settings: &AppSettings) -> Vec<PathBuf> {
        Self::state_db(settings).into_iter().collect()
    }

    /// Nothing local to watch: usage arrives from the account API on a timer.
    fn watch_paths(&self, _settings: &AppSettings) -> Vec<PathBuf> {
        Vec::new()
    }

    fn is_realtime(&self) -> bool {
        false
    }

    fn scan(&self, ctx: &ScanCtx) -> Result<ScanReport> {
        let pending = PENDING.lock().unwrap().take().unwrap_or_default();
        let detected = Self::state_db(ctx.settings)
            .map(|p| vec![p.to_string_lossy().to_string()])
            .unwrap_or_default();

        Ok(ScanReport {
            files_seen: detected.len() as i64,
            detected_paths: detected,
            events: finalize(pending, ctx.pricing),
            skipped: 0,
            states: Vec::new(),
        })
    }
}

// --------------------------------------------------------------------- API client

#[derive(Debug, Deserialize)]
struct UsageEventsResponse {
    #[serde(
        alias = "usageEvents",
        alias = "usage_events",
        alias = "usageEventsDisplay",
        default
    )]
    usage_events: Vec<RawUsageEvent>,
    #[serde(alias = "totalUsageEventsCount", default)]
    total_usage_events_count: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawUsageEvent {
    #[serde(default)]
    timestamp: Option<serde_json::Value>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default, alias = "modelIntent")]
    model_intent: Option<String>,
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    token_usage: Option<RawTokenUsage>,
    #[serde(default)]
    request_id: Option<String>,
    #[serde(default)]
    owning_user: Option<String>,
    #[serde(default)]
    input_tokens: Option<i64>,
    #[serde(default)]
    output_tokens: Option<i64>,
    #[serde(default)]
    cache_read_tokens: Option<i64>,
    #[serde(default)]
    cache_write_tokens: Option<i64>,
    #[serde(default)]
    cost_cents: Option<f64>,
    /// Prefer this when present: model cost + Cursor Token Rate.
    #[serde(default)]
    charged_cents: Option<f64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawTokenUsage {
    #[serde(default)]
    input_tokens: i64,
    #[serde(default)]
    output_tokens: i64,
    #[serde(default)]
    cache_read_tokens: i64,
    #[serde(default)]
    cache_write_tokens: i64,
    #[serde(default)]
    total_cents: Option<f64>,
}

/// Strip common paste mistakes: leading `WorkosCursorSessionToken=`, surrounding quotes,
/// and whitespace. Team API keys are left intact.
pub fn normalize_credential(raw: &str) -> String {
    let mut s = raw.trim().trim_matches('"').trim_matches('\'').to_string();
    // Case-insensitive prefix strip for the cookie name people copy from DevTools.
    let lower = s.to_ascii_lowercase();
    for prefix in [
        "cookie: workoscursorsessiontoken=",
        "workoscursorsessiontoken=",
    ] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            s = s[s.len() - rest.len()..].trim().to_string();
            break;
        }
    }
    s
}

fn looks_like_api_key(s: &str) -> bool {
    let t = s.trim();
    t.starts_with("key_") || t.starts_with("crsr_")
}

/// Pull usage events for a window.
///
/// `pasted` is whatever the user saved in Settings (cookie or team API key). `token` is
/// the optional local Cursor access token. Endpoints are tried in an order that matches
/// how Cursor actually authenticates today.
pub async fn fetch_usage_events(
    token: Option<String>,
    pasted: Option<String>,
    start_ms: i64,
    end_ms: i64,
    instance: &str,
) -> Result<Vec<UsageEvent>> {
    let pasted = pasted
        .map(|s| normalize_credential(&s))
        .filter(|s| !s.is_empty());
    let token = token.filter(|s| !s.is_empty());

    if token.is_none() && pasted.is_none() {
        return Err(anyhow!("no Cursor credential configured"));
    }

    let client = reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(std::time::Duration::from_secs(45))
        .build()?;

    let mut errors = Vec::new();

    // Team Admin API key — Basic auth, numeric dates.
    if let Some(key) = pasted.as_ref().filter(|s| looks_like_api_key(s)) {
        match fetch_pages(
            &client,
            TEAM_EVENTS_URL,
            Auth::Basic(key.clone()),
            start_ms,
            end_ms,
            true,
            instance,
        )
        .await
        {
            Ok(events) => return Ok(events),
            Err(e) => errors.push(format!("team API: {e}")),
        }
    }

    // Session cookie on the current dashboard host.
    if let Some(cookie) = pasted.as_ref().filter(|s| !looks_like_api_key(s)) {
        match fetch_pages(
            &client,
            DASHBOARD_EVENTS_URL,
            Auth::Cookie(cookie.clone()),
            start_ms,
            end_ms,
            false,
            instance,
        )
        .await
        {
            Ok(events) => return Ok(events),
            Err(e) => errors.push(format!("dashboard cookie: {e}")),
        }
    }

    // Local desktop access token as Bearer against the same dashboard host.
    if let Some(t) = &token {
        match fetch_pages(
            &client,
            DASHBOARD_EVENTS_URL,
            Auth::Bearer(t.clone()),
            start_ms,
            end_ms,
            false,
            instance,
        )
        .await
        {
            Ok(events) => return Ok(events),
            Err(e) => errors.push(format!("dashboard bearer: {e}")),
        }
    }

    Err(anyhow!(errors.join(" · ")))
}

enum Auth {
    Cookie(String),
    Bearer(String),
    Basic(String),
}

async fn fetch_pages(
    client: &reqwest::Client,
    url: &str,
    auth: Auth,
    start_ms: i64,
    end_ms: i64,
    numeric_dates: bool,
    instance: &str,
) -> Result<Vec<UsageEvent>> {
    let mut all = Vec::new();
    let mut page = 1i64;
    loop {
        // Personal dashboard wants date strings; the team Admin API wants numbers.
        // Omit teamId entirely for personal — sending 0 can 404 or return an empty team.
        let body = if numeric_dates {
            serde_json::json!({
                "startDate": start_ms,
                "endDate": end_ms,
                "page": page,
                "pageSize": 200,
            })
        } else {
            serde_json::json!({
                "startDate": start_ms.to_string(),
                "endDate": end_ms.to_string(),
                "page": page,
                "pageSize": 200,
            })
        };

        let mut req = client
            .post(url)
            .header("Origin", ORIGIN)
            .header("Referer", "https://cursor.com/dashboard")
            .json(&body);

        match &auth {
            Auth::Cookie(c) => {
                req = req.header("Cookie", format!("WorkosCursorSessionToken={c}"));
            }
            Auth::Bearer(t) => {
                req = req.bearer_auth(t);
            }
            Auth::Basic(k) => {
                req = req.basic_auth(k, Some(""));
            }
        }

        let resp = req.send().await?;
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        if !status.is_success() {
            let snippet: String = text.chars().take(160).collect();
            return Err(anyhow!("HTTP {status}: {snippet}"));
        }

        let parsed: UsageEventsResponse = serde_json::from_str(&text).map_err(|e| {
            anyhow!(
                "parse failed: {e}; body starts {:?}",
                text.chars().take(80).collect::<String>()
            )
        })?;

        let count = parsed.usage_events.len();
        for raw in parsed.usage_events {
            if let Some(e) = to_event(raw, instance) {
                all.push(e);
            }
        }
        if count < 200 || page >= 50 {
            break;
        }
        if let Some(total) = parsed.total_usage_events_count {
            if all.len() as i64 >= total {
                break;
            }
        }
        page += 1;
    }
    Ok(all)
}

/// Plan-level usage summary for the Settings status line.
pub async fn fetch_plan_usage(
    pasted: Option<String>,
    token: Option<String>,
) -> Result<serde_json::Value> {
    let client = reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(std::time::Duration::from_secs(20))
        .build()?;
    let mut req = client.get(USAGE_SUMMARY_URL).header("Origin", ORIGIN);
    if let Some(c) = pasted
        .map(|s| normalize_credential(&s))
        .filter(|s| !s.is_empty() && !looks_like_api_key(s))
    {
        req = req.header("Cookie", format!("WorkosCursorSessionToken={c}"));
    } else if let Some(t) = token {
        req = req.bearer_auth(t);
    } else {
        return Err(anyhow!("no session credential for usage-summary"));
    }
    Ok(req.send().await?.error_for_status()?.json().await?)
}

fn to_event(raw: RawUsageEvent, instance: &str) -> Option<UsageEvent> {
    let usage = raw.token_usage.as_ref();
    let input = usage
        .map(|u| u.input_tokens)
        .or(raw.input_tokens)
        .unwrap_or(0);
    let output = usage
        .map(|u| u.output_tokens)
        .or(raw.output_tokens)
        .unwrap_or(0);
    let cache_read = usage
        .map(|u| u.cache_read_tokens)
        .or(raw.cache_read_tokens)
        .unwrap_or(0);
    let cache_write = usage
        .map(|u| u.cache_write_tokens)
        .or(raw.cache_write_tokens)
        .unwrap_or(0);
    if input + output + cache_read + cache_write == 0 {
        return None;
    }

    let ts = raw
        .timestamp
        .as_ref()
        .and_then(|v| match v {
            serde_json::Value::String(s) => s
                .parse::<f64>()
                .ok()
                .map(normalize_epoch)
                .or_else(|| parse_timestamp(v)),
            other => parse_timestamp(other),
        })
        .unwrap_or_else(crate::store::now_ms);

    let model = raw
        .model
        .or(raw.model_intent)
        .unwrap_or_else(|| "unknown".to_string());

    let dedup_key = raw.request_id.clone().unwrap_or_else(|| {
        sha_key(&[
            &ts.to_string(),
            &model,
            &input.to_string(),
            &output.to_string(),
            &cache_read.to_string(),
            &cache_write.to_string(),
            raw.owning_user.as_deref().unwrap_or(""),
        ])
    });

    let mut e = UsageEvent::new(source::CURSOR, surface::IDE, instance, dedup_key);
    e.model = model;
    e.provider = Some("cursor".into());
    e.timestamp = ts;
    e.input_tokens = input;
    e.output_tokens = output;
    e.cache_read_tokens = cache_read;
    e.cache_write_tokens = cache_write;
    e.session_id = raw.kind.unwrap_or_default();
    // Cursor's chargedCents (model + token rate) is authoritative when present.
    e.cost_usd = raw
        .charged_cents
        .or(usage.and_then(|u| u.total_cents))
        .or(raw.cost_cents)
        .map(|c| c / 100.0);
    Some(e)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_cookie_name_prefix() {
        assert_eq!(
            normalize_credential("WorkosCursorSessionToken=user_abc%3A%3Ajwt"),
            "user_abc%3A%3Ajwt"
        );
        assert_eq!(
            normalize_credential("  user_abc%3A%3Ajwt  "),
            "user_abc%3A%3Ajwt"
        );
    }

    #[test]
    fn detects_team_api_keys() {
        assert!(looks_like_api_key("key_abc123def456ghi789"));
        assert!(!looks_like_api_key("user_01ABC%3A%3AeyJhbGciOi"));
    }
}
