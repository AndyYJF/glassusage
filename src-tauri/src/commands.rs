//! Tauri commands. Every handler returns `Result<_, String>` so a failure surfaces as a
//! rejected promise the UI can render inline rather than an unhandled panic.

use std::collections::HashMap;
use std::sync::Arc;

use tauri::{AppHandle, Emitter, Manager, State};

use crate::model::*;
use crate::pricing::ModelPrice;
use crate::remote::{RemoteInstance, RemoteInstanceInput, TestReport};
use crate::settings::AppSettings;
use crate::state::AppState;

type Res<T> = Result<T, String>;

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

#[tauri::command]
pub fn get_overview(state: State<'_, Arc<AppState>>, range: TimeRange) -> Res<OverviewStats> {
    state.store.overview(range).map_err(err)
}

#[tauri::command]
pub fn get_agent_stats(state: State<'_, Arc<AppState>>, source: String, range: TimeRange) -> Res<AgentStats> {
    state.store.agent_stats(&source, range).map_err(err)
}

#[tauri::command]
pub fn get_timeseries(
    state: State<'_, Arc<AppState>>,
    range: TimeRange,
    group_by: String,
    bucket: String,
    source: Option<String>,
) -> Res<Vec<SeriesPoint>> {
    state
        .store
        .timeseries(range, &group_by, &bucket, source.as_deref())
        .map_err(err)
}

#[tauri::command]
pub fn get_usage_log(
    state: State<'_, Arc<AppState>>,
    filter: UsageFilter,
    page: i64,
    page_size: i64,
) -> Res<Page<UsageRow>> {
    state.store.usage_log(&filter, page, page_size).map_err(err)
}

#[tauri::command]
pub fn get_provider_stats(state: State<'_, Arc<AppState>>, filter: UsageFilter) -> Res<Vec<GroupStat>> {
    state.store.group_stats("provider", &filter).map_err(err)
}

#[tauri::command]
pub fn get_model_stats(state: State<'_, Arc<AppState>>, filter: UsageFilter) -> Res<Vec<GroupStat>> {
    state.store.group_stats("model_norm", &filter).map_err(err)
}

#[tauri::command]
pub fn get_group_stats(state: State<'_, Arc<AppState>>, column: String, filter: UsageFilter) -> Res<Vec<GroupStat>> {
    state.store.group_stats(&column, &filter).map_err(err)
}

#[tauri::command]
pub fn get_source_health(state: State<'_, Arc<AppState>>) -> Res<Vec<SourceHealth>> {
    Ok(state.health())
}

#[tauri::command]
pub fn get_filter_options(state: State<'_, Arc<AppState>>) -> Res<HashMap<String, Vec<String>>> {
    let mut out = HashMap::new();
    for col in ["provider", "model_norm", "instance", "source", "project"] {
        out.insert(col.to_string(), state.store.distinct_values(col).unwrap_or_default());
    }
    Ok(out)
}

/// Full re-read of a source. Clearing the watermark is safe because dedup keys prevent
/// the re-read from duplicating anything already stored.
#[tauri::command]
pub fn rescan_source(
    app: AppHandle,
    state: State<'_, Arc<AppState>>,
    source: String,
    instance: Option<String>,
    purge: Option<bool>,
) -> Res<()> {
    state
        .store
        .clear_scan_state(&source, instance.as_deref())
        .map_err(err)?;
    if purge.unwrap_or(false) {
        state.store.delete_source(&source, instance.as_deref()).map_err(err)?;
    }
    let st = state.inner().clone();
    // Rescans can take seconds on a cold cache; do not block the IPC call.
    std::thread::spawn(move || st.run_scan(&app, &source, None));
    Ok(())
}

#[tauri::command]
pub fn rescan_all(app: AppHandle, state: State<'_, Arc<AppState>>) -> Res<()> {
    let st = state.inner().clone();
    std::thread::spawn(move || st.scan_all(&app));
    Ok(())
}

#[tauri::command]
pub fn set_cursor_cookie(state: State<'_, Arc<AppState>>, token: String) -> Res<()> {
    state.set_cursor_cookie(&token).map_err(err)
}

