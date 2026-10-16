/**
 * Side-by-side comparison: calendar week vs previous week, or two models in the
 * current range. Reuses overview + group_stats — no new backend endpoints.
 */
import { useMemo, useState } from "react";
import { ArrowLeftRight, Coins, GitCompare, Zap } from "lucide-react";

import { GlassCard } from "../components/glass/GlassCard";
import { GlassSegmented } from "../components/glass/GlassSegmented";
import { RangePicker } from "../components/RangePicker";
import { StatTile } from "../components/StatTile";
import { useFilterOptions, useGroupStats, useOverview, useRange } from "../lib/hooks";
import { useT } from "../lib/i18n";
import { delta, fullNumber, tokens, usd } from "../lib/format";

type Mode = "week" | "models";

export function ComparePage() {
  const { t } = useT();
  const [mode, setMode] = useState<Mode>("week");
  const { from, to } = useRange();
  const { data: overview } = useOverview();
  const { data: options } = useFilterOptions();
  const models = options?.model_norm ?? [];

  const [modelA, setModelA] = useState("");
  const [modelB, setModelB] = useState("");

  // Seed picks once models load.
  const effectiveA = modelA || models[0] || "";
  const effectiveB = modelB || models[1] || models[0] || "";

  const { data: groupA } = useGroupStats(
    "model_norm",
    { from, to, models: effectiveA ? [effectiveA] : [] },
    { enabled: mode === "models" && Boolean(effectiveA) },
  );
  const { data: groupB } = useGroupStats(
    "model_norm",
    { from, to, models: effectiveB ? [effectiveB] : [] },
    { enabled: mode === "models" && Boolean(effectiveB) },
  );

  const modes = useMemo(
    () => [
      { value: "week" as const, label: t("compare.modeWeek") },
      { value: "models" as const, label: t("compare.modeModels") },
    ],
    [t],
  );

  const thisWeek = overview?.thisWeek;
  const lastWeek = overview?.lastWeek;
  const weekTokenDelta = delta(thisWeek?.totalTokens ?? 0, lastWeek?.totalTokens ?? 0);
  const weekCostDelta = delta(thisWeek?.costUsd ?? 0, lastWeek?.costUsd ?? 0);

  const a = groupA?.[0];
  const b = groupB?.[0];
  const modelTokenDelta = delta(a?.totalTokens ?? 0, b?.totalTokens ?? 0);
  const modelCostDelta = delta(a?.costUsd ?? 0, b?.costUsd ?? 0);

  return (
    <div className="scroll-area flex h-full flex-col gap-3 overflow-y-auto pr-1">
      <div className="flex shrink-0 items-center gap-3">
        <h1 className="text-[1.05rem] font-semibold tracking-tight">{t("compare.title")}</h1>
        <div className="ml-auto flex items-center gap-2">
          {mode === "models" && <RangePicker />}
          <GlassSegmented value={mode} options={modes} onChange={setMode} />
        </div>
      </div>

      <p className="shrink-0 text-[0.8125rem] text-[rgb(var(--text-dim))]">{t("compare.subtitle")}</p>

      {mode === "week" ? (
        <>
          <div className="grid shrink-0 grid-cols-2 gap-3">
            <GlassCard variant="plain" className="p-4">
              <div className="text-[0.6875rem] font-semibold uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
                {t("compare.thisWeek")}
              </div>
              <div className="mt-3 grid grid-cols-2 gap-3">
                <div>
                  <div className="tnum text-[1.35rem] font-semibold leading-none">
                    {tokens(thisWeek?.totalTokens ?? 0)}
                  </div>
                  <div className="mt-1 text-[0.625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
                    {t("common.tokens")}
                  </div>
                </div>
                <div>
                  <div className="tnum text-[1.35rem] font-semibold leading-none">
                    {usd(thisWeek?.costUsd ?? 0)}
                  </div>
                  <div className="mt-1 text-[0.625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
                    {t("common.cost")}
                  </div>
                </div>
              </div>
              <div className="mt-3 text-[0.75rem] text-[rgb(var(--text-dim))]">
                {t("fmt.eventsSub", { n: fullNumber(thisWeek?.events ?? 0) })}
              </div>
            </GlassCard>

            <GlassCard variant="plain" className="p-4">
              <div className="text-[0.6875rem] font-semibold uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
                {t("compare.lastWeek")}
              </div>
              <div className="mt-3 grid grid-cols-2 gap-3">
                <div>
                  <div className="tnum text-[1.35rem] font-semibold leading-none">
                    {tokens(lastWeek?.totalTokens ?? 0)}
                  </div>
                  <div className="mt-1 text-[0.625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
                    {t("common.tokens")}
                  </div>
                </div>
                <div>
                  <div className="tnum text-[1.35rem] font-semibold leading-none">
                    {usd(lastWeek?.costUsd ?? 0)}
                  </div>
                  <div className="mt-1 text-[0.625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
                    {t("common.cost")}
                  </div>
                </div>
              </div>
              <div className="mt-3 text-[0.75rem] text-[rgb(var(--text-dim))]">
                {t("fmt.eventsSub", { n: fullNumber(lastWeek?.events ?? 0) })}
              </div>
            </GlassCard>
          </div>

          <div className="grid shrink-0 grid-cols-2 gap-3">
            <StatTile
              label={t("compare.tokenChange")}
              icon={<Zap size={12} />}
              value={tokens(Math.abs((thisWeek?.totalTokens ?? 0) - (lastWeek?.totalTokens ?? 0)))}
              delta={weekTokenDelta}
              caption={t("common.vsLastWeek")}
              accent="rgb(var(--accent) / 0.55)"
            />
            <StatTile
              label={t("compare.costChange")}
              icon={<Coins size={12} />}
              value={usd(Math.abs((thisWeek?.costUsd ?? 0) - (lastWeek?.costUsd ?? 0)))}
              delta={weekCostDelta}
              caption={t("common.vsLastWeek")}
              accent="rgb(var(--accent-2) / 0.5)"
            />
          </div>
        </>
      ) : (
        <>
          <GlassCard variant="plain" className="flex flex-wrap items-end gap-3 p-3">
            <label className="flex min-w-[12rem] flex-1 flex-col gap-1">
              <span className="text-[0.625rem] uppercase tracking-[0.05em] text-[rgb(var(--text-faint))]">
                {t("compare.modelA")}
              </span>
              <select
                value={effectiveA}
                onChange={(e) => setModelA(e.target.value)}
                className="glass-quiet rounded-md border border-white/8 bg-black/15 px-2 py-1.5 text-[0.8125rem]"
              >
                {models.length === 0 && <option value="">{t("compare.noModels")}</option>}
                {models.map((m) => (
                  <option key={m} value={m}>
                    {m}
                  </option>
                ))}
              </select>
            </label>
            <ArrowLeftRight size={16} className="mb-2 text-[rgb(var(--text-faint))]" />
            <label className="flex min-w-[12rem] flex-1 flex-col gap-1">
              <span className="text-[0.625rem] uppercase tracking-[0.05em] text-[rgb(var(--text-faint))]">
                {t("compare.modelB")}
              </span>
              <select
                value={effectiveB}
                onChange={(e) => setModelB(e.target.value)}
                className="glass-quiet rounded-md border border-white/8 bg-black/15 px-2 py-1.5 text-[0.8125rem]"
              >
                {models.length === 0 && <option value="">{t("compare.noModels")}</option>}
                {models.map((m) => (
                  <option key={m} value={m}>
                    {m}
                  </option>
                ))}
              </select>
            </label>
          </GlassCard>

          <div className="grid shrink-0 grid-cols-2 gap-3">
            <GlassCard variant="plain" className="p-4">
              <div className="truncate text-[0.6875rem] font-semibold text-[rgb(var(--text-faint))]" title={effectiveA}>
                {effectiveA || "—"}
              </div>
              <div className="mt-3 grid grid-cols-2 gap-3">
                <div>
                  <div className="tnum text-[1.35rem] font-semibold leading-none">
                    {tokens(a?.totalTokens ?? 0)}
                  </div>
                  <div className="mt-1 text-[0.625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
                    {t("common.tokens")}
                  </div>
                </div>
                <div>
                  <div className="tnum text-[1.35rem] font-semibold leading-none">
                    {usd(a?.costUsd ?? 0)}
                  </div>
                  <div className="mt-1 text-[0.625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
                    {t("common.cost")}
                  </div>
                </div>
              </div>
              <div className="mt-3 text-[0.75rem] text-[rgb(var(--text-dim))]">
                {t("fmt.eventsSub", { n: fullNumber(a?.events ?? 0) })}
              </div>
            </GlassCard>

            <GlassCard variant="plain" className="p-4">
              <div className="truncate text-[0.6875rem] font-semibold text-[rgb(var(--text-faint))]" title={effectiveB}>
                {effectiveB || "—"}
              </div>
              <div className="mt-3 grid grid-cols-2 gap-3">
                <div>
                  <div className="tnum text-[1.35rem] font-semibold leading-none">
                    {tokens(b?.totalTokens ?? 0)}
                  </div>
                  <div className="mt-1 text-[0.625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
                    {t("common.tokens")}
                  </div>
                </div>
                <div>
                  <div className="tnum text-[1.35rem] font-semibold leading-none">
                    {usd(b?.costUsd ?? 0)}
                  </div>
                  <div className="mt-1 text-[0.625rem] uppercase tracking-[0.07em] text-[rgb(var(--text-faint))]">
                    {t("common.cost")}
                  </div>
                </div>
              </div>
              <div className="mt-3 text-[0.75rem] text-[rgb(var(--text-dim))]">
                {t("fmt.eventsSub", { n: fullNumber(b?.events ?? 0) })}
              </div>
            </GlassCard>
          </div>

          <div className="grid shrink-0 grid-cols-2 gap-3">
            <StatTile
              label={t("compare.tokenChange")}
              icon={<GitCompare size={12} />}
              value={tokens(Math.abs((a?.totalTokens ?? 0) - (b?.totalTokens ?? 0)))}
              delta={modelTokenDelta}
              caption={t("compare.aVsB")}
              accent="rgb(var(--accent) / 0.55)"
            />
            <StatTile
              label={t("compare.costChange")}
              icon={<Coins size={12} />}
              value={usd(Math.abs((a?.costUsd ?? 0) - (b?.costUsd ?? 0)))}
              delta={modelCostDelta}
              caption={t("compare.aVsB")}
              accent="rgb(var(--accent-2) / 0.5)"
            />
          </div>
        </>
      )}
    </div>
  );
}
