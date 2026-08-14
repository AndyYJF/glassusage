/** Presentation metadata for each agent: label, brand colour, and how it is read. */
import type { HealthStatus, SourceId } from "./types";

export interface SourceMeta {
  id: SourceId;
  label: string;
  /** CSS variable holding the brand colour as an `R G B` triple. */
  colorVar: string;
  /** Short description of where the numbers come from, shown in Settings. */
  origin: string;
  realtime: boolean;
}

export const SOURCE_META: Record<SourceId, SourceMeta> = {
  claude: {
    id: "claude",
    label: "Claude Code",
    colorVar: "--src-claude",
    origin: "~/.claude/projects/**/*.jsonl",
    realtime: true,
  },
  codex: {
    id: "codex",
    label: "Codex",
    colorVar: "--src-codex",
    origin: "~/.codex/sessions/**/*.jsonl",
    realtime: true,
  },
  cursor: {
    id: "cursor",
    label: "Cursor",
    colorVar: "--src-cursor",
    origin: "Cursor dashboard API",
    realtime: false,
  },
  antigravity: {
    id: "antigravity",
    label: "Antigravity",
    colorVar: "--src-antigravity",
    origin: "Antigravity IDE + CLI databases",
    realtime: true,
  },
  opencode: {
    id: "opencode",
    label: "OpenCode",
    colorVar: "--src-opencode",
    origin: "~/.local/share/opencode storage",
    realtime: true,
  },
  hermes: {
    id: "hermes",
    label: "Hermes Agent",
    colorVar: "--src-hermes",
    origin: "~/.hermes/state.db",
    realtime: true,
  },
  openclaw: {
    id: "openclaw",
    label: "OpenClaw",
    colorVar: "--src-openclaw",
    origin: "~/.openclaw databases and archives",
    realtime: true,
  },
  pi: {
    id: "pi",
    label: "Pi",
    colorVar: "--src-pi",
    origin: "~/.pi/agent/sessions/**/*.jsonl",
    realtime: true,
  },
  kimi: {
    id: "kimi",
    label: "Kimi Code",
    colorVar: "--src-kimi",
    origin: "~/.kimi-code/sessions/**/wire.jsonl",
    realtime: true,
  },
  dsh: {
    id: "dsh",
    label: "DeepSeek Harness",
    colorVar: "--src-dsh",
    origin: "~/.dsh/sessions/**/session.jsonl.zstd",
    realtime: true,
  },
};

export const SOURCE_LIST = Object.values(SOURCE_META);

export function sourceLabel(id: string): string {
  return SOURCE_META[id as SourceId]?.label ?? id;
}

/** Usable directly in `color:`/`fill:` — chart libraries need a concrete colour string. */
export function sourceColor(id: string, alpha = 1): string {
  const v = SOURCE_META[id as SourceId]?.colorVar ?? "--accent";
  return alpha === 1 ? `rgb(var(${v}))` : `rgb(var(${v}) / ${alpha})`;
}

/**
 * Recharts writes colours into SVG attributes, where `var()` is not resolved. Reading
 * the computed value once gives a literal `rgb()` string the charts can use.
 */
export function resolveSourceColor(id: string, alpha = 1): string {
  const v = SOURCE_META[id as SourceId]?.colorVar ?? "--accent";
  const triple = getComputedStyle(document.documentElement).getPropertyValue(v).trim();
  if (!triple) return alpha === 1 ? "#7aa2ff" : `rgba(122,162,255,${alpha})`;
  const [r, g, b] = triple.split(/\s+/);
  return alpha === 1 ? `rgb(${r} ${g} ${b})` : `rgb(${r} ${g} ${b} / ${alpha})`;
}

export const STATUS_LABEL: Record<HealthStatus, string> = {
  live: "Live",
  polling: "Polling",
  missing: "Not found",
  error: "Error",
  disabled: "Disabled",
};

export const STATUS_CLASS: Record<HealthStatus, string> = {
  live: "status-live",
  polling: "status-polling",
  missing: "status-missing",
  error: "status-error",
  disabled: "status-disabled",
};

/**
 * One status pill per source in the sidebar / dashboard strip.
 *
 * Remote Hermes/OpenClaw rows share the same `source` id with a different `instance`.
 * Prefer a working remote over a missing local install — otherwise OpenClaw stays grey
 * forever when the only copy lives on a server.
 */
export function rollupSourceStatus(
  rows: { status: HealthStatus }[] | undefined,
): HealthStatus {
  if (!rows?.length) return "missing";
  if (rows.some((r) => r.status === "error")) return "error";
  if (rows.some((r) => r.status === "live")) return "live";
  if (rows.some((r) => r.status === "polling")) return "polling";
  if (rows.some((r) => r.status === "disabled")) return "disabled";
  return "missing";
}
