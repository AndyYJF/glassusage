import { useMemo, useState } from "react";
import { Activity, Coins, Gauge, RefreshCw, Zap } from "lucide-react";

import { GlassButton } from "../components/glass/GlassButton";
import { GlassCard } from "../components/glass/GlassCard";
import { GlassSegmented } from "../components/glass/GlassSegmented";
import { RangePicker } from "../components/RangePicker";
import { StatTile } from "../components/StatTile";
import { UsageChart } from "../components/charts/UsageChart";
import { ShareList } from "../components/charts/ShareList";
import { SourceStatusGrid } from "../components/SourceStatusGrid";
import { api } from "../lib/api";
import { useOverview, useRange, useTimeseries } from "../lib/hooks";
import { useT, type MessageKey } from "../lib/i18n";
import { bucketFor, useUi, type RangeKey } from "../lib/store";
import { delta, fullNumber, percent, tokens, unpricedNote, usd } from "../lib/format";
import { sourceLabel } from "../lib/sources";

/** Labels that track the range selector instead of hard-coding "today". */
function rangeLabelKeys(key: RangeKey): {
  tokens: MessageKey;
  cost: MessageKey;
  cache: MessageKey;
  compare: MessageKey;
} {
  switch (key) {
    case "today":
      return {
        tokens: "dash.tokensToday",
        cost: "dash.costToday",
        cache: "dash.cacheHit",
        compare: "common.vsYesterday",
      };
    case "7d":
      return {
        tokens: "dash.tokens7d",
        cost: "dash.cost7d",
        cache: "dash.cache7d",
        compare: "common.inThisRange",
      };
    case "30d":
      return {
        tokens: "dash.tokens30d",
        cost: "dash.cost30d",
        cache: "dash.cache30d",
        compare: "common.inThisRange",
      };
    case "90d":
      return {
        tokens: "dash.tokens90d",
        cost: "dash.cost90d",
        cache: "dash.cache90d",
        compare: "common.inThisRange",
      };
    case "all":
      return {
        tokens: "dash.tokensAll",
        cost: "dash.costAll",
        cache: "dash.cacheAll",
        compare: "common.allTime",
      };
    case "1d":
    case "14d":
    case "custom":
      return {
        tokens: "dash.tokensRange",
        cost: "dash.costRange",
        cache: "dash.cacheRange",
        compare: "common.inThisRange",
      };
  }
}

