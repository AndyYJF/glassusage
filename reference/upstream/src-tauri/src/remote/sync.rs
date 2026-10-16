//! Remote instance scheduling: stat, snapshot, parse.

use std::collections::HashSet;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use serde::Serialize;
use tauri::{AppHandle, Emitter};

use super::ssh::SshClient;
use super::{RemoteInstance, RemoteInstanceInput};
use crate::collectors::{collector_by_id, ScanCtx};
use crate::model::HealthStatus;
use crate::state::{AppState, SourceStatusEvent};

/// Backoff bounds for a failing instance, so a permanently unreachable host settles into
/// one retry every five minutes rather than hammering the network.
const BACKOFF_START: Duration = Duration::from_secs(30);
const BACKOFF_MAX: Duration = Duration::from_secs(300);

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TestStep {
    pub label: String,
    pub ok: bool,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TestReport {
    pub ok: bool,
    pub steps: Vec<TestStep>,
}

pub fn spawn_scheduler(app: AppHandle, state: Arc<AppState>) {
    tauri::async_runtime::spawn(async move {
        // Each instance gets its own task so a slow host cannot delay the others.
        let mut started: HashSet<String> = HashSet::new();
        let (finished_tx, mut finished_rx) = tokio::sync::mpsc::unbounded_channel();
        loop {
            while let Ok(name) = finished_rx.try_recv() {
                started.remove(&name);
            }
            let instances = state.store.list_remote().unwrap_or_default();
            for inst in instances.into_iter().filter(|i| i.enabled) {
                if started.contains(&inst.name) {
                    continue;
                }
                started.insert(inst.name.clone());
                spawn_instance_task(
                    app.clone(),
                    state.clone(),
                    inst.name.clone(),
                    finished_tx.clone(),
                );
            }
            tokio::time::sleep(Duration::from_secs(20)).await;
        }
    });
}

fn spawn_instance_task(
    app: AppHandle,
    state: Arc<AppState>,
    name: String,
    finished: tokio::sync::mpsc::UnboundedSender<String>,
) {
    tauri::async_runtime::spawn(async move {
        let mut backoff = BACKOFF_START;
        while let Some(inst) = state
            .store
            .list_remote()
            .unwrap_or_default()
            .into_iter()
            .find(|i| i.name == name)
        {
            if !inst.enabled {
                tokio::time::sleep(Duration::from_secs(30)).await;
                continue;
            }

            let poll = Duration::from_secs(inst.poll_secs.clamp(60, 3600) as u64);
            let app2 = app.clone();
            let state2 = state.clone();
            let name2 = name.clone();
            // SSH and SQLite work is blocking, so keep it off the async runtime.
            let result =
                tauri::async_runtime::spawn_blocking(move || sync_instance(&app2, &state2, &name2))
                    .await
                    .unwrap_or_else(|e| Err(anyhow!("sync task panicked: {e}")));

            match result {
                Ok(_) => {
                    backoff = BACKOFF_START;
                    tokio::time::sleep(poll).await;
                }
                Err(e) => {
                    tracing::warn!("remote {name} sync failed: {e}");
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(BACKOFF_MAX);
                }
            }
        }
        let _ = finished.send(name);
    });
}

/// One full pull for an instance: enumerate remote files, snapshot the changed ones,
/// then run the normal collector against the snapshot directory.
pub fn sync_instance(app: &AppHandle, state: &AppState, name: &str) -> Result<usize> {
    let inst = state
        .store
        .list_remote()?
        .into_iter()
        .find(|i| i.name == name)
        .ok_or_else(|| anyhow!("no such instance: {name}"))?;
    inst.validate()?;

    emit_status(app, &inst, HealthStatus::Polling, None);

    let result = (|| -> Result<usize> {
        let client = connect(state, &inst)?;
        let home = resolve_home(state, &client, &inst)?;
        let snapshot_dir = state.data_dir.join("remote").join(&inst.name);
        std::fs::create_dir_all(&snapshot_dir)?;

        let downloaded = pull_snapshot(state, &client, &inst, &home, &snapshot_dir)?;
        // Always parse: collectors keep their own watermarks, and a zero-download poll
        // must still pick up newly-supported formats in files already on disk.
        let added = parse_snapshot(app, state, &inst, &snapshot_dir)?;
        tracing::debug!(
            "remote {}: downloaded {downloaded}, changed {added}",
            inst.name
        );
        Ok(added)
    })();

    match result {
        Ok(n) => {
            emit_status(app, &inst, HealthStatus::Polling, None);
            Ok(n)
        }
        Err(e) => {
            let msg = e.to_string();
            let _ = state
                .store
                .record_status(&inst.agent, &inst.name, 0, 0, &[], Some(&msg));
            emit_status(app, &inst, HealthStatus::Error, Some(msg.clone()));
            Err(e)
        }
    }
}

fn connect(state: &AppState, inst: &RemoteInstance) -> Result<SshClient> {
    let password = if inst.auth_mode == "password" {
        state
            .store
            .remote_secret(&inst.name)?
            .and_then(|b| crate::dpapi::unprotect_str(&b).ok())
    } else {
        None
    };
    Ok(SshClient::new(
        inst.clone(),
        password,
        state.data_dir.join("ssh-known-hosts"),
    ))
}

fn resolve_home(state: &AppState, client: &SshClient, inst: &RemoteInstance) -> Result<String> {
    if let Some(h) = inst.remote_home.as_ref().filter(|h| !h.trim().is_empty()) {
        return Ok(h.trim_end_matches('/').to_string());
    }
    let home = client.remote_home()?;
    // Cache it so later polls skip the extra round trip.
    let _ = state.store.set_remote_home(&inst.name, &home);
    Ok(home)
}

/// Download every remote database whose mtime/size changed. Returns how many files were
/// actually transferred.
fn pull_snapshot(
    state: &AppState,
    client: &SshClient,
    inst: &RemoteInstance,
    home: &str,
    snapshot_dir: &std::path::Path,
) -> Result<usize> {
    let use_backup = client.has_sqlite3();
    let mut downloaded = 0;

    let remote_files = enumerate_remote_files(client, inst, home)?;
    if remote_files.is_empty() {
        return Err(anyhow!(
            "no {} data found on the remote host (looked under {home})",
            inst.agent
        ));
    }

    tracing::info!(
        "remote {}: {} file(s) to consider (backup={})",
        inst.name,
        remote_files.len(),
        use_backup
    );

    for (remote_path, local_rel) in remote_files {
        let Some((mtime, size)) = client.stat(&remote_path)? else {
            continue;
        };
        let key = format!("remote:{}:{}", inst.name, remote_path);
        let prev = state.store.get_scan_state(&inst.agent, &inst.name, &key);
        let local_path = safe_snapshot_path(snapshot_dir, &local_rel)?;
        let sqlite_file = is_sqlite_path(&local_path);

        // Skip the transfer when neither timestamp nor size moved and we still hold the
        // previous snapshot. A zero-length leftover from a cancelled pull must not count.
        if let Some(p) = &prev {
            let local_ok = local_path
                .metadata()
                .map(|metadata| {
                    if sqlite_file {
                        metadata.len() > 0
                    } else {
                        metadata.len() == size as u64
                    }
                })
                .unwrap_or(false);
            if p.mtime_ms == mtime * 1000 && p.offset == size && local_path.exists() && local_ok {
                continue;
            }
        }

        tracing::info!(
            "remote {}: pulling {} ({} bytes) → {}",
            inst.name,
            remote_path,
            size,
            local_rel
        );
        download_verified(client, &remote_path, &local_path, size, use_backup)?;
        downloaded += 1;

        let _ = state.store.set_scan_state(
            &inst.agent,
            &inst.name,
            &key,
            &crate::model::ScanState {
                offset: size,
                mtime_ms: mtime * 1000,
                extra: Some(local_rel.clone()),
            },
        );
    }
    Ok(downloaded)
}

fn safe_snapshot_path(snapshot_dir: &Path, relative: &str) -> Result<PathBuf> {
    let relative_path = Path::new(relative);
    if relative_path.as_os_str().is_empty()
        || relative_path.is_absolute()
        || relative.contains('\\')
    {
        return Err(anyhow!("unsafe remote snapshot path: {relative}"));
    }
    for component in relative_path.components() {
        if !matches!(component, Component::Normal(_)) {
            return Err(anyhow!("unsafe remote snapshot path: {relative}"));
        }
    }
    Ok(snapshot_dir.join(relative_path))
}

fn validate_remote_component(component: &str) -> Result<()> {
    if component.is_empty()
        || matches!(component, "." | "..")
        || component.contains(['/', '\\', '\0', '\r', '\n'])
    {
        return Err(anyhow!("unsafe remote filename: {component:?}"));
    }
    Ok(())
}

fn is_sqlite_path(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            extension.eq_ignore_ascii_case("sqlite") || extension.eq_ignore_ascii_case("db")
        })
}

