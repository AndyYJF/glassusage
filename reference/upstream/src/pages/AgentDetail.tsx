import { useState } from "react";
import { AlertTriangle, FolderOpen, RefreshCw } from "lucide-react";

import { GlassButton } from "../components/glass/GlassButton";
import { GlassCard } from "../components/glass/GlassCard";
import { RangePicker } from "../components/RangePicker";
import { CalendarHeatmap } from "../components/charts/CalendarHeatmap";
import { ShareList } from "../components/charts/ShareList";
import { UsageChart } from "../components/charts/UsageChart";
import { api } from "../lib/api";
import { useAgentStats, useRange, useSourceHealth, useTimeseries } from "../lib/hooks";
import { useT, statusKey } from "../lib/i18n";
import { bucketFor, useUi } from "../lib/store";
import { fullNumber, percent, relative, tokens, unpricedNote, usd } from "../lib/format";
import { SOURCE_META, STATUS_CLASS, sourceColor } from "../lib/sources";
import type { SourceId } from "../lib/types";

function Metric({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="glass px-3 py-2.5" style={{ borderRadius: "var(--radius-button)" }}>
      <div className="text-[0.625rem] font-semibold uppercase tracking-[0.06em] text-[rgb(var(--text-faint))]">
        {label}
      </div>
      <div className="tnum mt-1 text-[1.05rem] font-semibold leading-none">{value}</div>
      {sub && <div className="mt-1 text-[0.6875rem] text-[rgb(var(--text-dim))]">{sub}</div>}
    </div>
  );
}

