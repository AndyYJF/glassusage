/**
 * Remote Hermes / OpenClaw instances.
 *
 * Nothing is installed on the remote host: the backend pulls a consistent SQLite snapshot
 * over SSH and hands it to the same collector used for local data. The connection test is
 * step-by-step because "it doesn't work" is almost always one specific step — auth, a
 * missing path, or a locked database.
 */
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Check, Pencil, Plus, RefreshCw, Trash2, X } from "lucide-react";

import { GlassButton } from "../glass/GlassButton";
import { GlassSwitch } from "../glass/GlassSwitch";
import { api } from "../../lib/api";
import { useRemoteInstances } from "../../lib/hooks";
import { useT } from "../../lib/i18n";
import { useUi } from "../../lib/store";
import type { RemoteInstance, RemoteInstanceInput, TestReport } from "../../lib/types";

const BLANK: RemoteInstanceInput = {
  name: "",
  agent: "hermes",
  host: "",
  port: 22,
  username: "",
  authMode: "key",
  keyPath: null,
  password: "",
  remoteHome: null,
  remotePath: null,
  pollSecs: 300,
  importArchives: false,
  enabled: true,
};

function Field({
  label,
  value,
  onChange,
  placeholder,
  type = "text",
  width = "flex-1",
  disabled = false,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  type?: string;
  width?: string;
  disabled?: boolean;
}) {
  return (
    <label className={`flex min-w-0 flex-col gap-1 ${width}`}>
      <span className="text-[0.625rem] font-semibold uppercase tracking-[0.06em] text-[rgb(var(--text-faint))]">
        {label}
      </span>
      <input
        type={type}
        value={value}
        spellCheck={false}
        disabled={disabled}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        className="no-drag min-w-0 rounded-lg border border-white/8 bg-black/15 px-2 py-1 text-[0.75rem] outline-none placeholder:text-[rgb(var(--text-faint))] focus:border-[rgb(var(--accent)/0.6)] disabled:opacity-55"
      />
    </label>
  );
}