fn sidecar_path(path: &Path, suffix: &str) -> PathBuf {
    path.with_file_name(format!(
        "{}{suffix}",
        path.file_name().unwrap_or_default().to_string_lossy()
    ))
}

fn replace_download_set(entries: &[(Option<PathBuf>, PathBuf)]) -> Result<()> {
    let mut backups: Vec<(PathBuf, PathBuf)> = Vec::new();
    for (_, target) in entries {
        let backup = target.with_file_name(format!(
            ".{}.glassusage-previous",
            target.file_name().unwrap_or_default().to_string_lossy()
        ));
        std::fs::remove_file(&backup).ok();
        if target.exists() {
            if let Err(error) = std::fs::rename(target, &backup) {
                for (original, previous) in backups.iter().rev() {
                    let _ = std::fs::rename(previous, original);
                }
                return Err(error.into());
            }
            backups.push((target.clone(), backup));
        }
    }

    let mut installed: Vec<PathBuf> = Vec::new();
    for (staged, target) in entries {
        let Some(staged) = staged else {
            continue;
        };
        if let Err(error) = std::fs::rename(staged, target) {
            for path in installed.iter().rev() {
                std::fs::remove_file(path).ok();
            }
            for (original, previous) in backups.iter().rev() {
                if previous.exists() {
                    let _ = std::fs::rename(previous, original);
                }
            }
            return Err(error.into());
        }
        installed.push(target.clone());
    }

    for (_, backup) in backups {
        std::fs::remove_file(backup).ok();
    }
    Ok(())
}

