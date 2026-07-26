/** Client-side UI state. Server data lives in TanStack Query, not here. */
import { create } from "zustand";
import type { UsageFilter } from "./types";

export type RangeKey = "today" | "7d" | "30d" | "90d" | "all";

export const RANGE_KEYS: RangeKey[] = ["today", "7d", "30d", "90d", "all"];

/** @deprecated Prefer building labels via useT + RANGE_KEYS */
export const RANGE_OPTIONS: { value: RangeKey; label: string }[] = [
  { value: "today", label: "Today" },
  { value: "7d", label: "7 days" },
  { value: "30d", label: "30 days" },
  { value: "90d", label: "90 days" },
  { value: "all", label: "All" },
];

/** Default to 7 days so a quiet today does not make the dashboard look empty. */

const DAY = 86_400_000;

/** Day boundaries follow local midnight so "Today" matches the user's clock. */
export function resolveRange(key: RangeKey): { from: number; to: number } {
  const now = Date.now();
  const midnight = new Date();
  midnight.setHours(0, 0, 0, 0);
  switch (key) {
    case "today":
      return { from: midnight.getTime(), to: now };
    case "7d":
      return { from: midnight.getTime() - 6 * DAY, to: now };
    case "30d":
      return { from: midnight.getTime() - 29 * DAY, to: now };
    case "90d":
      return { from: midnight.getTime() - 89 * DAY, to: now };
    case "all":
      return { from: 0, to: now };
  }
}

/** Bucket width that keeps a chart around 30-90 points regardless of range. */
export function bucketFor(key: RangeKey): "hour" | "day" | "week" {
  if (key === "today") return "hour";
  if (key === "7d" || key === "30d") return "day";
  return key === "90d" ? "day" : "week";
}

interface UiState {
  range: RangeKey;
  setRange: (r: RangeKey) => void;

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

export const useUi = create<UiState>((set) => ({
  range: "7d",
  setRange: (range) => set({ range }),

  filter: {},
  setFilter: (patch) => set((s) => ({ filter: { ...s.filter, ...patch } })),
  resetFilter: () => set({ filter: {} }),

  resolvedTheme: "dark",
  setResolvedTheme: (resolvedTheme) => set({ resolvedTheme }),

  toast: null,
  notify: (message, tone = "info") => set({ toast: { id: Date.now(), message, tone } }),
  dismissToast: () => set({ toast: null }),
}));
