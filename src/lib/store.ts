/** Client-side UI state. Server data lives in TanStack Query, not here. */
import { create } from "zustand";
import type { UsageFilter } from "./types";

export type RangeKey = "today" | "1d" | "7d" | "14d" | "30d" | "90d" | "all" | "custom";

/** Quick-select chips inside the range picker (excludes free-form custom). */
export const RANGE_PRESETS: Exclude<RangeKey, "custom">[] = [
  "today",
  "1d",
  "7d",
  "14d",
  "30d",
  "90d",
  "all",
];

/** @deprecated Prefer RANGE_PRESETS + useT */
export const RANGE_KEYS = RANGE_PRESETS;

/** @deprecated Prefer building labels via useT + RANGE_PRESETS */
export const RANGE_OPTIONS: { value: RangeKey; label: string }[] = [
  { value: "today", label: "Today" },
  { value: "1d", label: "1 day" },
  { value: "7d", label: "7 days" },
  { value: "14d", label: "14 days" },
  { value: "30d", label: "30 days" },
  { value: "90d", label: "90 days" },
  { value: "all", label: "All" },
];

const DAY = 86_400_000;

function localMidnight(d = new Date()): Date {
  const m = new Date(d);
  m.setHours(0, 0, 0, 0);
  return m;
}

/** Day boundaries follow local midnight so "Today" matches the user's clock. */
export function resolveRange(key: Exclude<RangeKey, "custom">): { from: number; to: number } {
  const now = Date.now();
  const midnight = localMidnight().getTime();
  switch (key) {
    case "today":
      return { from: midnight, to: now };
    case "1d": {
      // Rolling 24h, minute-aligned so React Query does not thrash on every render.
      const to = Math.floor(now / 60_000) * 60_000;
      return { from: to - DAY, to: now };
    }
    case "7d":
      return { from: midnight - 6 * DAY, to: now };
    case "14d":
      return { from: midnight - 13 * DAY, to: now };
    case "30d":
      return { from: midnight - 29 * DAY, to: now };
    case "90d":
      return { from: midnight - 89 * DAY, to: now };
    case "all":
      return { from: 0, to: now };
  }
}

/** Bucket width that keeps a chart around 30–90 points regardless of span. */
export function bucketFor(key: RangeKey, from?: number, to?: number): "hour" | "day" | "week" {
  if (key === "custom" && from != null && to != null) {
    return bucketForSpan(to - from);
  }
  if (key === "today" || key === "1d") return "hour";
  if (key === "7d" || key === "14d" || key === "30d" || key === "90d") return "day";
  if (key === "all") return "week";
  return "day";
}

export function bucketForSpan(ms: number): "hour" | "day" | "week" {
  if (ms <= 36 * 3_600_000) return "hour";
  if (ms <= 90 * DAY) return "day";
  return "week";
}

interface UiState {
  range: RangeKey;
  /** Epoch ms for custom ranges. Ignored when `range !== "custom"`. */
  customFrom: number;
  customTo: number;
  /** When true, custom (and live-resolving presets) keep `to` at now. */
  endFollowsNow: boolean;
  setRange: (r: Exclude<RangeKey, "custom">) => void;
  setCustomRange: (from: number, to: number, endFollowsNow?: boolean) => void;

  /** Filters shared by the Usage page and CSV export. */
  filter: UsageFilter;
  setFilter: (patch: Partial<UsageFilter>) => void;
  resetFilter: () => void;

  /** Applied to <html> so CSS variables switch theme without a re-render cascade. */
  resolvedTheme: "dark" | "light";
  setResolvedTheme: (t: "dark" | "light") => void;

  toast: { id: number; message: string; tone: "info" | "error" } | null;
  notify: (message: string, tone?: "info" | "error") => void;
  dismissToast: () => void;
}

const defaultCustom = (() => {
  const { from, to } = resolveRange("7d");
  return { customFrom: from, customTo: to };
})();

export const useUi = create<UiState>((set) => ({
  range: "7d",
  ...defaultCustom,
  endFollowsNow: true,
  setRange: (range) => set({ range, endFollowsNow: true }),
  setCustomRange: (customFrom, customTo, endFollowsNow = false) =>
    set({
      range: "custom",
      customFrom,
      customTo: Math.max(customFrom, customTo),
      endFollowsNow,
    }),

  filter: {},
  setFilter: (patch) => set((s) => ({ filter: { ...s.filter, ...patch } })),
  resetFilter: () => set({ filter: {} }),

  resolvedTheme: "dark",
  setResolvedTheme: (resolvedTheme) => set({ resolvedTheme }),

  toast: null,
  notify: (message, tone = "info") => set({ toast: { id: Date.now(), message, tone } }),
  dismissToast: () => set({ toast: null }),
}));