fn download_verified(
    client: &SshClient,
    remote_path: &str,
    local_path: &Path,
    expected_size: i64,
    use_backup: bool,
) -> Result<()> {
    let parent = local_path
        .parent()
        .ok_or_else(|| anyhow!("snapshot target has no parent"))?;
    std::fs::create_dir_all(parent)?;
    let temp = local_path.with_file_name(format!(
        ".{}.glassusage-download-{}-{}",
        local_path.file_name().unwrap_or_default().to_string_lossy(),
        std::process::id(),
        crate::store::now_ms()
    ));

    let result = (|| -> Result<()> {
        if is_sqlite_path(local_path) {
            client.snapshot_sqlite(remote_path, &temp, use_backup)?;
            let connection = rusqlite::Connection::open_with_flags(
                &temp,
                rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
                    | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
            )?;
            let check: String = connection.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
            if check != "ok" {
                return Err(anyhow!(
                    "downloaded SQLite snapshot failed quick_check: {check}"
                ));
            }
            drop(connection);

            let mut entries = vec![(Some(temp.clone()), local_path.to_path_buf())];
            for suffix in ["-wal", "-shm"] {
                let temp_sidecar = sidecar_path(&temp, suffix);
                let target_sidecar = sidecar_path(local_path, suffix);
                entries.push((
                    temp_sidecar.exists().then_some(temp_sidecar),
                    target_sidecar,
                ));
            }
            replace_download_set(&entries)?;
        } else {
            client.download(remote_path, &temp)?;
            let actual_size = temp.metadata()?.len();
            if expected_size >= 0 && actual_size != expected_size as u64 {
                return Err(anyhow!(
                    "downloaded file size mismatch: expected {expected_size}, got {actual_size}"
                ));
            }
            replace_download_set(&[(Some(temp.clone()), local_path.to_path_buf())])?;
        }
        Ok(())
    })();

    if result.is_err() {
        std::fs::remove_file(&temp).ok();
        for suffix in ["-wal", "-shm"] {
            std::fs::remove_file(sidecar_path(&temp, suffix)).ok();
        }
    }
    result
}

