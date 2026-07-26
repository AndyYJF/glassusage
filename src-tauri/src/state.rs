//! Shared application state and the single ingestion path every scan goes through.

use std::path::PathBuf;
use std::sync::Arc;

use parking_lot::Mutex;
use serde::Serialize;
use tauri::{AppHandle, Emitter};

use crate::collectors::{self, Collector, ScanCtx};
use crate::live::LiveTracker;
use crate::model::{source, HealthStatus, LiveRates, SourceHealth, LOCAL_INSTANCE};
use crate::pricing::Pricing;
use crate::settings::SettingsStore;
use crate::store::Store;

pub struct AppState {
    pub store: Arc<Store>,
    pub pricing: Arc<Pricing>,
    pub settings: Arc<SettingsStore>,
    pub live: Arc<LiveTracker>,
    pub data_dir: PathBuf,
    /// Serializes scans so two triggers cannot interleave on the same watermark.
    scan_lock: Mutex<()>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct UsageUpdated {
    source: String,
    instance: String,
    added: usize,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SourceStatusEvent {
    pub source: String,
    pub instance: String,
    pub status: HealthStatus,
    pub error: Option<String>,
}

impl AppState {
    pub fn new(data_dir: PathBuf) -> anyhow::Result<Self> {
        std::fs::create_dir_all(&data_dir).ok();
        let store = Arc::new(Store::open(&data_dir.join("usage.db"))?);
        let pricing = Arc::new(Pricing::new(&data_dir));
        let settings = Arc::new(SettingsStore::load(&data_dir));

        let polling: Vec<String> = collectors::all_collectors()
            .iter()
            .filter(|c| !c.is_realtime())
            .map(|c| c.id().to_string())
            .collect();
        let live = Arc::new(LiveTracker::new(polling));

        // Seed the rate window so the mini card is not blank for the first minute.
        if let Ok(rows) = store.recent_events(chrono::Utc::now().timestamp_millis() - 120_000) {
            live.warm_up(&rows);
        }

        Ok(Self {
            store,
            pricing,
            settings,
            live,
            data_dir,
            scan_lock: Mutex::new(()),
        })
    }

    /// Run one collector and publish the result.
    ///
    /// Errors are recorded against the source and surfaced through `source-status`;
    /// they never propagate far enough to interrupt other collectors.
    pub fn run_scan(&self, app: &AppHandle, source_id: &str, root_override: Option<PathBuf>) {
        let Some(collector) = collectors::collector_by_id(source_id) else {
            return;
        };
        let settings = self.settings.get();
        if !settings.source_enabled(source_id) {
            return;
        }
        let _guard = self.scan_lock.lock();

        let instance = LOCAL_INSTANCE.to_string();
        let ctx = ScanCtx {
            store: &self.store,
            pricing: &self.pricing,
            settings: &settings,
            instance: instance.clone(),
            root_override,
        };

        match collector.scan(&ctx) {
            Ok(report) => {
                let outcome = self
                    .store
                    .insert_events(&report.events, collector.write_mode())
                    .unwrap_or_default();

                self.live.push(&outcome.deltas);
                let _ = self.store.record_status(
                    source_id,
                    &instance,
                    report.files_seen,
                    report.skipped,
                    &report.detected_paths,
                    None,
                );

                if outcome.changed > 0 {
                    self.refresh_today_totals();
                    let _ = app.emit(
                        "usage-updated",
                        UsageUpdated {
                            source: source_id.to_string(),
                            instance: instance.clone(),
                            added: outcome.changed,
                        },
                    );
                }
                let status = if report.detected_paths.is_empty() {
                    HealthStatus::Missing
                } else if collector.is_realtime() {
                    HealthStatus::Live
                } else {
                    HealthStatus::Polling
                };
                let _ = app.emit(
                    "source-status",
                    SourceStatusEvent {
                        source: source_id.to_string(),
                        instance,
                        status,
                        error: None,
                    },
                );
            }
            Err(e) => {
                let msg = e.to_string();
                tracing::warn!("scan {source_id} failed: {msg}");
                let _ = self
                    .store
                    .record_status(source_id, &instance, 0, 0, &[], Some(&msg));
                let _ = app.emit(
                    "source-status",
                    SourceStatusEvent {
                        source: source_id.to_string(),
                        instance,
                        status: HealthStatus::Error,
                        error: Some(msg),
                    },
                );
            }
        }
    }

    pub fn scan_all(&self, app: &AppHandle) {
        for collector in collectors::all_collectors() {
            self.run_scan(app, collector.id(), None);
        }
    }

    /// Pull new Cursor usage over HTTP, then let the collector pass adopt the results.
    pub async fn sync_cursor(&self, app: &AppHandle) {
        use crate::collectors::cursor::{self as cursor_api, CursorCollector};

        let settings = self.settings.get();
        let token = CursorCollector::access_token(&settings);
        let cookie = self.cursor_cookie();
        if token.is_none() && cookie.is_none() {
            cursor_api::set_error(Some(
                "No Cursor credential found. Sign in to Cursor, or paste a session token in Settings.".into(),
            ));
            let _ = app.emit(
                "source-status",
                SourceStatusEvent {
                    source: source::CURSOR.into(),
                    instance: LOCAL_INSTANCE.into(),
                    status: HealthStatus::Missing,
                    error: cursor_api::take_error(),
                },
            );
            return;
        }

        // Resume from the stored watermark, with a small overlap so an event that landed
        // during the previous request is not missed. Duplicates are filtered by dedup key.
        let key = "api:usage-events";
        let state = self.store.get_scan_state(source::CURSOR, LOCAL_INSTANCE, key);
        let now = chrono::Utc::now().timestamp_millis();
        let start = state
            .as_ref()
            .map(|s| (s.offset - 5 * 60_000).max(0))
            .filter(|s| *s > 0)
            .unwrap_or(now - 30 * 24 * 3600 * 1000);

        match cursor_api::fetch_usage_events(token, cookie, start, now, LOCAL_INSTANCE).await {
            Ok(events) => {
                cursor_api::set_error(None);
                let count = events.len();
                cursor_api::stash_events(events);
                let _ = self.store.set_scan_state(
                    source::CURSOR,
                    LOCAL_INSTANCE,
                    key,
                    &crate::model::ScanState {
                        offset: now,
                        mtime_ms: now,
                        extra: Some(count.to_string()),
                    },
                );
                self.run_scan(app, source::CURSOR, None);
            }
            Err(e) => {
                // The dashboard API is private and can change without notice; the tile
                // shows a degraded state rather than the app treating this as fatal.
                let msg = format!("Cursor account API unavailable: {e}");
                cursor_api::set_error(Some(msg.clone()));
                let _ = self
                    .store
                    .record_status(source::CURSOR, LOCAL_INSTANCE, 0, 0, &[], Some(&msg));
                let _ = app.emit(
                    "source-status",
                    SourceStatusEvent {
                        source: source::CURSOR.into(),
                        instance: LOCAL_INSTANCE.into(),
                        status: HealthStatus::Error,
                        error: Some(msg),
                    },
                );
            }
        }
    }

    pub fn cursor_cookie(&self) -> Option<String> {
        let path = self.data_dir.join("cursor-token.bin");
        let bytes = std::fs::read(path).ok()?;
        crate::dpapi::unprotect_str(&bytes).ok()
    }

    pub fn set_cursor_cookie(&self, token: &str) -> anyhow::Result<()> {
        use crate::collectors::cursor::normalize_credential;
        let path = self.data_dir.join("cursor-token.bin");
        let cleaned = normalize_credential(token);
        if cleaned.is_empty() {
            std::fs::remove_file(path).ok();
            return Ok(());
        }
        std::fs::write(path, crate::dpapi::protect_str(&cleaned)?)?;
        Ok(())
    }

    fn refresh_today_totals(&self) {
        let (from, to) = crate::store::day_bounds(0);
        if let Ok(t) = self.store.totals_in_range(from, to) {
            self.live.set_today_totals(t.total_tokens, t.cost_usd);
        }
    }

    pub fn live_rates(&self) -> LiveRates {
        self.refresh_today_totals();
        self.live.tick()
    }

    /// Merge stored status rows with live detection so sources that have never been
    /// scanned still appear in Settings with an accurate state.
    pub fn health(&self) -> Vec<SourceHealth> {
        let settings = self.settings.get();
        let stored = self.store.source_health().unwrap_or_default();
        let mut out: Vec<SourceHealth> = Vec::new();

        for collector in collectors::all_collectors() {
            let id = collector.id();
            let detected = collector.detect(&settings);
            let existing = stored
                .iter()
                .find(|h| h.source == id && h.instance == LOCAL_INSTANCE)
                .cloned();

            let mut health = existing.unwrap_or(SourceHealth {
                source: id.to_string(),
                instance: LOCAL_INSTANCE.to_string(),
                status: HealthStatus::Missing,
                detected_paths: Vec::new(),
                file_count: 0,
                event_count: 0,
                last_scan_ms: None,
                last_event_ms: None,
                last_error: None,
                skipped_rows: 0,
            });

            if health.detected_paths.is_empty() {
                health.detected_paths = detected.iter().map(|p| p.to_string_lossy().to_string()).collect();
            }
            health.status = if !settings.source_enabled(id) {
                HealthStatus::Disabled
            } else if health.last_error.is_some() {
                HealthStatus::Error
            } else if detected.is_empty() && health.event_count == 0 {
                HealthStatus::Missing
            } else if collector.is_realtime() {
                HealthStatus::Live
            } else {
                HealthStatus::Polling
            };
            out.push(health);
        }

        // Remote instances keep their stored rows; derive status from the last sync.
        out.extend(stored.into_iter().filter(|h| h.instance != LOCAL_INSTANCE).map(|mut h| {
            h.status = if h.last_error.is_some() {
                HealthStatus::Error
            } else if h.detected_paths.is_empty() && h.event_count == 0 {
                HealthStatus::Missing
            } else {
                // SSH pulls are always on a timer, even for agents that are realtime locally.
                HealthStatus::Polling
            };
            h
        }));
        out
    }

    pub fn collectors(&self) -> Vec<Arc<dyn Collector>> {
        collectors::all_collectors()
    }
}
