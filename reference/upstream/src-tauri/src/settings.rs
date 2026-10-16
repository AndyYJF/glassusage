//! User settings, persisted as `%APPDATA%\GlassUsage\settings.json`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::Result;
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum WindowMaterial {
    /// Real desktop see-through blur. Best looking, heaviest while dragging.
    Acrylic,
    /// Cheaper Win11 backdrop, tinted by the desktop rather than showing it.
    Mica,
    /// No native backdrop; the CSS glass layers render over an internal gradient.
    Css,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ThemeMode {
    System,
    Dark,
    Light,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum LocaleMode {
    /// Follow the OS / browser language (zh* → zh, else en).
    #[default]
    System,
    En,
    Zh,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceConfig {
    pub enabled: bool,
    /// Overrides the auto-detected data directory.
    pub custom_path: Option<String>,
}

impl Default for SourceConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            custom_path: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppSettings {
    pub sources: HashMap<String, SourceConfig>,
    pub material: WindowMaterial,
    pub theme: ThemeMode,
    /// UI language. `system` follows the OS locale at launch.
    pub locale: LocaleMode,
    /// Displacement strength for the liquid-glass lens, 0..1 mapped to filter presets.
    pub refraction: f64,
    /// Slow-moving mesh gradient behind the UI, for when the native backdrop is off.
    pub animated_background: bool,
    pub poll_secs: u64,
    pub cursor_poll_secs: u64,
    pub autostart: bool,
    pub start_minimized: bool,
    pub widget_compact: bool,
    pub widget_always_on_top: bool,
    pub widget_shortcut: String,
    /// Antigravity IDE reads protobuf blobs with no public schema; opt-in.
    pub antigravity_ide_enabled: bool,
    pub auto_refresh_secs: u64,
    pub first_run_done: bool,
    /// Toast when today's cost / tokens cross the configured caps.
    pub budget_alerts_enabled: bool,
    /// Daily spend cap in USD. Checked only when `budget_alerts_enabled`.
    pub daily_cost_budget: f64,
    /// Daily token cap. `0` disables the token check while leaving cost alerts on.
    pub daily_token_budget: i64,
    /// Agents included in the budget. Empty = all agents.
    pub budget_alert_sources: Vec<String>,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            sources: crate::model::source::ALL
                .iter()
                .map(|s| (s.to_string(), SourceConfig::default()))
                .collect(),
            material: WindowMaterial::Acrylic,
            theme: ThemeMode::System,
            locale: LocaleMode::System,
            refraction: 0.62,
            animated_background: true,
            poll_secs: 60,
            cursor_poll_secs: 300,
            autostart: false,
            start_minimized: false,
            widget_compact: false,
            widget_always_on_top: true,
            // A global hotkey shadows this chord in every application, so the default
            // avoids Ctrl+Shift+<letter>, which editors and browsers use heavily
            // (Ctrl+Shift+G is source control in VS Code, find-previous elsewhere).
            widget_shortcut: "CmdOrCtrl+Alt+G".into(),
            antigravity_ide_enabled: true,
            auto_refresh_secs: 30,
            first_run_done: false,
            budget_alerts_enabled: false,
            daily_cost_budget: 10.0,
            daily_token_budget: 0,
            budget_alert_sources: Vec::new(),
        }
    }
}

impl AppSettings {
    pub fn source_enabled(&self, source: &str) -> bool {
        self.sources.get(source).map(|c| c.enabled).unwrap_or(true)
    }

    pub fn custom_path(&self, source: &str) -> Option<PathBuf> {
        self.sources
            .get(source)
            .and_then(|c| c.custom_path.as_ref())
            .filter(|p| !p.trim().is_empty())
            .map(PathBuf::from)
    }
}

pub struct SettingsStore {
    path: PathBuf,
    inner: RwLock<AppSettings>,
}

impl SettingsStore {
    pub fn load(data_dir: &Path) -> Self {
        let path = data_dir.join("settings.json");
        let inner = match std::fs::read_to_string(&path) {
            Ok(s) => {
                let raw: serde_json::Value = serde_json::from_str(&s).unwrap_or_default();
                // Settings that predate onboarding must not re-open the wizard.
                let had_flag = raw.get("firstRunDone").is_some();
                let mut settings: AppSettings = serde_json::from_value(raw).unwrap_or_default();
                if !had_flag {
                    settings.first_run_done = true;
                }
                settings
            }
            Err(_) => AppSettings::default(),
        };
        Self {
            path,
            inner: RwLock::new(inner),
        }
    }

    pub fn get(&self) -> AppSettings {
        self.inner.read().clone()
    }

    /// Merge a partial JSON patch into the current settings and persist.
    pub fn patch(&self, patch: serde_json::Value) -> Result<AppSettings> {
        let mut guard = self.inner.write();
        let mut current = serde_json::to_value(&*guard)?;
        merge(&mut current, patch);
        let next: AppSettings = serde_json::from_value(current)?;
        self.save_value(&next)?;
        *guard = next.clone();
        Ok(next)
    }

    pub fn save(&self) -> Result<()> {
        self.save_value(&self.inner.read())
    }

    fn save_value(&self, settings: &AppSettings) -> Result<()> {
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir).ok();
        }
        std::fs::write(&self.path, serde_json::to_string_pretty(settings)?)?;
        Ok(())
    }
}

fn merge(target: &mut serde_json::Value, patch: serde_json::Value) {
    match (target, patch) {
        (serde_json::Value::Object(t), serde_json::Value::Object(p)) => {
            for (k, v) in p {
                merge(t.entry(k).or_insert(serde_json::Value::Null), v);
            }
        }
        (t, p) => *t = p,
    }
}
