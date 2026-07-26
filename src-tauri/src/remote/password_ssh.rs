//! Native password SSH via `russh` — no PuTTY, no interactive TTY, no askpass hacks.
//!
//! Key / agent auth still goes through the system OpenSSH client in `ssh.rs`.
//!
//! A single multi-thread Tokio runtime and one SSH session are reused for the lifetime of
//! a sync, so listing / stat / download do not pay a fresh TCP + auth handshake each time.

use std::path::Path;
use std::sync::{Arc, OnceLock};

use anyhow::{anyhow, bail, Context, Result};
use russh::client::{self, Handle};
use russh::ChannelMsg;
use tokio::io::AsyncWriteExt;
use tokio::runtime::Runtime;

struct AcceptAll;

impl client::Handler for AcceptAll {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        _server_public_key: &russh::keys::PublicKey,
    ) -> Result<bool, Self::Error> {
        // Matches OpenSSH `StrictHostKeyChecking=accept-new` for this app's use case:
        // we only ever read usage databases, never write to the remote host.
        Ok(true)
    }
}

fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("glassusage-ssh")
            .build()
            .expect("failed to start SSH runtime")
    })
}

/// Persistent password-authenticated session for one remote sync.
pub struct PasswordSession {
    handle: Handle<AcceptAll>,
}

impl PasswordSession {
    pub fn connect(host: &str, port: u16, username: &str, password: &str) -> Result<Self> {
        let handle = runtime().block_on(connect_async(host, port, username, password))?;
        Ok(Self { handle })
    }

    pub fn exec(&mut self, command: &str) -> Result<String> {
        runtime().block_on(exec_async(&mut self.handle, command))
    }

    pub fn download(&mut self, remote_path: &str, local_path: &Path) -> Result<()> {
        if let Some(dir) = local_path.parent() {
            std::fs::create_dir_all(dir).ok();
        }
        runtime().block_on(download_async(&mut self.handle, remote_path, local_path))
    }
}

async fn connect_async(
    host: &str,
    port: u16,
    username: &str,
    password: &str,
) -> Result<Handle<AcceptAll>> {
    let mut config = client::Config::default();
    // Large transfers (OpenClaw agent DBs) need room; keep the session alive for the
    // whole sync rather than treating quiet moments between commands as dead.
    config.inactivity_timeout = Some(std::time::Duration::from_secs(30 * 60));
    config.window_size = 32 * 1024 * 1024;
    config.maximum_packet_size = 65_535;
    let config = Arc::new(config);

    let mut session = client::connect(config, (host, port), AcceptAll)
        .await
        .with_context(|| format!("TCP connect to {host}:{port} failed"))?;

    let result = session
        .authenticate_password(username, password)
        .await
        .context("SSH password authentication failed")?;

    if !result.success() {
        bail!("SSH password authentication rejected");
    }
    Ok(session)
}

async fn exec_async(session: &mut Handle<AcceptAll>, command: &str) -> Result<String> {
    let mut channel = session
        .channel_open_session()
        .await
        .context("failed to open SSH session channel")?;
    channel
        .exec(true, command)
        .await
        .with_context(|| format!("failed to exec: {command}"))?;

    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let mut code: Option<u32> = None;

    loop {
        match channel.wait().await {
            Some(ChannelMsg::Data { ref data }) => stdout.extend_from_slice(data),
            Some(ChannelMsg::ExtendedData { ref data, .. }) => stderr.extend_from_slice(data),
            Some(ChannelMsg::ExitStatus { exit_status }) => code = Some(exit_status),
            Some(ChannelMsg::Eof) | None => break,
            _ => {}
        }
    }

    if let Some(c) = code {
        if c != 0 {
            bail!(
                "ssh exited with {c}: {}",
                String::from_utf8_lossy(&stderr).trim()
            );
        }
    }

    Ok(String::from_utf8_lossy(&stdout).to_string())
}

/// Stream a remote file over an `exec` channel (`cat`). This is typically much faster
/// than the SFTP subsystem on long-haul links, and avoids a second subsystem handshake.
async fn download_async(
    session: &mut Handle<AcceptAll>,
    remote_path: &str,
    local_path: &Path,
) -> Result<()> {
    let resolved = resolve_path(session, remote_path).await?;
    let cmd = format!("cat -- {}", shell_quote(&resolved));

    let mut channel = session
        .channel_open_session()
        .await
        .context("failed to open SSH channel for download")?;
    channel
        .exec(true, cmd.as_str())
        .await
        .with_context(|| format!("failed to start download of {resolved}"))?;

    let mut file = tokio::fs::File::create(local_path)
        .await
        .with_context(|| format!("cannot create {}", local_path.display()))?;

    let mut written: u64 = 0;
    let mut stderr = Vec::new();
    let mut code: Option<u32> = None;
    let mut last_log = std::time::Instant::now();

    loop {
        match channel.wait().await {
            Some(ChannelMsg::Data { ref data }) => {
                file.write_all(data).await?;
                written += data.len() as u64;
                if last_log.elapsed().as_secs() >= 3 {
                    tracing::info!(
                        "SSH download {}: {} MB",
                        resolved,
                        written / (1024 * 1024)
                    );
                    last_log = std::time::Instant::now();
                }
            }
            Some(ChannelMsg::ExtendedData { ref data, .. }) => stderr.extend_from_slice(data),
            Some(ChannelMsg::ExitStatus { exit_status }) => code = Some(exit_status),
            Some(ChannelMsg::Eof) | None => break,
            _ => {}
        }
    }

    file.flush().await?;

    if let Some(c) = code {
        if c != 0 {
            // Remove the partial file so the next poll does not treat a truncated DB as good.
            let _ = tokio::fs::remove_file(local_path).await;
            bail!(
                "download of {resolved} failed (exit {c}): {}",
                String::from_utf8_lossy(&stderr).trim()
            );
        }
    }

    if written == 0 {
        // Distinguish "empty file" from "cat never ran".
        tracing::warn!("downloaded 0 bytes from {resolved}");
    } else {
        tracing::info!(
            "SSH download complete {}: {} bytes",
            resolved,
            written
        );
    }

    Ok(())
}

async fn resolve_path(session: &mut Handle<AcceptAll>, remote_path: &str) -> Result<String> {
    if !(remote_path.starts_with("~/") || remote_path == "~") {
        return Ok(remote_path.to_string());
    }
    let home = exec_async(session, "echo $HOME")
        .await?
        .trim()
        .trim_end_matches('/')
        .to_string();
    if home.is_empty() {
        bail!("could not expand ~ on remote host");
    }
    if remote_path == "~" {
        Ok(home)
    } else {
        Ok(format!("{home}/{}", remote_path.trim_start_matches("~/")))
    }
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

pub fn require_password(password: &Option<String>) -> Result<&str> {
    password
        .as_deref()
        .filter(|p| !p.is_empty())
        .ok_or_else(|| anyhow!("password authentication selected but no password is stored"))
}
