//! SSH transport built on the OpenSSH client that ships with Windows 10 1809+.
//!
//! Using the system client rather than a bundled SSH library means `~/.ssh/config`
//! aliases, agent forwarding, hardware keys and `ProxyJump` all work for free, and no
//! OpenSSL toolchain is needed to build this app.
//!
//! Password authentication cannot use an interactive TTY (the app has none). That path
//! uses the pure-Rust `russh` client in [`super::password_ssh`] so PuTTY is not required.

use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use parking_lot::Mutex;

use super::password_ssh::{self, PasswordSession};
use super::RemoteInstance;

/// Commands are given a hard ceiling so a hung network never blocks a scheduler thread.
const CONNECT_TIMEOUT_SECS: u32 = 10;
const COMMAND_TIMEOUT: Duration = Duration::from_secs(120);

pub struct SshClient {
    instance: RemoteInstance,
    password: Option<String>,
    /// Reused for the whole sync so password mode does not re-authenticate per call.
    password_session: Mutex<Option<PasswordSession>>,
}

impl SshClient {
    pub fn new(instance: RemoteInstance, password: Option<String>) -> Self {
        Self {
            instance,
            password,
            password_session: Mutex::new(None),
        }
    }

    pub fn uses_password(&self) -> bool {
        self.instance.auth_mode == "password"
    }

    fn target(&self) -> String {
        format!("{}@{}", self.instance.username, self.instance.host)
    }

    fn with_password_session<R>(&self, f: impl FnOnce(&mut PasswordSession) -> Result<R>) -> Result<R> {
        let password = password_ssh::require_password(&self.password)?;
        let mut guard = self.password_session.lock();
        if guard.is_none() {
            tracing::info!(
                "SSH password session → {}@{}:{}",
                self.instance.username,
                self.instance.host,
                self.instance.port
            );
            *guard = Some(PasswordSession::connect(
                &self.instance.host,
                self.instance.port as u16,
                &self.instance.username,
                password,
            )?);
        }
        f(guard.as_mut().unwrap())
    }

    /// Base arguments shared by every OpenSSH invocation.
    ///
    /// `BatchMode=yes` is essential: it turns any prompt (unknown host key, password
    /// request) into an immediate failure instead of a process that waits forever.
    fn ssh_args(&self) -> Vec<String> {
        let mut args = vec![
            "-o".into(),
            "BatchMode=yes".into(),
            "-o".into(),
            format!("ConnectTimeout={CONNECT_TIMEOUT_SECS}"),
            "-o".into(),
            "StrictHostKeyChecking=accept-new".into(),
            "-p".into(),
            self.instance.port.to_string(),
        ];
        if self.instance.auth_mode == "key" {
            if let Some(key) = self.instance.key_path.as_ref().filter(|k| !k.trim().is_empty()) {
                args.push("-i".into());
                args.push(key.clone());
                // Do not fall back to agent keys when an explicit key was chosen.
                args.push("-o".into());
                args.push("IdentitiesOnly=yes".into());
            }
        }
        args
    }