export function AgentDetail({ source }: { source: string }) {
  const { t } = useT();
  const meta = SOURCE_META[source as SourceId];
  const notify = useUi((s) => s.notify);
  const [busy, setBusy] = useState(false);

  const { key, from, to } = useRange();
  const { data: stats } = useAgentStats(source);
  const { data: health } = useSourceHealth();
  const { data: series } = useTimeseries("model_norm", undefined, source);

  const rows = (health ?? []).filter((h) => h.source === source);
  const totals = stats?.totals;

  const agentSeries = series ?? [];

  const localizeUnpriced = (kind: "none" | "partial", count: number) =>
    kind === "none"
      ? t("fmt.noPrice")
      : t("fmt.excludesUnpriced", { n: fullNumber(count) });

  const rescan = async (purge: boolean) => {
    setBusy(true);
    try {
      await api.rescanSource(source, undefined, purge);
      const name = meta?.label ?? source;
      notify(
        purge ? t("agent.reimporting", { name }) : t("agent.rescanning", { name }),
      );
    } catch (e) {
      notify(String(e), "error");
    } finally {
      window.setTimeout(() => setBusy(false), 1200);
    }
  };

  const cacheRate = totals
    ? totals.cacheReadTokens /
      Math.max(1, totals.inputTokens + totals.cacheReadTokens + totals.cacheWriteTokens)
    : 0;

  return (
    <div className="scroll-area flex h-full flex-col gap-3 overflow-y-auto pr-1">
      <div className="flex items-center gap-3">
        <span
          className="h-2.5 w-2.5 rounded-full"
          style={{ background: sourceColor(source) }}
        />
        <h1 className="text-[1.05rem] font-semibold tracking-tight">{meta?.label ?? source}</h1>
        <span className="chip">
          {meta?.realtime ? t("common.fileWatcher") : t("common.polling")}
        </span>

        <div className="ml-auto flex items-center gap-2">
          <RangePicker />
          <GlassButton size="sm" onClick={() => rescan(false)} disabled={busy}>
            <RefreshCw size={13} className={busy ? "animate-spin" : undefined} />
            {t("common.rescan")}
          </GlassButton>
        </div>
      </div>

      <div className="grid grid-cols-5 gap-2">
        <Metric
          label={t("agent.totalTokens")}
          value={tokens(totals?.totalTokens ?? 0)}
          sub={t("fmt.eventsSub", { n: fullNumber(totals?.events ?? 0) })}
        />
        <Metric
          label={t("agent.cost")}
          value={usd(totals?.costUsd ?? 0)}
          sub={unpricedNote(totals, localizeUnpriced)}
        />
        <Metric label={t("agent.input")} value={tokens(totals?.inputTokens ?? 0)} />
        <Metric
          label={t("agent.output")}
          value={tokens(totals?.outputTokens ?? 0)}
          sub={t("agent.reasoning", { n: tokens(totals?.reasoningTokens ?? 0) })}
        />
        <Metric
          label={t("agent.cacheHit")}
          value={percent(cacheRate, 1)}
          sub={tokens(totals?.cacheReadTokens ?? 0)}
        />
      </div>

      <GlassCard variant="lens" className="p-4">
        <h2 className="mb-1 text-[0.875rem] font-semibold">{t("agent.byModel")}</h2>
        <UsageChart data={agentSeries} bucket={bucketFor(key, from, to)} colorBy="palette" height={200} />
      </GlassCard>

      <div className="grid grid-cols-3 gap-3">
        <GlassCard variant="lens" className="p-4">
          <h2 className="mb-2 text-[0.875rem] font-semibold">{t("agent.models")}</h2>
          <ShareList items={stats?.perModel ?? []} limit={8} />
        </GlassCard>
        <GlassCard variant="lens" className="p-4">
          <h2 className="mb-2 text-[0.875rem] font-semibold">{t("agent.projects")}</h2>
          <ShareList
            items={stats?.perProject ?? []}
            limit={8}
            emptyText={t("agent.noProjects")}
          />
        </GlassCard>
        <GlassCard variant="lens" className="p-4">
          <h2 className="mb-2 text-[0.875rem] font-semibold">{t("agent.byInstance")}</h2>
          <ShareList
            items={(stats?.perInstance ?? []).map((row) =>
              row.key === "local"
                ? { ...row, label: t("usage.instanceLocal") }
                : row,
            )}
            limit={8}
            emptyText={t("agent.noInstances")}
          />
        </GlassCard>
      </div>

      <GlassCard variant="plain" className="p-4">
        <h2 className="mb-3 text-[0.875rem] font-semibold">{t("agent.daily")}</h2>
        <CalendarHeatmap data={stats?.calendar ?? []} color={sourceColor(source)} />
      </GlassCard>

      <GlassCard variant="plain" className="p-3">
        <div className="mb-2 flex items-center gap-2 px-1">
          <span className="text-[0.6875rem] font-semibold uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
            {t("agent.instances")}
          </span>
          <GlassButton
            size="sm"
            tone="ghost"
            className="ml-auto"
            onClick={() => api.openDataDir()}
            title={t("agent.openData")}
          >
            <FolderOpen size={13} />
            {t("agent.dataFolder")}
          </GlassButton>
          <GlassButton size="sm" tone="danger" onClick={() => rescan(true)} disabled={busy}>
            {t("agent.reimport")}
          </GlassButton>
        </div>

        {!rows.length && (
          <div className="px-1 py-3 text-[0.8125rem] text-[rgb(var(--text-faint))]">
            {t("agent.noDir")}
          </div>
        )}

        <div className="flex flex-col gap-1.5">
          {rows.map((h) => (
            <div key={`${h.source}:${h.instance}`} className="glass-quiet px-3 py-2">
              <div className="flex items-center gap-2">
                <span className={`status-dot ${STATUS_CLASS[h.status]}`} />
                <span className="text-[0.8125rem] font-medium">{h.instance}</span>
                <span className="text-[0.75rem] text-[rgb(var(--text-dim))]">
                  {t(statusKey(h.status))}
                </span>
                <span className="tnum ml-auto text-[0.75rem] text-[rgb(var(--text-dim))]">
                  {t("agent.healthLine", {
                    events: fullNumber(h.eventCount),
                    files: h.fileCount,
                    scan: relative(h.lastScanMs),
                  })}
                </span>
              </div>

              {h.detectedPaths.length > 0 && (
                <div
                  className="mt-1 truncate text-[0.6875rem] text-[rgb(var(--text-faint))]"
                  title={h.detectedPaths.join("\n")}
                >
                  {h.detectedPaths[0]}
                  {h.detectedPaths.length > 1 &&
                    ` ${t("agent.morePaths", { n: h.detectedPaths.length - 1 })}`}
                </div>
              )}

              {(h.lastError || h.skippedRows > 0) && (
                <div className="mt-1 flex items-start gap-1.5 text-[0.6875rem] text-[rgb(var(--warning))]">
                  <AlertTriangle size={11} className="mt-px shrink-0" />
                  <span>
                    {h.lastError ?? t("agent.skippedRows", { n: h.skippedRows })}
                  </span>
                </div>
              )}
            </div>
          ))}
        </div>
      </GlassCard>
    </div>
  );
}