/// `(remote absolute path, path relative to the local snapshot dir)`.
fn enumerate_remote_files(
    client: &SshClient,
    inst: &RemoteInstance,
    home: &str,
) -> Result<Vec<(String, String)>> {
    let mut out = Vec::new();
    match inst.agent.as_str() {
        "hermes" => {
            let base = inst
                .remote_path
                .as_ref()
                .filter(|p| !p.trim().is_empty())
                .cloned()
                .unwrap_or_else(|| format!("{home}/.hermes/state.db"));
            if client.stat(&base)?.is_some() {
                out.push((base.clone(), "state.db".to_string()));
            }
            // Profiles each hold their own database.
            let profiles_dir = format!("{home}/.hermes/profiles");
            for profile in client.list_dir(&profiles_dir)? {
                validate_remote_component(&profile)?;
                let db = format!("{profiles_dir}/{profile}/state.db");
                if client.stat(&db)?.is_some() {
                    out.push((db, format!("profiles/{profile}/state.db")));
                }
            }
        }
        "openclaw" => {
            let root = inst
                .remote_path
                .as_ref()
                .filter(|p| !p.trim().is_empty())
                .cloned()
                .unwrap_or_else(|| format!("{home}/.openclaw"));
            for agent_id in client.list_dir(&format!("{root}/agents"))? {
                validate_remote_component(&agent_id)?;
                // Prefer any sqlite under the agent folder that might hold transcripts.
                // `openclaw-agent.sqlite` on recent builds is often only the memory index —
                // usage lives in the session JSONL files below.
                let agent_dir = format!("{root}/agents/{agent_id}/agent");
                for f in client.list_dir(&agent_dir)? {
                    validate_remote_component(&f)?;
                    if (f.ends_with(".sqlite") || f.ends_with(".db"))
                        && !f.contains(".reindex-lock.")
                    {
                        out.push((
                            format!("{agent_dir}/{f}"),
                            format!("agents/{agent_id}/agent/{f}"),
                        ));
                    }
                }

                // Session transcripts are the primary usage source for current OpenClaw.
                // Always pull them on remote sync (not only when "import archives" is on).
                let sessions = format!("{root}/agents/{agent_id}/sessions");
                for f in client.list_dir(&sessions)? {
                    validate_remote_component(&f)?;
                    if f.ends_with(".jsonl") {
                        out.push((
                            format!("{sessions}/{f}"),
                            format!("agents/{agent_id}/sessions/{f}"),
                        ));
                    }
                }

                // Optional: rotated / archived JSONL elsewhere under the agent.
                if inst.import_archives {
                    let archives = format!("{root}/agents/{agent_id}/archives");
                    for f in client.list_dir(&archives)? {
                        validate_remote_component(&f)?;
                        if f.ends_with(".jsonl") {
                            out.push((
                                format!("{archives}/{f}"),
                                format!("agents/{agent_id}/archives/{f}"),
                            ));
                        }
                    }
                }
            }
        }
        other => return Err(anyhow!("unsupported remote agent type: {other}")),
    }
    Ok(out)
}