#[tauri::command]
pub fn get_cursor_status(state: State<'_, Arc<AppState>>) -> Res<serde_json::Value> {
    use crate::collectors::cursor::{self, CursorCollector};
    let settings = state.settings.get();
    Ok(serde_json::json!({
        "hasAccessToken": CursorCollector::access_token(&settings).is_some(),
        "hasCookie": state.cursor_cookie().is_some(),
        "stateDb": CursorCollector::state_db(&settings).map(|p| p.to_string_lossy().to_string()),
        "lastError": cursor::take_error(),
    }))
}

#[tauri::command]
pub async fn sync_cursor_now(app: AppHandle, state: State<'_, Arc<AppState>>) -> Res<()> {
    let st = state.inner().clone();
    st.sync_cursor(&app).await;
    Ok(())
}

#[tauri::command]
pub fn get_settings(state: State<'_, Arc<AppState>>) -> Res<AppSettings> {
    Ok(state.settings.get())
}

#[tauri::command]
pub fn set_settings(app: AppHandle, state: State<'_, Arc<AppState>>, patch: serde_json::Value) -> Res<AppSettings> {
    let prev = state.settings.get();
    let next = state.settings.patch(patch).map_err(err)?;
    // The window backdrop is owned by the OS, so it has to be re-applied here rather
    // than in CSS.
    crate::window::apply_material(&app, &next.material);

    if next.widget_shortcut != prev.widget_shortcut {
        crate::replace_widget_shortcut(&app, &prev.widget_shortcut, &next.widget_shortcut);
    }

    if next.autostart != prev.autostart {
        crate::apply_autostart(&app, next.autostart);
    }

    if next.widget_compact != prev.widget_compact {
        crate::window::apply_widget_compact(&app, next.widget_compact);
    }

    // Changing caps or scope should allow a fresh alert the same day.
    if next.budget_alerts_enabled != prev.budget_alerts_enabled
        || (next.daily_cost_budget - prev.daily_cost_budget).abs() > f64::EPSILON
        || next.daily_token_budget != prev.daily_token_budget
        || next.budget_alert_sources != prev.budget_alert_sources
    {
        state.reset_budget_alert_gate();
        if next.budget_alerts_enabled {
            state.check_budget_alerts(&app);
        }
    }

    let _ = app.emit("settings-changed", &next);
    Ok(next)
}

#[tauri::command]
pub fn get_pricing_info(state: State<'_, Arc<AppState>>) -> Res<serde_json::Value> {
    let (count, source) = state.pricing.table_info();
    Ok(serde_json::json!({
        "modelCount": count,
        "source": source,
        "overrides": state.pricing.overrides(),
    }))
}

#[tauri::command]
pub fn set_pricing_overrides(
    state: State<'_, Arc<AppState>>,
    overrides: HashMap<String, ModelPrice>,
) -> Res<usize> {
    state.pricing.set_overrides(overrides).map_err(err)?;
    // Existing rows were costed with the old table, so re-derive them.
    state.store.reprice(&state.pricing).map_err(err)
}

#[tauri::command]
pub async fn refresh_pricing(state: State<'_, Arc<AppState>>) -> Res<usize> {
    let st = state.inner().clone();
    let n = st.pricing.refresh().await.map_err(err)?;
    st.store.reprice(&st.pricing).map_err(err)?;
    Ok(n)
}

#[tauri::command]
pub fn export_csv(state: State<'_, Arc<AppState>>, filter: UsageFilter, path: Option<String>) -> Res<String> {
    use std::io::Write;

    let target = match path {
        Some(p) if !p.trim().is_empty() => std::path::PathBuf::from(p),
        _ => {
            let name = format!(
                "glassusage-export-{}.csv",
                chrono::Local::now().format("%Y%m%d-%H%M%S")
            );
            dirs::download_dir()
                .unwrap_or_else(|| state.data_dir.clone())
                .join(name)
        }
    };

    let file = std::fs::File::create(&target).map_err(err)?;
    let mut w = std::io::BufWriter::new(file);
    writeln!(
        w,
        "timestamp,source,surface,instance,provider,model,model_norm,project,session_id,\
         input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,total_tokens,cost_usd"
    )
    .map_err(err)?;

    let mut io_error = None;
    state
        .store
        .for_each_usage_row(&filter, |r| {
            if io_error.is_some() {
                return;
            }
            let ts = chrono::DateTime::from_timestamp_millis(r.ts_ms)
                .map(|d| d.with_timezone(&chrono::Local).to_rfc3339())
                .unwrap_or_default();
            let total = r.input_tokens + r.output_tokens + r.cache_read_tokens + r.cache_write_tokens;
            let line = format!(
                "{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}",
                ts,
                r.source,
                r.surface,
                r.instance,
                csv_field(r.provider.as_deref().unwrap_or("")),
                csv_field(&r.model),
                csv_field(&r.model_norm),
                csv_field(r.project.as_deref().unwrap_or("")),
                csv_field(&r.session_id),
                r.input_tokens,
                r.output_tokens,
                r.cache_read_tokens,
                r.cache_write_tokens,
                r.reasoning_tokens,
                total,
                r.cost_usd.map(|c| format!("{c:.6}")).unwrap_or_default(),
            );
            if let Err(e) = writeln!(w, "{line}") {
                io_error = Some(e.to_string());
            }
        })
        .map_err(err)?;

    if let Some(e) = io_error {
        return Err(e);
    }
    w.flush().map_err(err)?;
    Ok(target.to_string_lossy().to_string())
}

