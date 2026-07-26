//! Remote Hermes / OpenClaw instances.
//!
//! Both agents keep self-contained SQLite files, so a remote instance needs no new
//! parsing: pull a consistent snapshot to `%APPDATA%\GlassUsage\remote\<name>\`, then
//! hand it to the existing collector with `instance` set to the instance name.
//!
//! The transport is strictly pull-based. Nothing is installed on the remote host and no
//! port is opened there; only read-only commands are ever executed.

pub mod password_ssh;
pub mod ssh;
pub mod sync;

use serde::{Deserialize, Serialize};

pub use sync::{spawn_scheduler, sync_instance, test_instance, TestReport, TestStep};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteInstance {
    pub name: String,
    /// `"hermes"` or `"openclaw"`.
    pub agent: String,
    pub host: String,
    pub port: i64,
    pub username: String,
    /// `"key"`, `"agent"` or `"password"`.
    pub auth_mode: String,
    pub key_path: Option<String>,
    pub remote_home: Option<String>,
    pub remote_path: Option<String>,
    pub poll_secs: i64,
    pub import_archives: bool,
    pub enabled: bool,
    /// Whether a DPAPI-encrypted secret is stored. The secret itself is never returned.
    pub has_secret: bool,
}

/// Shape accepted from the UI. The password is present only at save time.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteInstanceInput {
    pub name: String,
    pub agent: String,
    pub host: String,
    #[serde(default = "default_port")]
    pub port: i64,
    pub username: String,
    pub auth_mode: String,
    #[serde(default)]
    pub key_path: Option<String>,
    #[serde(default)]
    pub password: Option<String>,
    #[serde(default)]
    pub remote_home: Option<String>,
    #[serde(default)]
    pub remote_path: Option<String>,
    #[serde(default = "default_poll")]
    pub poll_secs: i64,
    #[serde(default)]
    pub import_archives: bool,
    #[serde(default = "default_true")]
    pub enabled: bool,
}

fn default_port() -> i64 {
    22
}
fn default_poll() -> i64 {
    300
}
fn default_true() -> bool {
    true
}

impl From<&RemoteInstanceInput> for RemoteInstance {
    fn from(i: &RemoteInstanceInput) -> Self {
        Self {
            name: i.name.trim().to_string(),
            agent: i.agent.clone(),
            host: i.host.trim().to_string(),
            port: i.port,
            username: i.username.trim().to_string(),
            auth_mode: i.auth_mode.clone(),
            key_path: i.key_path.clone(),
            remote_home: i.remote_home.clone(),
            remote_path: i.remote_path.clone(),
            poll_secs: i.poll_secs.clamp(60, 3600),
            import_archives: i.import_archives,
            enabled: i.enabled,
            has_secret: i.password.is_some(),
        }
    }
}

impl RemoteInstance {
    /// Default data paths per agent, used when `remote_path` is blank.
    pub fn default_remote_paths(&self, home: &str) -> Vec<String> {
        match self.agent.as_str() {
            "hermes" => vec![format!("{home}/.hermes/state.db")],
            "openclaw" => vec![format!("{home}/.openclaw")],
            _ => Vec::new(),
        }
    }
}