    /// Run a command on the remote host and return stdout.
    pub fn exec(&self, remote_command: &str) -> Result<String> {
        if self.uses_password() {
            return self.with_password_session(|s| s.exec(remote_command));
        }

        let program = locate("ssh.exe")?;
        let mut args = self.ssh_args();
        args.push(self.target());
        args.push(remote_command.to_string());

        let output = run(&program, &args)?;
        if !output.status.success() {
            bail!(
                "ssh exited with {}: {}",
                output.status.code().unwrap_or(-1),
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    /// Copy one remote file to a local path.
    pub fn download(&self, remote_path: &str, local_path: &Path) -> Result<()> {
        if self.uses_password() {
            return self.with_password_session(|s| s.download(remote_path, local_path));
        }

        if let Some(dir) = local_path.parent() {
            std::fs::create_dir_all(dir).ok();
        }
        let remote_spec = format!("{}:{}", self.target(), shell_quote_scp(remote_path));

        let mut args = vec![
            "-o".to_string(),
            "BatchMode=yes".to_string(),
            "-o".to_string(),
            format!("ConnectTimeout={CONNECT_TIMEOUT_SECS}"),
            "-o".to_string(),
            "StrictHostKeyChecking=accept-new".to_string(),
            "-P".to_string(),
            self.instance.port.to_string(),
        ];
        if self.instance.auth_mode == "key" {
            if let Some(key) = self.instance.key_path.as_ref().filter(|k| !k.trim().is_empty()) {
                args.push("-i".into());
                args.push(key.clone());
            }
        }
        args.push(remote_spec);
        args.push(local_path.to_string_lossy().to_string());

        let output = run(&locate("scp.exe")?, &args)?;
        if !output.status.success() {
            bail!(
                "download failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        Ok(())
    }

    /// `(mtime_seconds, size_bytes)` for a remote file, or `None` when it is absent.
    pub fn stat(&self, remote_path: &str) -> Result<Option<(i64, i64)>> {
        let out = self.exec(&format!(
            "stat -c '%Y %s' {} 2>/dev/null || true",
            shell_quote(remote_path)
        ))?;
        let line = out.trim();
        if line.is_empty() {
            return Ok(None);
        }
        let mut parts = line.split_whitespace();
        let mtime = parts.next().and_then(|s| s.parse::<i64>().ok());
        let size = parts.next().and_then(|s| s.parse::<i64>().ok());
        Ok(match (mtime, size) {
            (Some(m), Some(s)) => Some((m, s)),
            _ => None,
        })
    }

    pub fn remote_home(&self) -> Result<String> {
        let out = self.exec("echo $HOME")?;
        let home = out.trim().trim_end_matches('/').to_string();
        if home.is_empty() {
            bail!("could not determine remote home directory");
        }
        Ok(home)
    }

    pub fn has_sqlite3(&self) -> bool {
        self.exec("command -v sqlite3 >/dev/null 2>&1 && echo yes || echo no")
            .map(|o| o.trim() == "yes")
            .unwrap_or(false)
    }

    pub fn list_dir(&self, remote_path: &str) -> Result<Vec<String>> {
        let out = self.exec(&format!("ls -1 {} 2>/dev/null || true", shell_quote(remote_path)))?;
        Ok(out
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect())
    }

    /// Pull a WAL-mode SQLite database as a consistent snapshot.
    ///
    /// With `sqlite3` present the online backup API produces a transactionally clean
    /// single file. Otherwise the main file and its `-wal`/`-shm` sidecars are fetched
    /// together and rusqlite replays the log locally; those three transfers are not
    /// atomic, so a torn read is possible and the caller discards the snapshot when it
    /// fails to open, picking it up on the next poll.
    pub fn snapshot_sqlite(&self, remote_db: &str, local_db: &Path, use_backup: bool) -> Result<()> {
        if use_backup {
            let tmp = format!("/tmp/glassusage-snap-{}.db", std::process::id());
            let cmd = format!(
                "rm -f {tmp} && sqlite3 {src} \".backup '{tmp}'\"",
                tmp = tmp,
                src = shell_quote(remote_db)
            );
            match self.exec(&cmd) {
                Ok(_) => {
                    let result = self.download(&tmp, local_db);
                    // Always clean up, even if the transfer failed.
                    let _ = self.exec(&format!("rm -f {tmp}"));
                    return result;
                }
                Err(e) => {
                    tracing::warn!("sqlite3 .backup unavailable, falling back to file copy: {e}");
                }
            }
        }

        self.download(remote_db, local_db)?;
        for suffix in ["-wal", "-shm"] {
            let remote_side = format!("{remote_db}{suffix}");
            let local_side = local_db.with_file_name(format!(
                "{}{suffix}",
                local_db.file_name().unwrap_or_default().to_string_lossy()
            ));
            // Sidecars are optional; a database checkpointed at rest has none.
            if matches!(self.stat(&remote_side), Ok(Some(_))) {
                let _ = self.download(&remote_side, &local_side);
            } else {
                std::fs::remove_file(&local_side).ok();
            }
        }
        Ok(())
    }
}

fn run(program: &str, args: &[String]) -> Result<std::process::Output> {
    let mut child = Command::new(program);
    child
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    #[cfg(windows)]
    {
        // CREATE_NO_WINDOW: never flash a console while polling in the background.
        use std::os::windows::process::CommandExt;
        child.creation_flags(0x0800_0000);
    }

    let mut handle = child.spawn().map_err(|e| anyhow!("failed to start {program}: {e}"))?;

    // `Child::wait_with_output` has no timeout, so poll and kill on overrun.
    let deadline = std::time::Instant::now() + COMMAND_TIMEOUT;
    loop {
        if let Some(_status) = handle.try_wait()? {
            return Ok(handle.wait_with_output()?);
        }
        if std::time::Instant::now() > deadline {
            let _ = handle.kill();
            bail!("remote command timed out after {}s", COMMAND_TIMEOUT.as_secs());
        }
        std::thread::sleep(Duration::from_millis(80));
    }
}

fn locate(exe: &str) -> Result<String> {
    // Prefer the copy in System32 so a shadowed `ssh` on PATH cannot be picked up.
    if let Some(sysroot) = std::env::var_os("SystemRoot") {
        let p = Path::new(&sysroot).join("System32").join("OpenSSH").join(exe);
        if p.is_file() {
            return Ok(p.to_string_lossy().to_string());
        }
    }
    if which(exe).is_some() {
        return Ok(exe.to_string());
    }
    bail!("{exe} not found. Install the Windows OpenSSH Client optional feature.")
}

fn which(exe: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(exe))
        .find(|p| p.is_file())
        .map(|p| p.to_string_lossy().to_string())
}

/// Single-quote a value for a POSIX remote shell.
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// scp parses the remote path with a shell on the far side, but the local argument must
/// not be quoted, so only the characters that would break parsing are escaped.
fn shell_quote_scp(s: &str) -> String {
    s.replace(' ', "\\ ")
}
