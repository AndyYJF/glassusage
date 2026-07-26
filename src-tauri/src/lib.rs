//! GlassUsage — token usage monitor for local AI coding agents.

pub mod collectors;
pub mod commands;
pub mod dpapi;
pub mod live;
pub mod model;
pub mod pricing;
pub mod remote;
pub mod settings;
pub mod state;
pub mod store;
pub mod watcher;
pub mod window;

use std::sync::Arc;

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::Manager;

use state::AppState;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("GLASSUSAGE_LOG")
                .unwrap_or_else(|_| "glassusage_lib=info,warn".into()),
        )
        .with_target(false)
        .init();

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_window_state::Builder::default().build())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            Some(vec!["--minimized"]),
        ))
        .invoke_handler(tauri::generate_handler![
            commands::get_overview,
            commands::get_agent_stats,
            commands::get_timeseries,
            commands::get_usage_log,
            commands::get_provider_stats,
            commands::get_model_stats,
            commands::get_group_stats,
            commands::get_source_health,
            commands::get_filter_options,
            commands::rescan_source,
            commands::rescan_all,
            commands::set_cursor_cookie,
            commands::get_cursor_status,
            commands::sync_cursor_now,
            commands::get_settings,
            commands::set_settings,
            commands::get_pricing_info,
            commands::set_pricing_overrides,
            commands::refresh_pricing,
            commands::export_csv,
            commands::export_json,
            commands::export_monthly_report,
            commands::list_remote_instances,
            commands::upsert_remote_instance,
            commands::delete_remote_instance,
            commands::test_remote_instance,
            commands::sync_remote_instance,
            commands::get_live_rates,
            commands::toggle_widget_mode,
            commands::show_main_window,
            commands::window_minimize,
            commands::window_toggle_maximize,
            commands::window_close,
            commands::set_widget_always_on_top,
            commands::widget_snap_to_edge,
            commands::quit_app,
            commands::open_data_dir,
        ])
        .setup(|app| {
            let data_dir = app
                .path()
                .app_data_dir()
                .unwrap_or_else(|_| std::path::PathBuf::from("."));
            let state = Arc::new(AppState::new(data_dir)?);
            let settings = state.settings.get();
            app.manage(state.clone());

            if let Some(main) = app.get_webview_window("main") {
                window::apply_material_to(&main, &settings.material);
                if settings.start_minimized || std::env::args().any(|a| a == "--minimized") {
                    let _ = main.hide();
                }
            }
            if let Some(widget) = app.get_webview_window("widget") {
                window::prepare_widget(&widget);
                window::apply_widget_compact(app.handle(), settings.widget_compact);
                let _ = window::place_widget_default(&widget);
            }

            build_tray(app.handle())?;
            register_shortcut(app.handle(), &settings.widget_shortcut);
            apply_autostart(app.handle(), settings.autostart);

            // First pass immediately, then watchers and timers take over.
            let handle = app.handle().clone();
            let scan_state = state.clone();
            std::thread::spawn(move || scan_state.scan_all(&handle));

            // Apply the bundled price table immediately so newly added offline prices
            // cover events that arrived as unpriced. Then refresh from LiteLLM and
            // reprice again if the network call succeeds.
            let pricing = state.pricing.clone();
            let store = state.store.clone();
            tauri::async_runtime::spawn(async move {
                let _ = store.reprice(&pricing);
                if pricing.refresh().await.is_ok() {
                    let _ = store.reprice(&pricing);
                }
            });

            let watch_handle = app.handle().clone();
            let watch_state = state.clone();
            std::thread::spawn(move || {
                let _guard = watcher::start(watch_handle, watch_state);
                // The watcher owns OS handles that must outlive this thread's scope.
                loop {
                    std::thread::sleep(std::time::Duration::from_secs(3600));
                }
            });

            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the main window hides it; Quit lives in the tray menu.
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running GlassUsage");
}

fn build_tray(app: &tauri::AppHandle) -> tauri::Result<()> {
    let show = MenuItem::with_id(app, "show", "Open GlassUsage", true, None::<&str>)?;
    let widget = MenuItem::with_id(app, "widget", "Mini card", true, None::<&str>)?;
    let rescan = MenuItem::with_id(app, "rescan", "Rescan all sources", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let menu = Menu::with_items(
        app,
        &[
            &show,
            &widget,
            &PredefinedMenuItem::separator(app)?,
            &rescan,
            &PredefinedMenuItem::separator(app)?,
            &quit,
        ],
    )?;

    TrayIconBuilder::with_id("main-tray")
        .icon(app.default_window_icon().cloned().unwrap())
        .tooltip("GlassUsage")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => {
                let _ = window::restore_main(app, None);
            }
            "widget" => {
                let _ = window::set_widget_mode(app, true);
            }
            "rescan" => {
                if let Some(state) = app.try_state::<Arc<AppState>>() {
                    let st = state.inner().clone();
                    let handle = app.clone();
                    std::thread::spawn(move || st.scan_all(&handle));
                }
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let _ = window::restore_main(tray.app_handle(), None);
            }
        })
        .build(app)?;
    Ok(())
}

fn register_shortcut(app: &tauri::AppHandle, accelerator: &str) {
    use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};

    let Ok(shortcut) = accelerator.parse::<tauri_plugin_global_shortcut::Shortcut>() else {
        tracing::warn!("invalid widget shortcut: {accelerator}");
        return;
    };
    let result = app.global_shortcut().on_shortcut(shortcut, move |app, _sc, event| {
        // Fire once per press, not again on release.
        if event.state() != ShortcutState::Pressed {
            return;
        }
        let _ = window::set_widget_mode(app, !window::widget_mode());
    });
    if let Err(e) = result {
        tracing::warn!("could not register {accelerator}: {e}");
    }
}

/// Drop the previous accelerator and bind the new one without restarting.
pub fn replace_widget_shortcut(app: &tauri::AppHandle, old: &str, new: &str) {
    use tauri_plugin_global_shortcut::GlobalShortcutExt;

    if old != new {
        if let Ok(sc) = old.parse::<tauri_plugin_global_shortcut::Shortcut>() {
            if let Err(e) = app.global_shortcut().unregister(sc) {
                tracing::warn!("could not unregister {old}: {e}");
            }
        }
    }
    register_shortcut(app, new);
}

pub fn apply_autostart(app: &tauri::AppHandle, on: bool) {
    use tauri_plugin_autostart::ManagerExt;
    let manager = app.autolaunch();
    let result = if on {
        manager.enable()
    } else {
        manager.disable()
    };
    if let Err(e) = result {
        tracing::warn!("autostart {}: {e}", if on { "enable" } else { "disable" });
    }
}
