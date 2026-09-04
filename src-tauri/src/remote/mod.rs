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

use anyhow::{bail, Result};
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
    /// Optional HTTP proxy (`http://host:port`) tunnelled through with CONNECT.
    pub proxy_url: Option<String>,
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
    #[serde(default)]
    pub proxy_url: Option<String>,
}

impl RemoteInstanceInput {
    pub fn validate(&self) -> Result<()> {
        let name = self.name.trim();
        if name.is_empty() || name.len() > 64 {
            bail!("instance name must be between 1 and 64 characters");
        }
        if name.eq_ignore_ascii_case(crate::model::LOCAL_INSTANCE) {
            bail!("'local' is reserved for this machine");
        }
        if name.ends_with('.') {
            bail!("instance name may not end with a dot");
        }
        if !name.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_alphanumeric() || (index > 0 && matches!(byte, b'.' | b'_' | b'-'))
        }) {
            bail!("instance name must start with a letter or number and contain only letters, numbers, '.', '_' or '-'");
        }
        let stem = name
            .split('.')
            .next()
            .unwrap_or_default()
            .to_ascii_uppercase();
        let reserved = matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
            || (stem.len() == 4
                && (stem.starts_with("COM") || stem.starts_with("LPT"))
                && stem.as_bytes()[3].is_ascii_digit()
                && stem.as_bytes()[3] != b'0');
        if reserved {
            bail!("instance name is reserved by Windows");
        }
        if !matches!(self.agent.as_str(), "hermes" | "openclaw") {
            bail!("unsupported remote agent type");
        }
        let host = self.host.trim();
        if host.is_empty()
            || !host.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b':' | b'[' | b']')
            })
        {
            bail!("host contains unsupported characters");
        }
        let username = self.username.trim();
        if username.is_empty()
            || !username
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        {
            bail!("username contains unsupported characters");
        }
        if !(1..=65_535).contains(&self.port) {
            bail!("port must be between 1 and 65535");
        }
        if !matches!(self.auth_mode.as_str(), "key" | "agent" | "password") {
            bail!("unsupported authentication mode");
        }
        if !(60..=3_600).contains(&self.poll_secs) {
            bail!("poll interval must be between 60 and 3600 seconds");
        }
        for value in [
            self.key_path.as_deref(),
            self.remote_home.as_deref(),
            self.remote_path.as_deref(),
            self.proxy_url.as_deref(),
        ]
        .into_iter()
        .flatten()
        {
            if value.contains(['\0', '\r', '\n']) {
                bail!("paths may not contain control characters");
            }
        }
        if let Some(proxy) = self.proxy_url.as_deref().filter(|p| !p.trim().is_empty()) {
            let rest = proxy
                .trim()
                .strip_prefix("http://")
                .ok_or_else(|| anyhow::anyhow!("proxy must look like http://host:port"))?;
            let host_port = rest.split('/').next().unwrap_or_default();
            let valid = host_port.split(':').count() == 2
                && host_port.split(':').all(|part| {
                    !part.is_empty()
                        && part
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-'))
                });
            if !valid {
                bail!("proxy must look like http://host:port");
            }
        }
        Ok(())
    }
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
            proxy_url: i
                .proxy_url
                .as_deref()
                .map(str::trim)
                .filter(|p| !p.is_empty())
                .map(str::to_string),
        }
    }
}

impl RemoteInstance {
    pub fn validate(&self) -> Result<()> {
        RemoteInstanceInput {
            name: self.name.clone(),
            agent: self.agent.clone(),
            host: self.host.clone(),
            port: self.port,
            username: self.username.clone(),
            auth_mode: self.auth_mode.clone(),
            key_path: self.key_path.clone(),
            password: None,
            remote_home: self.remote_home.clone(),
            remote_path: self.remote_path.clone(),
            poll_secs: self.poll_secs,
            import_archives: self.import_archives,
            enabled: self.enabled,
            proxy_url: self.proxy_url.clone(),
        }
        .validate()
    }

    /// Default data paths per agent, used when `remote_path` is blank.
    pub fn default_remote_paths(&self, home: &str) -> Vec<String> {
        match self.agent.as_str() {
            "hermes" => vec![format!("{home}/.hermes/state.db")],
            "openclaw" => vec![format!("{home}/.openclaw")],
            _ => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_input() -> RemoteInstanceInput {
        RemoteInstanceInput {
            name: "build-box".into(),
            agent: "openclaw".into(),
            host: "10.0.0.5".into(),
            port: 22,
            username: "ubuntu".into(),
            auth_mode: "password".into(),
            key_path: None,
            password: Some("secret".into()),
            remote_home: None,
            remote_path: None,
            poll_secs: 300,
            import_archives: false,
            enabled: true,
            proxy_url: None,
        }
    }

    #[test]
    fn rejects_instance_names_that_can_escape_snapshot_root() {
        for name in [
            "../outside",
            r"..\outside",
            ".",
            "CON",
            "/absolute",
            "local",
            "LOCAL",
            "name.",
        ] {
            let mut input = valid_input();
            input.name = name.into();
            assert!(input.validate().is_err(), "{name} should be rejected");
        }
    }

    #[test]
    fn accepts_safe_remote_configuration() {
        assert!(valid_input().validate().is_ok());
    }
}