export function Dashboard({ onOpenAgent }: { onOpenAgent: (source: string) => void }) {
  const { t } = useT();
  const notify = useUi((s) => s.notify);
  const [metric, setMetric] = useState<"tokens" | "cost">("tokens");
  const [rescanning, setRescanning] = useState(false);

  const { key, from, to } = useRange();
  const { data: overview, isLoading } = useOverview();
  const { data: series } = useTimeseries("source");

  const metrics = useMemo(
    () => [
      { value: "tokens" as const, label: t("common.tokens") },
      { value: "cost" as const, label: t("common.cost") },
    ],
    [t],
  );

  const rescan = async () => {
    setRescanning(true);
    try {
      await api.rescanAll();
      notify(t("dash.rescanning"));
    } catch (e) {
      notify(String(e), "error");
    } finally {
      // The scan runs on a background thread; the spinner marks the request, not the work.
      window.setTimeout(() => setRescanning(false), 1200);
    }
  };

  // Tiles 1/2/4 follow the selected range. "Today" is only special for the delta baseline.
  const stats = overview?.range;
  const labels = rangeLabelKeys(key);
  const cacheRate = stats
    ? stats.cacheReadTokens /
      Math.max(1, stats.inputTokens + stats.cacheReadTokens + stats.cacheWriteTokens)
    : 0;

  const topAgent = overview?.perSource?.[0];
  const tokenDelta =
    key === "today" ? delta(stats?.totalTokens ?? 0, overview?.yesterday.totalTokens ?? 0) : null;
  const costDelta =
    key === "today" ? delta(stats?.costUsd ?? 0, overview?.yesterday.costUsd ?? 0) : null;

  const localizeUnpriced = (kind: "none" | "partial", count: number) =>
    kind === "none"
      ? t("fmt.noPrice")
      : t("fmt.excludesUnpriced", { n: fullNumber(count) });

  return (
    <div className="scroll-area flex h-full flex-col gap-3 overflow-y-auto pr-1">
      <div className="flex shrink-0 items-center gap-3">
        <h1 className="text-[1.05rem] font-semibold tracking-tight">{t("dash.title")}</h1>
        <div className="ml-auto flex items-center gap-2">
          <RangePicker />
          <GlassButton
            size="sm"
            onClick={rescan}
            disabled={rescanning}
            title={t("dash.rescanTitle")}
          >
            <RefreshCw size={13} className={rescanning ? "animate-spin" : undefined} />
            {t("common.rescan")}
          </GlassButton>
        </div>
      </div>

      <div className="grid shrink-0 grid-cols-4 gap-3">
        <StatTile
          label={t(labels.tokens)}
          icon={<Zap size={12} />}
          value={tokens(stats?.totalTokens ?? 0)}
          delta={tokenDelta}
          caption={
            key === "today"
              ? t("common.vsYesterday")
              : t("fmt.eventsSub", { n: fullNumber(stats?.events ?? 0) })
          }
          accent="rgb(var(--accent) / 0.55)"
        />
        <StatTile
          label={t(labels.cost)}
          icon={<Coins size={12} />}
          value={usd(stats?.costUsd ?? 0)}
          delta={costDelta}
          caption={
            unpricedNote(stats, localizeUnpriced) ??
            (key === "today" ? t("common.vsYesterday") : t(labels.compare))
          }
          accent="rgb(var(--accent-2) / 0.5)"
        />
        <StatTile
          label={t("dash.events")}
          icon={<Activity size={12} />}
          value={fullNumber(stats?.events ?? 0)}
          caption={
            topAgent
              ? t("dash.topAgent", {
                  name: sourceLabel(topAgent.key),
                  pct: percent(topAgent.share),
                })
              : t("dash.noActivity")
          }
          accent="rgb(var(--info) / 0.45)"
        />
        <StatTile
          label={t(labels.cache)}
          icon={<Gauge size={12} />}
          value={percent(cacheRate, 1)}
          caption={t("dash.cacheServed", { n: tokens(stats?.cacheReadTokens ?? 0) })}
          accent="rgb(var(--success) / 0.4)"
        />
      </div>

      {/* The page scrolls, so these rows must keep their natural height. Letting them
          flex-shrink would squeeze the fixed-height chart out of its card and over the
          panel below. */}
      <div className="grid shrink-0 grid-cols-[1fr_320px] gap-3">
        <GlassCard variant="lens" className="flex min-w-0 flex-col p-4">
          <div className="mb-1 flex items-center gap-3">
            <h2 className="text-[0.875rem] font-semibold">{t("dash.usageOverTime")}</h2>
            <GlassSegmented
              className="ml-auto"
              options={metrics}
              value={metric}
              onChange={setMetric}
              size="sm"
            />
          </div>
          <UsageChart
            data={series ?? []}
            bucket={bucketFor(key, from, to)}
            metric={metric}
            colorBy="source"
            height={264}
          />
        </GlassCard>

        <GlassCard variant="lens" className="flex flex-col p-4">
          <h2 className="mb-2 text-[0.875rem] font-semibold">{t("dash.byAgent")}</h2>
          <ShareList
            items={overview?.perSource ?? []}
            metric={metric}
            colorBy="source"
            onSelect={onOpenAgent}
            emptyText={isLoading ? t("common.loading") : t("common.noUsage")}
          />
        </GlassCard>
      </div>

      <SourceStatusGrid onOpenAgent={onOpenAgent} />
    </div>
  );
}
