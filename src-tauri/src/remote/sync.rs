//! Remote instance scheduling: stat, snapshot, parse.

use std::path::PathBuf;
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
        let mut started: Vec<String> = Vec::new();
        loop {
            let instances = state.store.list_remote().unwrap_or_default();
            for inst in instances.into_iter().filter(|i| i.enabled) {
                if started.contains(&inst.name) {
                    continue;
                }
                started.push(inst.name.clone());
                spawn_instance_task(app.clone(), state.clone(), inst.name.clone());
            }
            tokio::time::sleep(Duration::from_secs(20)).await;
        }
    });
}

fn spawn_instance_task(app: AppHandle, state: Arc<AppState>, name: String) {
    tauri::async_runtime::spawn(async move {
        let mut backoff = BACKOFF_START;
        loop {
            let Some(inst) = state
                .store
                .list_remote()
                .unwrap_or_default()
                .into_iter()
                .find(|i| i.name == name)
            else {
                return; // deleted
            };
            if !inst.enabled {
                tokio::time::sleep(Duration::from_secs(30)).await;
                continue;
            }

            let poll = Duration::from_secs(inst.poll_secs.clamp(60, 3600) as u64);
            let app2 = app.clone();
            let state2 = state.clone();
            let name2 = name.clone();
            // SSH and SQLite work is blocking, so keep it off the async runtime.
            let result = tauri::async_runtime::spawn_blocking(move || sync_instance(&app2, &state2, &name2))
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
        if downloaded == 0 && added == 0 {
            let _ = state
                .store
                .record_status(&inst.agent, &inst.name, 0, 0, &[home.clone()], None);
            emit_status(app, &inst, HealthStatus::Polling, None);
        }
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
    Ok(SshClient::new(inst.clone(), password))
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
    let use_backup = !client.uses_password() && client.has_sqlite3();
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
        let local_path = snapshot_dir.join(&local_rel);

        // Skip the transfer when neither timestamp nor size moved and we still hold the
        // previous snapshot. A zero-length leftover from a cancelled pull must not count.
        if let Some(p) = &prev {
            if p.mtime_ms == mtime * 1000
                && p.offset == size
                && local_path.exists()
                && local_path.metadata().map(|m| m.len() > 0).unwrap_or(false)
            {
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
        // Drop any truncated leftover before starting so a crash mid-transfer is obvious.
        let _ = std::fs::remove_file(&local_path);

        client.snapshot_sqlite(&remote_path, &local_path, use_backup)?;
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

/// `(remote absolute path, path relative to the local snapshot dir)`.
fn enumerate_remote_files(client: &SshClient, inst: &RemoteInstance, home: &str) -> Result<Vec<(String, String)>> {
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
                // Prefer any sqlite under the agent folder that might hold transcripts.
                // `openclaw-agent.sqlite` on recent builds is often only the memory index —
                // usage lives in the session JSONL files below.
                let agent_dir = format!("{root}/agents/{agent_id}/agent");
                for f in client.list_dir(&agent_dir)? {
                    if f.ends_with(".sqlite") || f.ends_with(".db") {
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
    snapshot_dir: &PathBuf,
) -> Result<usize> {
    let collector = collector_by_id(&inst.agent).ok_or_else(|| anyhow!("unknown agent {}", inst.agent))?;
    let settings = state.settings.get();
    let ctx = ScanCtx {
        store: &state.store,
        pricing: &state.pricing,
        settings: &settings,
        instance: inst.name.clone(),
        root_override: Some(snapshot_dir.clone()),
    };

    let report = collector.scan(&ctx)?;
    let outcome = state.store.insert_events(&report.events, collector.write_mode())?;
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
    let client = SshClient::new(inst.clone(), password);

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
    let test_dir = state.data_dir.join("remote").join(format!("{}__test", inst.name));
    let _ = std::fs::remove_dir_all(&test_dir);
    if let Err(e) = std::fs::create_dir_all(&test_dir) {
        steps.push(TestStep {
            label: "Snapshot".into(),
            ok: false,
            detail: e.to_string(),
        });
        return TestReport { ok: false, steps };
    }

    let use_backup = !client.uses_password() && client.has_sqlite3();
    let (remote_path, local_rel) = &files[0];
    match client.snapshot_sqlite(remote_path, &test_dir.join(local_rel), use_backup) {
        Ok(_) => steps.push(TestStep {
            label: "Snapshot".into(),
            ok: true,
            detail: if use_backup {
                "pulled a consistent snapshot via sqlite3 .backup".into()
            } else {
                "sqlite3 not available on the host; copied the database with its WAL sidecars".into()
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
    let _ = state.store.clear_scan_state(&inst.agent, Some(&format!("{}__test", inst.name)));
    let _ = state.store.delete_source(&inst.agent, Some(&format!("{}__test", inst.name)));

    let ok = steps.iter().all(|s| s.ok);
    TestReport { ok, steps }
}

fn emit_status(app: &AppHandle, inst: &RemoteInstance, status: HealthStatus, error: Option<String>) {
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