fn csv_field(s: &str) -> String {
    if s.contains([',', '"', '\n']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

fn default_export_path(data_dir: &std::path::Path, stem: &str, ext: &str) -> std::path::PathBuf {
    let name = format!(
        "{stem}-{}.{}",
        chrono::Local::now().format("%Y%m%d-%H%M%S"),
        ext
    );
    dirs::download_dir()
        .unwrap_or_else(|| data_dir.to_path_buf())
        .join(name)
}

#[tauri::command]
pub fn export_json(state: State<'_, Arc<AppState>>, filter: UsageFilter, path: Option<String>) -> Res<String> {
    use std::io::Write;

    let target = match path {
        Some(p) if !p.trim().is_empty() => std::path::PathBuf::from(p),
        _ => default_export_path(&state.data_dir, "glassusage-export", "json"),
    };

    let mut rows = Vec::new();
    state
        .store
        .for_each_usage_row(&filter, |r| {
            let ts = chrono::DateTime::from_timestamp_millis(r.ts_ms)
                .map(|d| d.with_timezone(&chrono::Local).to_rfc3339())
                .unwrap_or_default();
            let total = r.input_tokens + r.output_tokens + r.cache_read_tokens + r.cache_write_tokens;
            rows.push(serde_json::json!({
                "timestamp": ts,
                "tsMs": r.ts_ms,
                "source": r.source,
                "surface": r.surface,
                "instance": r.instance,
                "provider": r.provider,
                "model": r.model,
                "modelNorm": r.model_norm,
                "project": r.project,
                "sessionId": r.session_id,
                "inputTokens": r.input_tokens,
                "outputTokens": r.output_tokens,
                "cacheReadTokens": r.cache_read_tokens,
                "cacheWriteTokens": r.cache_write_tokens,
                "reasoningTokens": r.reasoning_tokens,
                "totalTokens": total,
                "costUsd": r.cost_usd,
                "unpriced": r.unpriced,
            }));
        })
        .map_err(err)?;

    let file = std::fs::File::create(&target).map_err(err)?;
    let mut w = std::io::BufWriter::new(file);
    serde_json::to_writer_pretty(&mut w, &rows).map_err(|e| e.to_string())?;
    w.flush().map_err(err)?;
    Ok(target.to_string_lossy().to_string())
}

#[tauri::command]
pub fn export_monthly_report(
    state: State<'_, Arc<AppState>>,
    filter: UsageFilter,
    path: Option<String>,
) -> Res<String> {
    use std::io::Write;

    let target = match path {
        Some(p) if !p.trim().is_empty() => std::path::PathBuf::from(p),
        _ => default_export_path(&state.data_dir, "glassusage-monthly", "json"),
    };

    let months = state.store.monthly_stats(&filter).map_err(err)?;
    let report = serde_json::json!({
        "generatedAt": chrono::Local::now().to_rfc3339(),
        "filter": {
            "from": filter.from,
            "to": filter.to,
            "sources": filter.sources,
        },
        "months": months,
    });

    let file = std::fs::File::create(&target).map_err(err)?;
    let mut w = std::io::BufWriter::new(file);
    serde_json::to_writer_pretty(&mut w, &report).map_err(|e| e.to_string())?;
    w.flush().map_err(err)?;
    Ok(target.to_string_lossy().to_string())
}

// ------------------------------------------------------------------ remote instances

#[tauri::command]
pub fn list_remote_instances(state: State<'_, Arc<AppState>>) -> Res<Vec<RemoteInstance>> {
    state.store.list_remote().map_err(err)
}

#[tauri::command]
pub fn upsert_remote_instance(state: State<'_, Arc<AppState>>, cfg: RemoteInstanceInput) -> Res<()> {
    if cfg.name.trim().is_empty() {
        return Err("Instance name is required".into());
    }
    if cfg.name.trim() == crate::model::LOCAL_INSTANCE {
        return Err("'local' is reserved for this machine".into());
    }
    let inst: RemoteInstance = (&cfg).into();
    // The plaintext password exists only in this call; DPAPI-encrypt before it is stored.
    let secret = match cfg.password.as_deref().filter(|p| !p.is_empty()) {
        Some(p) => Some(crate::dpapi::protect_str(p).map_err(err)?),
        None => None,
    };
    state.store.upsert_remote(&inst, secret).map_err(err)
}

#[tauri::command]
pub fn delete_remote_instance(state: State<'_, Arc<AppState>>, name: String) -> Res<()> {
    state.store.delete_remote(&name).map_err(err)
}

#[tauri::command]
pub async fn test_remote_instance(state: State<'_, Arc<AppState>>, cfg: RemoteInstanceInput) -> Res<TestReport> {
    let st = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || crate::remote::test_instance(&st, &cfg))
        .await
        .map_err(err)
}

#[tauri::command]
pub async fn sync_remote_instance(app: AppHandle, state: State<'_, Arc<AppState>>, name: String) -> Res<usize> {
    let st = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || crate::remote::sync_instance(&app, &st, &name))
        .await
        .map_err(err)?
        .map_err(err)
}

