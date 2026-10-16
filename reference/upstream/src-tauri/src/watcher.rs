//! Scan scheduling: file watchers for the log-based sources, timers for the rest.
//!
//! All ingestion funnels through [`AppState::run_scan`] so deduplication, pricing and
//! event emission behave identically whether a scan was triggered by a file change, the
//! fallback timer, or a manual rescan from the UI.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use parking_lot::Mutex;
use tauri::{AppHandle, Emitter};

use crate::state::AppState;

/// Coalescing window for filesystem noise. An agent writing a streamed response touches
/// its transcript many times per second; 800ms turns that into one scan.
const DEBOUNCE: Duration = Duration::from_millis(800);

pub struct WatchHandle {
    _manager: std::thread::JoinHandle<()>,
}

pub fn start(app: AppHandle, state: Arc<AppState>) -> WatchHandle {
    let dirty = Arc::new(Mutex::new(HashSet::<String>::new()));
    let pending = Arc::new(AtomicBool::new(false));

    let (reconfigure_tx, reconfigure_rx) = std::sync::mpsc::channel();
    let _ = RECONFIGURE.set(reconfigure_tx);
    let manager_state = state.clone();
    let manager_dirty = dirty.clone();
    let manager_pending = pending.clone();
    let manager = std::thread::spawn(move || {
        let mut watcher = build_watcher(
            &manager_state,
            manager_dirty.clone(),
            manager_pending.clone(),
        );
        while reconfigure_rx.recv().is_ok() {
            watcher = build_watcher(
                &manager_state,
                manager_dirty.clone(),
                manager_pending.clone(),
            );
        }
        drop(watcher);
    });

    spawn_debounce_loop(app.clone(), state.clone(), dirty, pending);
    spawn_fallback_timer(app.clone(), state.clone());
    spawn_cursor_poller(app.clone(), state.clone());
    spawn_live_ticker(app.clone(), state.clone());
    crate::remote::spawn_scheduler(app, state);

    WatchHandle { _manager: manager }
}

static RECONFIGURE: OnceLock<std::sync::mpsc::Sender<()>> = OnceLock::new();

pub fn request_reconfigure() {
    if let Some(sender) = RECONFIGURE.get() {
        let _ = sender.send(());
    }
}

fn build_watcher(
    state: &Arc<AppState>,
    dirty: Arc<Mutex<HashSet<String>>>,
    pending: Arc<AtomicBool>,
) -> Option<RecommendedWatcher> {
    let settings = state.settings.get();
    let mut paths: Vec<(String, PathBuf)> = Vec::new();
    for collector in crate::collectors::all_collectors() {
        if !settings.source_enabled(collector.id()) {
            continue;
        }
        for p in collector.watch_paths(&settings) {
            if p.is_dir() {
                paths.push((collector.id().to_string(), p));
            }
        }
    }
    if paths.is_empty() {
        return None;
    }

    let route = paths.clone();
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        let Ok(event) = res else { return };
        if !matches!(
            event.kind,
            notify::EventKind::Create(_)
                | notify::EventKind::Modify(_)
                | notify::EventKind::Remove(_)
        ) {
            return;
        }
        let mut marked = false;
        for changed in &event.paths {
            for (source, root) in &route {
                if changed.starts_with(root) {
                    dirty.lock().insert(source.clone());
                    marked = true;
                }
            }
        }
        if marked {
            pending.store(true, Ordering::Relaxed);
        }
    })
    .ok()?;

    for (_, path) in &paths {
        if let Err(e) = watcher.watch(path, RecursiveMode::Recursive) {
            tracing::warn!("watch {} failed: {e}", path.display());
        }
    }
    Some(watcher)
}

fn spawn_debounce_loop(
    app: AppHandle,
    state: Arc<AppState>,
    dirty: Arc<Mutex<HashSet<String>>>,
    pending: Arc<AtomicBool>,
) {
    std::thread::spawn(move || {
        let mut last_change: Option<Instant> = None;
        loop {
            std::thread::sleep(Duration::from_millis(150));
            if pending.swap(false, Ordering::Relaxed) {
                last_change = Some(Instant::now());
            }
            let Some(t) = last_change else { continue };
            if t.elapsed() < DEBOUNCE {
                continue;
            }
            last_change = None;

            let sources: Vec<String> = {
                let mut d = dirty.lock();
                d.drain().collect()
            };
            for source in sources {
                state.run_scan(&app, &source, None);
            }
        }
    });
}

/// Catches anything the watcher missed: network drives, editors that replace files
/// atomically, and sources with no watchable directory.
fn spawn_fallback_timer(app: AppHandle, state: Arc<AppState>) {
    std::thread::spawn(move || loop {
        let secs = state.settings.get().poll_secs.clamp(15, 3600);
        std::thread::sleep(Duration::from_secs(secs));
        state.scan_all(&app);
    });
}

/// Cursor has no local token log, so it is polled over HTTP on its own slower cadence.
fn spawn_cursor_poller(app: AppHandle, state: Arc<AppState>) {
    tauri::async_runtime::spawn(async move {
        // Let the first local scan finish before adding network work.
        tokio::time::sleep(Duration::from_secs(3)).await;
        loop {
            let settings = state.settings.get();
            if settings.source_enabled(crate::model::source::CURSOR) {
                state.sync_cursor(&app).await;
            }
            let secs = settings.cursor_poll_secs.clamp(60, 3600);
            tokio::time::sleep(Duration::from_secs(secs)).await;
        }
    });
}

/// Emits `live-rates`. The cadence drops to 10s when only the main window is open and
/// pauses entirely when everything is hidden, which is what keeps the always-on-top
/// mini card under the CPU budget.
fn spawn_live_ticker(app: AppHandle, state: Arc<AppState>) {
    tauri::async_runtime::spawn(async move {
        loop {
            let (widget_visible, main_visible) = window_visibility(&app);
            let interval = if widget_visible {
                Duration::from_secs(2)
            } else if main_visible {
                Duration::from_secs(10)
            } else {
                tokio::time::sleep(Duration::from_secs(5)).await;
                continue;
            };

            let rates = state.live.tick();
            let _ = app.emit("live-rates", &rates);
            tokio::time::sleep(interval).await;
        }
    });
}

fn window_visibility(app: &AppHandle) -> (bool, bool) {
    use tauri::Manager;
    let vis = |label: &str| {
        app.get_webview_window(label)
            .and_then(|w| w.is_visible().ok())
            .unwrap_or(false)
    };
    (vis("widget"), vis("main"))
}
