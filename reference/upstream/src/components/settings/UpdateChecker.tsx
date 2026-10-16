/**
 * Check GitHub Releases for a signed NSIS update and install it in-place.
 */
import { useEffect, useState } from "react";
import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { getVersion } from "@tauri-apps/api/app";

import { GlassButton } from "../glass/GlassButton";
import { useT } from "../../lib/i18n";
import { useUi } from "../../lib/store";

type Status =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "upToDate"; version: string }
  | { kind: "available"; update: Update }
  | { kind: "downloading"; progress: number }
  | { kind: "error"; message: string };

export function UpdateChecker() {
  const { t } = useT();
  const notify = useUi((s) => s.notify);
  const [version, setVersion] = useState("");
  const [status, setStatus] = useState<Status>({ kind: "idle" });

  useEffect(() => {
    void getVersion()
      .then(setVersion)
      .catch(() => setVersion(""));
  }, []);

  const checkNow = async () => {
    setStatus({ kind: "checking" });
    try {
      const update = await check();
      if (!update) {
        setStatus({ kind: "upToDate", version: version || "?" });
        return;
      }
      setStatus({ kind: "available", update });
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      setStatus({ kind: "error", message });
      notify(t("settings.updateError", { error: message }), "error");
    }
  };

  const install = async (update: Update) => {
    setStatus({ kind: "downloading", progress: 0 });
    try {
      let downloaded = 0;
      let total = 0;
      await update.downloadAndInstall((event) => {
        if (event.event === "Started") {
          total = event.data.contentLength ?? 0;
        } else if (event.event === "Progress") {
          downloaded += event.data.chunkLength;
          if (total > 0) {
            setStatus({
              kind: "downloading",
              progress: Math.min(1, downloaded / total),
            });
          }
        }
      });
      notify(t("settings.updateAvailable", { version: update.version }));
      await relaunch();
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      setStatus({ kind: "error", message });
      notify(t("settings.updateError", { error: message }), "error");
    }
  };

  return (
    <div className="flex flex-col gap-2">
      <div className="text-[0.6875rem] text-[rgb(var(--text-dim))]">{t("settings.updatesHint")}</div>
      {version && (
        <div className="text-[0.75rem] text-[rgb(var(--text-faint))]">
          {t("settings.currentVersion", { version })}
        </div>
      )}

      {status.kind === "available" && (
        <div className="glass-quiet rounded-lg border border-white/8 bg-black/15 p-3">
          <div className="text-[0.8125rem] font-semibold">
            {t("settings.updateAvailable", { version: status.update.version })}
          </div>
          {status.update.body && (
            <div className="mt-1 whitespace-pre-wrap text-[0.75rem] text-[rgb(var(--text-dim))]">
              {status.update.body}
            </div>
          )}
          <GlassButton
            className="mt-2"
            size="sm"
            tone="accent"
            onClick={() => void install(status.update)}
          >
            {t("settings.installUpdate")}
          </GlassButton>
        </div>
      )}

      {status.kind === "downloading" && (
        <div className="flex flex-col gap-1.5">
          <div className="text-[0.75rem] text-[rgb(var(--text-dim))]">
            {t("settings.downloadingUpdate")}
          </div>
          <div className="h-1.5 w-full overflow-hidden rounded-full bg-white/10">
            <div
              className="h-full rounded-full bg-[rgb(var(--accent))] transition-[width] duration-200"
              style={{ width: `${Math.round(status.progress * 100)}%` }}
            />
          </div>
        </div>
      )}

      {status.kind === "upToDate" && (
        <div className="text-[0.75rem] text-[rgb(var(--success))]">
          {t("settings.upToDate", { version: status.version })}
        </div>
      )}

      {status.kind === "error" && (
        <div className="text-[0.75rem] text-[rgb(var(--danger))]">{status.message}</div>
      )}

      <div>
        <GlassButton
          size="sm"
          disabled={status.kind === "checking" || status.kind === "downloading"}
          onClick={() => void checkNow()}
        >
          {status.kind === "checking" ? t("settings.checkingUpdate") : t("settings.checkUpdate")}
        </GlassButton>
      </div>
    </div>
  );
}
