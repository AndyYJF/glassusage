//! Native password SSH via `russh` — no PuTTY, no interactive TTY, no askpass hacks.
//!
//! Key / agent auth still goes through the system OpenSSH client in `ssh.rs`.
//!
//! A single multi-thread Tokio runtime and one SSH session are reused for the lifetime of
//! a sync, so listing / stat / download do not pay a fresh TCP + auth handshake each time.

use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use anyhow::{anyhow, bail, Context, Result};
use russh::client::{self, Handle};
use russh::ChannelMsg;
use tokio::io::AsyncWriteExt;
use tokio::runtime::Runtime;

const COMMAND_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

struct KnownHostVerifier {
    host: String,
    port: u16,
    path: PathBuf,
}

impl client::Handler for KnownHostVerifier {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &russh::keys::PublicKey,
    ) -> Result<bool, Self::Error> {
        match russh::keys::check_known_hosts_path(
            &self.host,
            self.port,
            server_public_key,
            &self.path,
        ) {
            Ok(true) => Ok(true),
            Ok(false) => {
                match russh::keys::known_hosts::learn_known_hosts_path(
                    &self.host,
                    self.port,
                    server_public_key,
                    &self.path,
                ) {
                    Ok(()) => Ok(true),
                    Err(error) => {
                        tracing::error!("could not persist SSH host key: {error}");
                        Ok(false)
                    }
                }
            }
            Err(error) => {
                tracing::error!("SSH host key verification failed: {error}");
                Ok(false)
            }
        }
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
    handle: Handle<KnownHostVerifier>,
}

impl PasswordSession {
    pub fn connect(
        host: &str,
        port: u16,
        username: &str,
        password: &str,
        known_hosts_path: &Path,
    ) -> Result<Self> {
        let handle = runtime().block_on(connect_async(
            host,
            port,
            username,
            password,
            known_hosts_path,
        ))?;
        Ok(Self { handle })
    }

    pub fn exec(&mut self, command: &str) -> Result<String> {
        runtime()
            .block_on(tokio::time::timeout(
                COMMAND_TIMEOUT,
                exec_async(&mut self.handle, command),
            ))
            .map_err(|_| {
                anyhow!(
                    "remote command timed out after {}s",
                    COMMAND_TIMEOUT.as_secs()
                )
            })?
    }

    pub fn download(&mut self, remote_path: &str, local_path: &Path) -> Result<()> {
        if let Some(dir) = local_path.parent() {
            std::fs::create_dir_all(dir).ok();
        }
        match runtime().block_on(tokio::time::timeout(
            COMMAND_TIMEOUT,
            download_async(&mut self.handle, remote_path, local_path),
        )) {
            Ok(result) => result,
            Err(_) => {
                std::fs::remove_file(local_path).ok();
                bail!("download timed out after {}s", COMMAND_TIMEOUT.as_secs())
            }
        }
    }
}

async fn connect_async(
    host: &str,
    port: u16,
    username: &str,
    password: &str,
    known_hosts_path: &Path,
) -> Result<Handle<KnownHostVerifier>> {
    // Large transfers (OpenClaw agent DBs) need room; keep the session alive for the
    // whole sync rather than treating quiet moments between commands as dead.
    let config = client::Config {
        inactivity_timeout: Some(std::time::Duration::from_secs(30 * 60)),
        window_size: 32 * 1024 * 1024,
        maximum_packet_size: 65_535,
        ..Default::default()
    };
    let config = Arc::new(config);

    let verifier = KnownHostVerifier {
        host: host.to_string(),
        port,
        path: known_hosts_path.to_path_buf(),
    };
    let mut session = client::connect(config, (host, port), verifier)
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

async fn exec_async(session: &mut Handle<KnownHostVerifier>, command: &str) -> Result<String> {
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

    let c = code.ok_or_else(|| anyhow!("SSH command ended without an exit status"))?;
    if c != 0 {
        bail!(
            "ssh exited with {c}: {}",
            String::from_utf8_lossy(&stderr).trim()
        );
    }

    Ok(String::from_utf8_lossy(&stdout).to_string())
}

/// Stream a remote file over an `exec` channel (`cat`). This is typically much faster
/// than the SFTP subsystem on long-haul links, and avoids a second subsystem handshake.
async fn download_async(
    session: &mut Handle<KnownHostVerifier>,
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
                    tracing::info!("SSH download {}: {} MB", resolved, written / (1024 * 1024));
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

    let Some(c) = code else {
        let _ = tokio::fs::remove_file(local_path).await;
        bail!("download of {resolved} ended without an exit status");
    };
    if c != 0 {
        // Remove the partial file so the next poll does not treat a truncated DB as good.
        let _ = tokio::fs::remove_file(local_path).await;
        bail!(
            "download of {resolved} failed (exit {c}): {}",
            String::from_utf8_lossy(&stderr).trim()
        );
    }

    if written == 0 {
        // Distinguish "empty file" from "cat never ran".
        tracing::warn!("downloaded 0 bytes from {resolved}");
    } else {
        tracing::info!("SSH download complete {}: {} bytes", resolved, written);
    }

    Ok(())
}

async fn resolve_path(
    session: &mut Handle<KnownHostVerifier>,
    remote_path: &str,
) -> Result<String> {
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
