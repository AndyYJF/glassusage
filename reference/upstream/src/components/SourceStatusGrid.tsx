/**
 * Health strip for every source.
 *
 * This is the app's honesty panel: a source that is not installed, disabled, or failing
 * to parse says so here, so a low total is never mistaken for low usage.
 */
import { AlertTriangle } from "lucide-react";

import { GlassCard } from "./glass/GlassCard";
import { SOURCE_LIST, STATUS_CLASS, rollupSourceStatus } from "../lib/sources";
import { useSourceHealth } from "../lib/hooks";
import { useT, statusKey } from "../lib/i18n";
import { fullNumber, relative } from "../lib/format";
import type { SourceHealth } from "../lib/types";

export function SourceStatusGrid({ onOpenAgent }: { onOpenAgent: (source: string) => void }) {
  const { t } = useT();
  const { data: health } = useSourceHealth();

  // Remote instances arrive as extra rows for the same source; roll them into one tile
  // and let the Agents page break them apart.
  const rollup = new Map<string, SourceHealth[]>();
  for (const h of health ?? []) {
    const list = rollup.get(h.source) ?? [];
    list.push(h);
    rollup.set(h.source, list);
  }

  return (
    <GlassCard variant="plain" className="shrink-0 p-3">
      <div className="mb-2 px-1 text-[0.6875rem] font-semibold uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
        {t("sources.title")}
      </div>
      <div className="grid grid-cols-4 gap-2">
        {SOURCE_LIST.map((meta) => {
          const rows = rollup.get(meta.id) ?? [];
          const status = rollupSourceStatus(rows);
          const primary =
            rows.find((r) => r.status === status) ??
            rows.find((r) => r.instance === "local") ??
            rows[0];
          const events = rows.reduce((n, r) => n + r.eventCount, 0);
          const skipped = rows.reduce((n, r) => n + r.skippedRows, 0);
          const lastEvent = Math.max(0, ...rows.map((r) => r.lastEventMs ?? 0));

          return (
            <button
              key={meta.id}
              type="button"
              onClick={() => onOpenAgent(meta.id)}
              className="glass-quiet flex flex-col gap-1.5 px-3 py-2.5 text-left transition-colors hover:bg-white/[0.09]"
            >
              <div className="flex items-center gap-2">
                <span
                  className="h-2 w-2 shrink-0 rounded-full"
                  style={{ background: `rgb(var(${meta.colorVar}))` }}
                />
                <span className="truncate text-[0.8125rem] font-medium">{meta.label}</span>
                <span className={`status-dot ml-auto ${STATUS_CLASS[status]}`} />
              </div>

              <div className="flex items-baseline gap-1.5 text-[0.6875rem] text-[rgb(var(--text-faint))]">
                <span>{t(statusKey(status))}</span>
                {rows.length > 1 && (
                  <span>· {t("sources.instances", { n: rows.length })}</span>
                )}
              </div>

              <div className="flex items-baseline gap-1.5 text-[0.6875rem] text-[rgb(var(--text-dim))]">
                <span className="tnum">{t("sources.events", { n: fullNumber(events) })}</span>
                {lastEvent > 0 && <span className="ml-auto">{relative(lastEvent)}</span>}
              </div>

              {(status === "error" || skipped > 0) && (
                <div
                  className="flex items-center gap-1 text-[0.6875rem] text-[rgb(var(--warning))]"
                  title={primary?.lastError ?? t("sources.skipped", { n: skipped })}
                >
                  <AlertTriangle size={11} />
                  <span className="truncate">
                    {status === "error"
                      ? (primary?.lastError ?? t("sources.scanFailed"))
                      : t("sources.skipped", { n: skipped })}
                  </span>
                </div>
              )}
            </button>
          );
        })}
      </div>
    </GlassCard>
  );
}
