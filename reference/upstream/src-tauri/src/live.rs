//! Sliding-window RPM / TPM used by the mini card and the dashboard header.
//!
//! Windows are keyed on **event timestamps**, not ingest time. That is what keeps a
//! backfill honest: importing a year of history adds thousands of rows at once, but
//! their timestamps fall outside the 60-second window so the displayed rate stays flat.

use std::collections::{HashMap, VecDeque};

use parking_lot::Mutex;

use crate::model::{LiveRates, LiveSource};
use crate::store::LiveDelta;

const WINDOW_MS: i64 = 60_000;
const ACTIVE_MS: i64 = 5 * 60_000;
/// Smoothing factor for a ~5s exponential moving average at the 2s tick rate.
const EMA_ALPHA: f64 = 0.4;

struct Entry {
    ts_ms: i64,
    tokens: i64,
    source: String,
    is_request: bool,
}

pub struct LiveTracker {
    inner: Mutex<Inner>,
}

struct Inner {
    events: VecDeque<Entry>,
    /// Last event time per source, for the activity dots.
    last_seen: HashMap<String, i64>,
    polling_sources: Vec<String>,
    smoothed_rpm: f64,
    smoothed_tpm: f64,
    smoothed_per_source: HashMap<String, (f64, f64)>,
    cost_today: f64,
    tokens_today: i64,
}

impl LiveTracker {
    pub fn new(polling_sources: Vec<String>) -> Self {
        Self {
            inner: Mutex::new(Inner {
                events: VecDeque::new(),
                last_seen: HashMap::new(),
                polling_sources,
                smoothed_rpm: 0.0,
                smoothed_tpm: 0.0,
                smoothed_per_source: HashMap::new(),
                cost_today: 0.0,
                tokens_today: 0,
            }),
        }
    }

    pub fn push(&self, deltas: &[LiveDelta]) {
        let mut inner = self.inner.lock();
        for d in deltas {
            if d.tokens <= 0 && !d.is_new_request {
                continue;
            }
            // Backfilled events can arrive out of order, so keep the newest timestamp.
            let seen = inner.last_seen.entry(d.source.clone()).or_insert(d.ts_ms);
            *seen = (*seen).max(d.ts_ms);
            inner.events.push_back(Entry {
                ts_ms: d.ts_ms,
                tokens: d.tokens,
                source: d.source.clone(),
                is_request: d.is_new_request,
            });
        }
        // Keep the deque from growing without bound during a large backfill.
        let cutoff = now_ms() - WINDOW_MS;
        while inner.events.len() > 20_000
            || inner
                .events
                .front()
                .is_some_and(|e| e.ts_ms < cutoff - WINDOW_MS)
        {
            if inner.events.pop_front().is_none() {
                break;
            }
        }
    }

    pub fn set_today_totals(&self, tokens: i64, cost: f64) {
        let mut inner = self.inner.lock();
        inner.tokens_today = tokens;
        inner.cost_today = cost;
    }

    /// Recompute the window and return the smoothed rates.
    pub fn tick(&self) -> LiveRates {
        let mut inner = self.inner.lock();
        let now = now_ms();
        let cutoff = now - WINDOW_MS;

        while inner.events.front().is_some_and(|e| e.ts_ms < cutoff) {
            inner.events.pop_front();
        }

        let mut requests = 0f64;
        let mut tokens = 0f64;
        let mut per_source_raw: HashMap<String, (f64, f64)> = HashMap::new();
        let mut spark = vec![0i64; 60];

        for e in &inner.events {
            // Events dated in the future (clock skew between machines) still count, but
            // are clamped into the newest bucket.
            if e.ts_ms > now + WINDOW_MS {
                continue;
            }
            if e.is_request {
                requests += 1.0;
            }
            tokens += e.tokens as f64;
            let slot = per_source_raw.entry(e.source.clone()).or_insert((0.0, 0.0));
            if e.is_request {
                slot.0 += 1.0;
            }
            slot.1 += e.tokens as f64;

            let bucket = (((e.ts_ms - cutoff) / 1000).clamp(0, 59)) as usize;
            spark[bucket] += e.tokens;
        }

        inner.smoothed_rpm = ema(inner.smoothed_rpm, requests);
        inner.smoothed_tpm = ema(inner.smoothed_tpm, tokens);

        let mut per_source = Vec::new();
        let known: Vec<String> = crate::model::source::ALL
            .iter()
            .map(|s| s.to_string())
            .collect();
        for source in known {
            let raw = per_source_raw.get(&source).copied().unwrap_or((0.0, 0.0));
            let entry = inner
                .smoothed_per_source
                .entry(source.clone())
                .or_insert((0.0, 0.0));
            entry.0 = ema(entry.0, raw.0);
            entry.1 = ema(entry.1, raw.1);
            let (rpm, tpm) = *entry;
            let active = inner
                .last_seen
                .get(&source)
                .map(|t| now - *t < ACTIVE_MS)
                .unwrap_or(false);
            per_source.push(LiveSource {
                polling: inner.polling_sources.contains(&source),
                source,
                rpm,
                tpm,
                active,
            });
        }

        LiveRates {
            rpm: round1(inner.smoothed_rpm),
            tpm: round1(inner.smoothed_tpm),
            cost_today: inner.cost_today,
            tokens_today: inner.tokens_today,
            per_source,
            spark60: spark,
            budget_cost_today: inner.cost_today,
            budget_tokens_today: inner.tokens_today,
        }
    }

    /// Seed the window from the database so the first tick after launch is meaningful.
    pub fn warm_up(&self, rows: &[(i64, String, i64)]) {
        let deltas: Vec<LiveDelta> = rows
            .iter()
            .map(|(ts, source, tokens)| LiveDelta {
                ts_ms: *ts,
                source: source.clone(),
                tokens: *tokens,
                is_new_request: true,
            })
            .collect();
        self.push(&deltas);
    }
}

/// Decay toward zero instead of snapping, so an idle indicator fades over ~2s.
fn ema(prev: f64, next: f64) -> f64 {
    let v = prev + EMA_ALPHA * (next - prev);
    if v.abs() < 0.05 {
        0.0
    } else {
        v
    }
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}