// ------------------------------------------------------------------- widget & live

#[tauri::command]
pub fn get_live_rates(app: AppHandle, state: State<'_, Arc<AppState>>) -> Res<LiveRates> {
    let rates = state.live_rates();
    state.check_budget_alerts(&app);
    Ok(rates)
}

#[tauri::command]
pub fn toggle_widget_mode(app: AppHandle, on: bool) -> Res<()> {
    crate::window::set_widget_mode(&app, on).map_err(err)
}

#[tauri::command]
pub fn show_main_window(app: AppHandle, route: Option<String>) -> Res<()> {
    crate::window::restore_main(&app, route.as_deref()).map_err(err)
}

#[tauri::command]
pub fn window_minimize(app: AppHandle, label: String) -> Res<()> {
    if let Some(w) = app.get_webview_window(&label) {
        w.minimize().map_err(err)?;
    }
    Ok(())
}

#[tauri::command]
pub fn window_toggle_maximize(app: AppHandle, label: String) -> Res<()> {
    if let Some(w) = app.get_webview_window(&label) {
        if w.is_maximized().unwrap_or(false) {
            w.unmaximize().map_err(err)?;
        } else {
            w.maximize().map_err(err)?;
        }
    }
    Ok(())
}

/// Closing the main window hides it to the tray instead of exiting, matching the tray
/// menu's separate Quit entry.
#[tauri::command]
pub fn window_close(app: AppHandle, label: String) -> Res<()> {
    if let Some(w) = app.get_webview_window(&label) {
        w.hide().map_err(err)?;
    }
    Ok(())
}

#[tauri::command]
pub fn set_widget_always_on_top(app: AppHandle, state: State<'_, Arc<AppState>>, on: bool) -> Res<()> {
    if let Some(w) = app.get_webview_window("widget") {
        w.set_always_on_top(on).map_err(err)?;
    }
    state
        .settings
        .patch(serde_json::json!({ "widgetAlwaysOnTop": on }))
        .map_err(err)?;
    Ok(())
}

/// Snap the widget to a screen edge when it is dropped near one.
#[tauri::command]
pub fn widget_snap_to_edge(app: AppHandle) -> Res<()> {
    crate::window::snap_widget(&app).map_err(err)
}

#[tauri::command]
pub fn quit_app(app: AppHandle) -> Res<()> {
    app.exit(0);
    Ok(())
}

#[tauri::command]
pub fn open_data_dir(app: AppHandle, state: State<'_, Arc<AppState>>) -> Res<()> {
    use tauri_plugin_opener::OpenerExt;
    app.opener()
        .open_path(state.data_dir.to_string_lossy().to_string(), None::<&str>)
        .map_err(err)
}
