/**
 * First-launch walkthrough: local agents detected, Cursor cookie, remote tip.
 */
import { useMemo, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Check, ChevronRight, Cloud, Server, Sparkles } from "lucide-react";

import { GlassButton } from "./glass/GlassButton";
import { api } from "../lib/api";
import { useCursorStatus, useSourceHealth } from "../lib/hooks";
import { useT, statusKey } from "../lib/i18n";
import { SOURCE_LIST, STATUS_CLASS } from "../lib/sources";
import { useUi } from "../lib/store";

const STEPS = 3;

export function Onboarding({ onDone }: { onDone: () => void }) {
  const { t } = useT();
  const qc = useQueryClient();
  const notify = useUi((s) => s.notify);
  const { data: health } = useSourceHealth();
  const { data: cursor } = useCursorStatus();
  const [step, setStep] = useState(0);
  const [cookie, setCookie] = useState("");
  const [busy, setBusy] = useState(false);

  const detected = useMemo(() => {
    return SOURCE_LIST.map((meta) => {
      const rows = (health ?? []).filter((h) => h.source === meta.id);
      const status =
        rows.find((r) => r.status === "live" || r.status === "polling")?.status ??
        rows[0]?.status ??
        ("missing" as const);
      return { meta, status, paths: rows.flatMap((r) => r.detectedPaths).slice(0, 2) };
    });
  }, [health]);

  const finish = async () => {
    setBusy(true);
    try {
      await api.setSettings({ firstRunDone: true });
      qc.invalidateQueries({ queryKey: ["settings"] });
      onDone();
    } catch (e) {
      notify(String(e), "error");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="fixed inset-0 z-[100] flex items-center justify-center bg-black/55 p-6 backdrop-blur-md">
      <div
        className="range-popover flex w-full max-w-lg flex-col gap-4 p-5"
        role="dialog"
        aria-label={t("onboard.title")}
      >
        <div className="flex items-center gap-2">
          <Sparkles size={16} className="text-[rgb(var(--accent))]" />
          <h2 className="text-[1.05rem] font-semibold tracking-tight">{t("onboard.title")}</h2>
          <span className="ml-auto text-[0.6875rem] text-[rgb(var(--text-faint))]">
            {step + 1} / {STEPS}
          </span>
        </div>

        {step === 0 && (
          <div className="flex flex-col gap-3">
            <p className="text-[0.8125rem] leading-relaxed text-[rgb(var(--text-dim))]">
              {t("onboard.agentsHint")}
            </p>
            <div className="flex max-h-56 flex-col gap-1.5 overflow-y-auto">
              {detected.map(({ meta, status, paths }) => (
                <div
                  key={meta.id}
                  className="range-popover-field flex items-center gap-2.5 px-2.5 py-2"
                >
                  <span className={`status-dot ${STATUS_CLASS[status]}`} />
                  <div className="min-w-0 flex-1">
                    <div className="text-[0.8125rem] font-medium">{meta.label}</div>
                    <div className="truncate text-[0.6875rem] text-[rgb(var(--text-faint))]">
                      {paths[0] ?? meta.origin}
                    </div>
                  </div>
                  <span className="chip">{t(statusKey(status))}</span>
                </div>
              ))}
            </div>
            <GlassButton
              size="sm"
              onClick={async () => {
                try {
                  await api.rescanAll();
                  notify(t("dash.rescanning"));
                  qc.invalidateQueries({ queryKey: ["health"] });
                } catch (e) {
                  notify(String(e), "error");
                }
              }}
            >
              {t("common.rescan")}
            </GlassButton>
          </div>
        )}

        {step === 1 && (
          <div className="flex flex-col gap-3">
            <div className="flex items-center gap-2 text-[0.875rem] font-semibold">
              <Cloud size={15} />
              {t("onboard.cursorTitle")}
            </div>
            <p className="text-[0.8125rem] leading-relaxed text-[rgb(var(--text-dim))]">
              {t("onboard.cursorHint")}
            </p>
            <ol className="list-decimal space-y-1 pl-4 text-[0.75rem] text-[rgb(var(--text-dim))]">
              <li>{t("settings.cursorStep1")}</li>
              <li>{t("settings.cursorStep2")}</li>
              <li>{t("settings.cursorStep3")}</li>
            </ol>
            <div className="flex items-center gap-2 text-[0.75rem]">
              <span
                className={`status-dot ${cursor?.hasAccessToken || cursor?.hasCookie ? "status-live" : "status-missing"}`}
              />
              {cursor?.hasAccessToken
                ? t("settings.cursorChannelA")
                : cursor?.hasCookie
                  ? t("settings.cursorChannelB")
                  : t("settings.cursorNone")}
            </div>
            <div className="flex gap-2">
              <input
                value={cookie}
                onChange={(e) => setCookie(e.target.value)}
                type="password"
                placeholder={t("settings.cursorPlaceholder")}
                spellCheck={false}
                className="no-drag min-w-0 flex-1 rounded-lg border border-white/8 bg-black/15 px-2.5 py-1.5 text-[0.75rem] outline-none"
              />
              <GlassButton
                size="sm"
                tone="accent"
                disabled={!cookie.trim() || busy}
                onClick={async () => {
                  setBusy(true);
                  try {
                    await api.setCursorCookie(cookie.trim());
                    setCookie("");
                    await api.syncCursorNow();
                    notify(t("onboard.cursorSaved"));
                    qc.invalidateQueries({ queryKey: ["cursor-status"] });
                  } catch (e) {
                    notify(String(e), "error");
                  } finally {
                    setBusy(false);
                  }
                }}
              >
                {t("common.save")}
              </GlassButton>
            </div>
          </div>
        )}

        {step === 2 && (
          <div className="flex flex-col gap-3">
            <div className="flex items-center gap-2 text-[0.875rem] font-semibold">
              <Server size={15} />
              {t("onboard.remoteTitle")}
            </div>
            <p className="text-[0.8125rem] leading-relaxed text-[rgb(var(--text-dim))]">
              {t("onboard.remoteHint")}
            </p>
            <ul className="space-y-1.5 text-[0.75rem] text-[rgb(var(--text-dim))]">
              <li>· {t("onboard.remoteBullet1")}</li>
              <li>· {t("onboard.remoteBullet2")}</li>
              <li>· {t("onboard.remoteBullet3")}</li>
            </ul>
          </div>
        )}

        <div className="mt-1 flex items-center justify-between gap-2">
          <GlassButton size="sm" tone="ghost" disabled={busy} onClick={() => void finish()}>
            {t("onboard.skip")}
          </GlassButton>
          <div className="flex gap-2">
            {step > 0 && (
              <GlassButton size="sm" tone="ghost" onClick={() => setStep((s) => s - 1)}>
                {t("onboard.back")}
              </GlassButton>
            )}
            {step < STEPS - 1 ? (
              <GlassButton size="sm" tone="accent" onClick={() => setStep((s) => s + 1)}>
                {t("onboard.next")}
                <ChevronRight size={13} />
              </GlassButton>
            ) : (
              <GlassButton size="sm" tone="accent" disabled={busy} onClick={() => void finish()}>
                <Check size={13} />
                {t("onboard.done")}
              </GlassButton>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
