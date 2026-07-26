/**
 * Data hooks.
 *
 * The backend pushes a `usage-updated` event whenever a scan actually stores something,
 * so queries do not poll on a timer. A short debounce coalesces the burst of events that
 * a single agent turn produces (one per file write) into one refetch.
 */
import { useEffect, useRef } from "react";
import { listen } from "@tauri-apps/api/event";
import { useQuery, useQueryClient } from "@tanstack/react-query";

import { api, type Bucket, type GroupBy } from "./api";
import { tokens, usd } from "./format";
import { useT } from "./i18n";
import { bucketFor, resolveRange, useUi, type RangeKey } from "./store";
import { sourceLabel } from "./sources";
import type {
  AgentStats,
  AppSettings,
  BudgetAlertEvent,
  LiveRates,
  OverviewStats,
  SeriesPoint,
  SourceHealth,
  SourceStatusEvent,
  UsageFilter,
  UsageUpdatedEvent,
} from "./types";

/** Align both ends to the minute so rolling windows (e.g. 1d) keep a stable query key. */
function stabilize(from: number, to: number) {
  const minute = 60_000;
  const f = Math.floor(from / minute) * minute;
  const t = Math.floor(to / minute) * minute;
  return { from: f, to: Math.max(f, t) };
}

export function useRange() {
  const range = useUi((s) => s.range);
  const customFrom = useUi((s) => s.customFrom);
  const customTo = useUi((s) => s.customTo);
  const endFollowsNow = useUi((s) => s.endFollowsNow);

  if (range === "custom") {
    const to = endFollowsNow ? Date.now() : customTo;
    return { key: range as RangeKey, ...stabilize(customFrom, Math.max(customFrom, to)) };
  }
  const resolved = resolveRange(range);
  return { key: range as RangeKey, ...stabilize(resolved.from, resolved.to) };
}

export function useOverview() {
  const { key, from, to } = useRange();
  return useQuery<OverviewStats>({
    queryKey: ["overview", key, from, to],
    queryFn: () => api.overview({ from, to }),
  });
}

export function useTimeseries(groupBy: GroupBy = "source", bucket?: Bucket, source?: string) {
  const { key, from, to } = useRange();
  const b = bucket ?? bucketFor(key, from, to);
  return useQuery<SeriesPoint[]>({
    queryKey: ["timeseries", key, from, to, groupBy, b, source ?? "all"],
    queryFn: () => api.timeseries({ from, to }, groupBy, b, source),
  });
}

export function useAgentStats(source: string) {
  const { key, from, to } = useRange();
  return useQuery<AgentStats>({
    queryKey: ["agent", source, key, from, to],
    queryFn: () => api.agentStats(source, { from, to }),
    enabled: Boolean(source),
  });
}

export function useUsageLog(filter: UsageFilter, page: number, pageSize: number) {
  return useQuery({
    queryKey: ["usage-log", filter, page, pageSize],
    queryFn: () => api.usageLog(filter, page, pageSize),
    placeholderData: (prev) => prev,
  });
}

export function useGroupStats(column: GroupBy, filter: UsageFilter) {
  return useQuery({
    queryKey: ["group", column, filter],
    queryFn: () => api.groupStats(column, filter),
  });
}

export function useSourceHealth() {
  return useQuery<SourceHealth[]>({
    queryKey: ["health"],
    queryFn: api.sourceHealth,
    // Health includes "seconds since last scan", which drifts on its own.
    refetchInterval: 15_000,
  });
}

export function useSettings() {
  return useQuery<AppSettings>({
    queryKey: ["settings"],
    queryFn: api.getSettings,
    staleTime: Infinity,
  });
}

export function useFilterOptions() {
  return useQuery({
    queryKey: ["filter-options"],
    queryFn: api.filterOptions,
    staleTime: 60_000,
  });
}

export function usePricingInfo() {
  return useQuery({ queryKey: ["pricing"], queryFn: api.pricingInfo, staleTime: Infinity });
}

export function useRemoteInstances() {
  return useQuery({ queryKey: ["remote"], queryFn: api.listRemote });
}

export function useCursorStatus() {
  return useQuery({ queryKey: ["cursor-status"], queryFn: api.cursorStatus });
}

/**
 * Live RPM/TPM. This one does poll: the rates decay continuously between events, so the
 * number has to keep moving even when nothing new arrives.
 */
export function useLiveRates(intervalMs = 1000) {
  return useQuery<LiveRates>({
    queryKey: ["live"],
    queryFn: api.liveRates,
    refetchInterval: intervalMs,
    refetchIntervalInBackground: false,
  });
}

/** Wires backend events to cache invalidation. Mount once, at the app root. */
export function useBackendEvents() {
  const qc = useQueryClient();
  const { t } = useT();
  const notify = useUi((s) => s.notify);
  const timer = useRef<number | null>(null);

  useEffect(() => {
    const flush = () => {
      timer.current = null;
      qc.invalidateQueries({ queryKey: ["overview"] });
      qc.invalidateQueries({ queryKey: ["timeseries"] });
      qc.invalidateQueries({ queryKey: ["agent"] });
      qc.invalidateQueries({ queryKey: ["usage-log"] });
      qc.invalidateQueries({ queryKey: ["group"] });
      qc.invalidateQueries({ queryKey: ["health"] });
    };

    const unlisten = [
      listen<UsageUpdatedEvent>("usage-updated", () => {
        // One agent turn can rewrite a transcript several times in a second.
        if (timer.current !== null) return;
        timer.current = window.setTimeout(flush, 600);
      }),
      listen<SourceStatusEvent>("source-status", () => {
        qc.invalidateQueries({ queryKey: ["health"] });
      }),
      listen<BudgetAlertEvent>("budget-alert", (e) => {
        const { kind, value, limit, sources } = e.payload;
        const scoped = sources && sources.length > 0;
        const agents = scoped ? sources.map(sourceLabel).join(", ") : "";
        if (kind === "cost") {
          notify(
            scoped
              ? t("budget.costCrossedScoped", { value: usd(value), limit: usd(limit), agents })
              : t("budget.costCrossed", { value: usd(value), limit: usd(limit) }),
            "error",
          );
        } else {
          notify(
            scoped
              ? t("budget.tokensCrossedScoped", {
                  value: tokens(value),
                  limit: tokens(limit),
                  agents,
                })
              : t("budget.tokensCrossed", {
                  value: tokens(value),
                  limit: tokens(limit),
                }),
            "error",
          );
        }
      }),
      listen("settings-changed", () => {
        qc.invalidateQueries({ queryKey: ["settings"] });
      }),
    ];

    return () => {
      if (timer.current !== null) window.clearTimeout(timer.current);
      unlisten.forEach((p) => p.then((fn) => fn()).catch(() => {}));
    };
  }, [qc, notify, t]);
}
