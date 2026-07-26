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
import { bucketFor, resolveRange, useUi, type RangeKey } from "./store";
import type {
  AgentStats,
  AppSettings,
  LiveRates,
  OverviewStats,
  SeriesPoint,
  SourceHealth,
  SourceStatusEvent,
  UsageFilter,
  UsageUpdatedEvent,
} from "./types";

/** Rounded so a re-render a few seconds later reuses the cached result. */
function rangeKey(key: RangeKey) {
  const { from, to } = resolveRange(key);
  return { from, to: Math.floor(to / 60_000) * 60_000 };
}

export function useRange() {
  const range = useUi((s) => s.range);
  return { key: range, ...rangeKey(range) };
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
  const b = bucket ?? bucketFor(key);
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
    ];

    return () => {
      if (timer.current !== null) window.clearTimeout(timer.current);
      unlisten.forEach((p) => p.then((fn) => fn()).catch(() => {}));
    };
  }, [qc]);
}