export function RemoteInstances() {
  const { t } = useT();
  const qc = useQueryClient();
  const notify = useUi((s) => s.notify);
  const { data: instances } = useRemoteInstances();

  const [draft, setDraft] = useState<RemoteInstanceInput | null>(null);
  /** Name is the primary key — lock it while editing an existing row. */
  const [editingExisting, setEditingExisting] = useState(false);
  const [hadSecret, setHadSecret] = useState(false);
  const [report, setReport] = useState<TestReport | null>(null);
  const [testing, setTesting] = useState(false);
  const [syncing, setSyncing] = useState<string | null>(null);

  const set = (patch: Partial<RemoteInstanceInput>) =>
    setDraft((d) => (d ? { ...d, ...patch } : d));

  const closeForm = () => {
    setDraft(null);
    setReport(null);
    setEditingExisting(false);
    setHadSecret(false);
  };

  const startEdit = (inst: RemoteInstance) => {
    const { hasSecret, ...rest } = inst;
    setDraft({ ...rest, password: "" });
    setEditingExisting(true);
    setHadSecret(hasSecret);
    setReport(null);
  };

  const save = async () => {
    if (!draft) return;
    try {
      await api.upsertRemote(draft);
      closeForm();
      qc.invalidateQueries({ queryKey: ["remote"] });
      notify(t("remote.saved", { name: draft.name }));
    } catch (e) {
      notify(String(e), "error");
    }
  };

  const test = async () => {
    if (!draft) return;
    setTesting(true);
    try {
      setReport(await api.testRemote(draft));
    } catch (e) {
      notify(String(e), "error");
    } finally {
      setTesting(false);
    }
  };

  const sync = async (name: string) => {
    setSyncing(name);
    try {
      const n = await api.syncRemote(name);
      notify(t("remote.synced", { name, n }));
      qc.invalidateQueries();
    } catch (e) {
      notify(String(e), "error");
    } finally {
      setSyncing(null);
    }
  };

  return (
    <div className="flex flex-col gap-2">
      {!instances?.length && !draft && (
        <div className="text-[0.6875rem] text-[rgb(var(--text-dim))]">{t("remote.empty")}</div>
      )}

      {instances?.map((inst) => (
        <div key={inst.name} className="glass-quiet flex items-center gap-2.5 px-3 py-2">
          <span className={`status-dot ${inst.enabled ? "status-live" : "status-disabled"}`} />
          <span className="text-[0.8125rem] font-medium">{inst.name}</span>
          <span className="chip">{inst.agent}</span>
          <span className="truncate text-[0.6875rem] text-[rgb(var(--text-dim))]">
            {inst.username}@{inst.host}:{inst.port} · {inst.authMode} · every {inst.pollSecs}s
          </span>

          <div className="ml-auto flex shrink-0 items-center gap-2">
            <GlassButton size="sm" tone="ghost" disabled={syncing === inst.name} onClick={() => sync(inst.name)}>
              <RefreshCw size={12} className={syncing === inst.name ? "animate-spin" : undefined} />
              {t("common.sync")}
            </GlassButton>
            <GlassButton
              size="sm"
              tone="ghost"
              title={t("remote.edit")}
              disabled={draft !== null}
              onClick={() => startEdit(inst)}
            >
              <Pencil size={12} />
            </GlassButton>
            <GlassSwitch
              checked={inst.enabled}
              label={`Enable ${inst.name}`}
              onChange={async (enabled) => {
                // hasSecret is server-side state; omitting `password` keeps the stored one.
                const { hasSecret: _hasSecret, ...rest } = inst;
                await api.upsertRemote({ ...rest, enabled });
                qc.invalidateQueries({ queryKey: ["remote"] });
              }}
            />
            <GlassButton
              size="sm"
              tone="ghost"
              title={t("common.remove")}
              onClick={async () => {
                await api.deleteRemote(inst.name);
                qc.invalidateQueries({ queryKey: ["remote"] });
              }}
            >
              <Trash2 size={12} />
            </GlassButton>
          </div>
        </div>
      ))}

      {draft ? (
        <div className="glass-quiet flex flex-col gap-2 p-3">
          <div className="flex gap-2">
            <Field
              label={t("remote.name")}
              value={draft.name}
              onChange={(name) => set({ name })}
              placeholder="build-box"
              disabled={editingExisting}
            />
            <label className="flex w-[130px] flex-col gap-1">
              <span className="text-[0.625rem] font-semibold uppercase tracking-[0.06em] text-[rgb(var(--text-faint))]">
                {t("remote.agent")}
              </span>
              <select
                value={draft.agent}
                onChange={(e) => set({ agent: e.target.value as "hermes" | "openclaw" })}
                className="no-drag rounded-lg border border-white/8 bg-black/25 px-2 py-1 text-[0.75rem] outline-none"
              >
                <option value="hermes">Hermes Agent</option>
                <option value="openclaw">OpenClaw</option>
              </select>
            </label>
          </div>
          {editingExisting && (
            <div className="text-[0.6875rem] text-[rgb(var(--text-dim))]">{t("remote.nameLocked")}</div>
          )}

          <div className="flex gap-2">
            <Field label={t("remote.host")} value={draft.host} onChange={(host) => set({ host })} placeholder="10.0.0.5" />
            <Field
              label={t("remote.port")}
              width="w-[80px]"
              value={String(draft.port)}
              onChange={(v) => set({ port: Number(v) || 22 })}
            />
            <Field label={t("remote.user")} value={draft.username} onChange={(username) => set({ username })} placeholder="ubuntu" />
          </div>

          <div className="flex gap-2">
            <label className="flex w-[130px] flex-col gap-1">
              <span className="text-[0.625rem] font-semibold uppercase tracking-[0.06em] text-[rgb(var(--text-faint))]">
                {t("remote.auth")}
              </span>
              <select
                value={draft.authMode}
                onChange={(e) => set({ authMode: e.target.value as RemoteInstanceInput["authMode"] })}
                className="no-drag rounded-lg border border-white/8 bg-black/25 px-2 py-1 text-[0.75rem] outline-none"
              >
                <option value="key">{t("remote.key")}</option>
                <option value="agent">{t("remote.agentAuth")}</option>
                <option value="password">{t("remote.password")}</option>
              </select>
            </label>

            {draft.authMode === "key" && (
              <Field
                label={t("remote.keyPath")}
                value={draft.keyPath ?? ""}
                onChange={(keyPath) => set({ keyPath })}
                placeholder="%USERPROFILE%\.ssh\id_ed25519"
              />
            )}
            {draft.authMode === "password" && (
              <Field
                label={t("remote.password")}
                type="password"
                value={draft.password ?? ""}
                onChange={(password) => set({ password })}
                placeholder={hadSecret ? t("remote.passwordKeep") : t("remote.passwordHint")}
              />
            )}
          </div>

          <div className="flex gap-2">
            <Field
              label={t("remote.remotePath")}
              value={draft.remotePath ?? ""}
              onChange={(remotePath) => set({ remotePath })}
              placeholder={draft.agent === "hermes" ? "~/.hermes/state.db" : "~/.openclaw"}
            />
            <Field
              label={t("remote.poll")}
              width="w-[90px]"
              value={String(draft.pollSecs)}
              onChange={(v) => set({ pollSecs: Number(v) || 300 })}
            />
          </div>

          <div className="flex items-center gap-2">
            <GlassSwitch
              checked={draft.importArchives}
              onChange={(importArchives) => set({ importArchives })}
              label={t("remote.archives")}
            />
            <span className="text-[0.6875rem] text-[rgb(var(--text-dim))]">
              {t("remote.archivesHint")}
            </span>
          </div>

          {report && (
            <div className="flex flex-col gap-1 rounded-lg bg-black/20 p-2">
              {report.steps.map((s) => (
                <div key={s.label} className="flex items-start gap-1.5 text-[0.6875rem]">
                  {s.ok ? (
                    <Check size={12} className="mt-px shrink-0 text-[rgb(var(--success))]" />
                  ) : (
                    <X size={12} className="mt-px shrink-0 text-[rgb(var(--danger))]" />
                  )}
                  <span className="font-medium">{s.label}</span>
                  <span className="min-w-0 flex-1 truncate text-[rgb(var(--text-dim))]" title={s.detail}>
                    {s.detail}
                  </span>
                </div>
              ))}
            </div>
          )}

          <div className="flex items-center gap-2">
            <GlassButton size="sm" onClick={test} disabled={testing || !draft.host || !draft.username}>
              {testing ? t("common.loading") : t("remote.test")}
            </GlassButton>
            <GlassButton size="sm" tone="accent" onClick={save} disabled={!draft.name || !draft.host}>
              {t("common.save")}
            </GlassButton>
            <GlassButton size="sm" tone="ghost" onClick={closeForm}>
              {t("common.cancel")}
            </GlassButton>
          </div>
        </div>
      ) : (
        <GlassButton
          size="sm"
          className="self-start"
          onClick={() => {
            setDraft({ ...BLANK });
            setEditingExisting(false);
            setHadSecret(false);
          }}
        >
          <Plus size={13} />
          {t("remote.add")}
        </GlassButton>
      )}
    </div>
  );
}
