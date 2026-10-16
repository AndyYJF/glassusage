//! Window chrome: native backdrop material, tray icon, and the main/widget swap.

use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::Result;
use tauri::{AppHandle, Emitter, Manager, WebviewWindow};

use crate::settings::WindowMaterial;

/// Apply the Windows backdrop that the CSS glass layers refract.
///
/// Acrylic samples the actual desktop behind the window, which is what makes the
/// refraction read as real glass. Mica is cheaper but only tints, and the CSS mode
/// leaves the window opaque-backed for machines where either causes drag stutter.
///
/// The mini card deliberately stays on the CSS path: native acrylic/mica fill the
/// rectangular HWND and paint solid corners outside the rounded CSS radius.
pub fn apply_material(app: &AppHandle, material: &WindowMaterial) {
    if let Some(main) = app.get_webview_window("main") {
        apply_material_to(&main, material);
    }
    if let Some(widget) = app.get_webview_window("widget") {
        prepare_widget(&widget);
    }
}

/// Clear native vibrancy and keep the HWND/WebView2 background fully transparent so
/// CSS `border-radius` can cut real rounded corners.
pub fn prepare_widget(window: &WebviewWindow) {
    apply_material_to(window, &WindowMaterial::Css);
    // Alpha 0 is required on Windows 8+: any non-zero alpha is forced to 255.
    let _ = window.set_background_color(Some(tauri::utils::config::Color(0, 0, 0, 0)));
}

#[cfg(windows)]
pub fn apply_material_to(window: &WebviewWindow, material: &WindowMaterial) {
    use window_vibrancy::{apply_acrylic, apply_mica, clear_acrylic, clear_mica};

    let _ = clear_acrylic(window);
    let _ = clear_mica(window);

    match material {
        WindowMaterial::Acrylic => {
            // Cool navy tint — pure grey acrylic washes the whole UI out.
            if apply_acrylic(window, Some((14, 18, 42, 78))).is_err() {
                let _ = apply_mica(window, Some(true));
            }
        }
        WindowMaterial::Mica => {
            let _ = apply_mica(window, Some(true));
        }
        WindowMaterial::Css => {}
    }
}

#[cfg(not(windows))]
pub fn apply_material_to(_window: &WebviewWindow, _material: &WindowMaterial) {}

/// Whether the mini card is currently standing in for the main window.
///
/// Tracked explicitly rather than inferred from the widget window's OS visibility, because
/// anything that shows or hides that window out of band would otherwise invert the meaning
/// of the next toggle.
static WIDGET_MODE: AtomicBool = AtomicBool::new(false);

pub fn widget_mode() -> bool {
    WIDGET_MODE.load(Ordering::Relaxed)
}

/// Swap between the main window and the always-on-top mini card.
pub fn set_widget_mode(app: &AppHandle, on: bool) -> Result<()> {
    let main = app.get_webview_window("main");
    let widget = app.get_webview_window("widget");

    if on {
        if let Some(w) = &widget {
            w.show()?;
            w.set_always_on_top(true)?;
            let _ = w.set_focus();
        }
        if let Some(m) = &main {
            m.hide()?;
        }
    } else {
        if let Some(w) = &widget {
            w.hide()?;
        }
        if let Some(m) = &main {
            m.show()?;
            m.unminimize().ok();
            m.set_focus()?;
        }
    }
    WIDGET_MODE.store(on, Ordering::Relaxed);
    let _ = app.emit("widget-mode", on);
    Ok(())
}

pub fn restore_main(app: &AppHandle, route: Option<&str>) -> Result<()> {
    set_widget_mode(app, false)?;
    if let Some(r) = route {
        let _ = app.emit("navigate", r);
    }
    Ok(())
}

/// Pull the widget flush against the nearest screen edge when it was dropped within
/// 24 logical pixels of one.
pub fn snap_widget(app: &AppHandle) -> Result<()> {
    const THRESHOLD: f64 = 24.0;
    const MARGIN: f64 = 12.0;

    let Some(window) = app.get_webview_window("widget") else {
        return Ok(());
    };
    let Some(monitor) = window.current_monitor()? else {
        return Ok(());
    };

    let scale = monitor.scale_factor();
    let screen = monitor.size().to_logical::<f64>(scale);
    let screen_pos = monitor.position().to_logical::<f64>(scale);
    let size = window.outer_size()?.to_logical::<f64>(scale);
    let pos = window.outer_position()?.to_logical::<f64>(scale);

    let left = pos.x - screen_pos.x;
    let top = pos.y - screen_pos.y;
    let right = screen.width - (left + size.width);
    let bottom = screen.height - (top + size.height);

    let mut x = left;
    let mut y = top;
    if left < THRESHOLD {
        x = MARGIN;
    } else if right < THRESHOLD {
        x = screen.width - size.width - MARGIN;
    }
    if top < THRESHOLD {
        y = MARGIN;
    } else if bottom < THRESHOLD {
        y = screen.height - size.height - MARGIN;
    }

    if (x - left).abs() > 0.5 || (y - top).abs() > 0.5 {
        window.set_position(tauri::LogicalPosition::new(
            screen_pos.x + x,
            screen_pos.y + y,
        ))?;
    }
    Ok(())
}

/// Place the widget at the bottom-right corner the first time it is shown.
pub fn place_widget_default(window: &WebviewWindow) -> Result<()> {
    let Some(monitor) = window.current_monitor()? else {
        return Ok(());
    };
    let scale = monitor.scale_factor();
    let screen = monitor.size().to_logical::<f64>(scale);
    let origin = monitor.position().to_logical::<f64>(scale);
    let size = window.outer_size()?.to_logical::<f64>(scale);
    window.set_position(tauri::LogicalPosition::new(
        origin.x + screen.width - size.width - 24.0,
        // Leave room for the taskbar.
        origin.y + screen.height - size.height - 72.0,
    ))?;
    Ok(())
}

/// Full vs compact mini-card size. Compact shows only today's tokens + cost.
pub fn apply_widget_compact(app: &AppHandle, compact: bool) {
    let Some(widget) = app.get_webview_window("widget") else {
        return;
    };
    let (w, h) = if compact {
        (300.0, 78.0)
    } else {
        (360.0, 168.0)
    };
    let _ = widget.set_size(tauri::LogicalSize::new(w, h));
}