/// Feed the downloaded snapshot to the ordinary collector, tagged with the instance name.
fn parse_snapshot(
    app: &AppHandle,
    state: &AppState,
    inst: &RemoteInstance,
    snapshot_dir: &Path,
) -> Result<usize> {
    let collector =
        collector_by_id(&inst.agent).ok_or_else(|| anyhow!("unknown agent {}", inst.agent))?;
    let settings = state.settings.get();
    let ctx = ScanCtx {
        store: &state.store,
        pricing: &state.pricing,
        settings: &settings,
        instance: inst.name.clone(),
        root_override: Some(snapshot_dir.to_path_buf()),
    };

    let report = collector.scan(&ctx)?;
    let outcome =
        state
            .store
            .ingest_scan(&report.events, collector.write_mode(), &report.states)?;
    state.live.push(&outcome.deltas);

    let _ = state.store.record_status(
        &inst.agent,
        &inst.name,
        report.files_seen,
        report.skipped,
        &report.detected_paths,
        None,
    );

    if outcome.changed > 0 {
        let _ = app.emit(
            "usage-updated",
            serde_json::json!({
                "source": inst.agent,
                "instance": inst.name,
                "added": outcome.changed,
            }),
        );
    }
    Ok(outcome.changed)
}

/// Four-step preflight run before an instance is saved: reachability, data path,
/// snapshot transfer, and a parse that must produce a usable row count.
pub fn test_instance(state: &AppState, input: &RemoteInstanceInput) -> TestReport {
    let mut steps = Vec::new();
    if let Err(error) = input.validate() {
        steps.push(TestStep {
            label: "Configuration".into(),
            ok: false,
            detail: error.to_string(),
        });
        return TestReport { ok: false, steps };
    }
    let inst: RemoteInstance = input.into();

    // A password typed into the dialog is used directly; an existing saved secret is
    // decrypted only if the field was left blank.
    let password = match input.password.clone() {
        Some(p) if !p.is_empty() => Some(p),
        _ => state
            .store
            .remote_secret(&inst.name)
            .ok()
            .flatten()
            .and_then(|b| crate::dpapi::unprotect_str(&b).ok()),
    };
    let client = SshClient::new(
        inst.clone(),
        password,
        state.data_dir.join("ssh-known-hosts"),
    );

    let home = match client.remote_home() {
        Ok(h) => {
            steps.push(TestStep {
                label: "SSH connection".into(),
                ok: true,
                detail: format!("connected as {}@{}, home = {h}", inst.username, inst.host),
            });
            h
        }
        Err(e) => {
            steps.push(TestStep {
                label: "SSH connection".into(),
                ok: false,
                detail: e.to_string(),
            });
            return TestReport { ok: false, steps };
        }
    };

    let files = match enumerate_remote_files(&client, &inst, &home) {
        Ok(f) if !f.is_empty() => {
            steps.push(TestStep {
                label: "Data path".into(),
                ok: true,
                detail: format!("found {} database file(s)", f.len()),
            });
            f
        }
        Ok(_) => {
            steps.push(TestStep {
                label: "Data path".into(),
                ok: false,
                detail: format!("no {} data under {home}", inst.agent),
            });
            return TestReport { ok: false, steps };
        }
        Err(e) => {
            steps.push(TestStep {
                label: "Data path".into(),
                ok: false,
                detail: e.to_string(),
            });
            return TestReport { ok: false, steps };
        }
    };

    // Snapshot into a scratch directory so a test never disturbs live data.
    let test_dir = state
        .data_dir
        .join("remote")
        .join(format!("{}__test", inst.name));
    let _ = std::fs::remove_dir_all(&test_dir);
    if let Err(e) = std::fs::create_dir_all(&test_dir) {
        steps.push(TestStep {
            label: "Snapshot".into(),
            ok: false,
            detail: e.to_string(),
        });
        return TestReport { ok: false, steps };
    }

    let use_backup = client.has_sqlite3();
    let (remote_path, local_rel) = &files[0];
    let local_path = safe_snapshot_path(&test_dir, local_rel);
    let snapshot = local_path.and_then(|local_path| {
        download_verified(&client, remote_path, &local_path, -1, use_backup)
    });
    match snapshot {
        Ok(_) => steps.push(TestStep {
            label: "Snapshot".into(),
            ok: true,
            detail: if use_backup {
                "pulled a consistent snapshot via sqlite3 .backup".into()
            } else {
                "sqlite3 not available on the host; copied the database with its WAL sidecars"
                    .into()
            },
        }),
        Err(e) => {
            steps.push(TestStep {
                label: "Snapshot".into(),
                ok: false,
                detail: e.to_string(),
            });
            return TestReport { ok: false, steps };
        }
    }

    let settings = state.settings.get();
    let parse = collector_by_id(&inst.agent).map(|c| {
        let ctx = ScanCtx {
            store: &state.store,
            pricing: &state.pricing,
            settings: &settings,
            // A throwaway instance name keeps test rows out of the real dataset.
            instance: format!("{}__test", inst.name),
            root_override: Some(test_dir.clone()),
        };
        c.scan(&ctx)
    });

    match parse {
        Some(Ok(report)) => steps.push(TestStep {
            label: "Parse".into(),
            ok: true,
            detail: format!(
                "read {} usage record(s) from {} file(s)",
                report.events.len(),
                report.files_seen
            ),
        }),
        Some(Err(e)) => steps.push(TestStep {
            label: "Parse".into(),
            ok: false,
            detail: e.to_string(),
        }),
        None => steps.push(TestStep {
            label: "Parse".into(),
            ok: false,
            detail: format!("no collector for agent type {}", inst.agent),
        }),
    }

    // Clean up the scratch snapshot and its watermarks.
    let _ = std::fs::remove_dir_all(&test_dir);
    let _ = state
        .store
        .clear_scan_state(&inst.agent, Some(&format!("{}__test", inst.name)));
    let _ = state
        .store
        .delete_source(&inst.agent, Some(&format!("{}__test", inst.name)));

    let ok = steps.iter().all(|s| s.ok);
    TestReport { ok, steps }
}

fn emit_status(
    app: &AppHandle,
    inst: &RemoteInstance,
    status: HealthStatus,
    error: Option<String>,
) {
    let _ = app.emit(
        "source-status",
        SourceStatusEvent {
            source: inst.agent.clone(),
            instance: inst.name.clone(),
            status,
            error,
        },
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_paths_cannot_escape_the_instance_directory() {
        let root = Path::new(r"C:\data\remote\safe");
        assert!(safe_snapshot_path(root, "agents/a/session.jsonl").is_ok());
        for relative in [
            "../outside.db",
            r"..\outside.db",
            r"agents\a\..\outside.db",
            r"C:\outside.db",
            "/outside.db",
        ] {
            assert!(
                safe_snapshot_path(root, relative).is_err(),
                "{relative} should be rejected"
            );
        }
    }

    #[test]
    fn replacing_a_snapshot_removes_stale_sidecars_as_one_set() {
        let root = std::env::temp_dir().join(format!(
            "glassusage-snapshot-replace-{}-{}",
            std::process::id(),
            crate::store::now_ms()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let target = root.join("usage.db");
        let target_wal = sidecar_path(&target, "-wal");
        let staged = root.join("staged.db");
        std::fs::write(&target, b"old").unwrap();
        std::fs::write(&target_wal, b"stale").unwrap();
        std::fs::write(&staged, b"new").unwrap();

        replace_download_set(&[(Some(staged), target.clone()), (None, target_wal.clone())])
            .unwrap();

        assert_eq!(std::fs::read(&target).unwrap(), b"new");
        assert!(!target_wal.exists());
        std::fs::remove_dir_all(root).unwrap();
    }
}
