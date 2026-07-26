/** Mirrors `src-tauri/src/model.rs`, `settings.rs` and `remote/mod.rs`. */

export const SOURCES = [
  "claude",
  "codex",
  "cursor",
  "antigravity",
  "opencode",
  "hermes",
  "openclaw",
] as const;

export type SourceId = (typeof SOURCES)[number];

export type HealthStatus = "live" | "polling" | "missing" | "error" | "disabled";

export interface TokenBreakdown {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  reasoningTokens: number;
  totalTokens: number;
  costUsd: number;
  events: number;
  /** Events excluded from `costUsd` because no price matched their model. */
  unpricedEvents: number;
}

export interface TimeRange {
  from: number;
  to: number;
}

/** `TokenBreakdown` is flattened into these by serde, hence the intersection. */
export type SeriesPoint = TokenBreakdown & {
  bucket: number;
  key: string;
};

export type GroupStat = TokenBreakdown & {
  key: string;
  label: string;
  share: number;
  unpriced: boolean;
};

export interface OverviewStats {
  today: TokenBreakdown;
  yesterday: TokenBreakdown;
  thisWeek: TokenBreakdown;
  lastWeek: TokenBreakdown;
  range: TokenBreakdown;
  perSource: GroupStat[];
}

export interface AgentStats {
  source: string;
  totals: TokenBreakdown;
  perModel: GroupStat[];
  perProject: GroupStat[];
  perInstance: GroupStat[];
  calendar: [string, number][];
}

export interface UsageRow {
  id: number;
  tsMs: number;
  source: string;
  surface: string;
  instance: string;
  provider: string | null;
  model: string;
  modelNorm: string;
  project: string | null;
  sessionId: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  reasoningTokens: number;
  costUsd: number | null;
  unpriced: boolean;
}

export interface UsageFilter {
  from?: number;
  to?: number;
  sources?: string[];
  instances?: string[];
  providers?: string[];
  models?: string[];
  search?: string;
}

export interface Page<T> {
  rows: T[];
  total: number;
  page: number;
  pageSize: number;
}

export interface SourceHealth {
  source: string;
  instance: string;
  status: HealthStatus;
  detectedPaths: string[];
  fileCount: number;
  eventCount: number;
  lastScanMs: number | null;
  lastEventMs: number | null;
  lastError: string | null;
  skippedRows: number;
}

export interface LiveSource {
  source: string;
  rpm: number;
  tpm: number;
  active: boolean;
  polling: boolean;
}

export interface LiveRates {
  rpm: number;
  tpm: number;
  costToday: number;
  tokensToday: number;
  perSource: LiveSource[];
  spark60: number[];
}

// ------------------------------------------------------------------------ settings

export type WindowMaterial = "acrylic" | "mica" | "css";
export type ThemeMode = "system" | "dark" | "light";
export type LocaleMode = "system" | "en" | "zh";

export interface SourceConfig {
  enabled: boolean;
  customPath: string | null;
}

export interface AppSettings {
  sources: Record<string, SourceConfig>;
  material: WindowMaterial;
  theme: ThemeMode;
  locale?: LocaleMode;
  refraction: number;
  animatedBackground: boolean;
  pollSecs: number;
  cursorPollSecs: number;
  autostart: boolean;
  startMinimized: boolean;
  widgetCompact: boolean;
  widgetAlwaysOnTop: boolean;
  widgetShortcut: string;
  antigravityIdeEnabled: boolean;
  autoRefreshSecs: number;
  firstRunDone: boolean;
}

export interface ModelPrice {
  input: number;
  output: number;
  cacheRead?: number | null;
  cacheWrite?: number | null;
}

export interface PricingInfo {
  modelCount: number;
  source: string;
  overrides: Record<string, ModelPrice>;
}

export interface CursorStatus {
  hasAccessToken: boolean;
  hasCookie: boolean;
  stateDb: string | null;
  lastError: string | null;
}

// -------------------------------------------------------------------------- remote

export interface RemoteInstance {
  name: string;
  agent: "hermes" | "openclaw";
  host: string;
  port: number;
  username: string;
  authMode: "key" | "agent" | "password";
  keyPath: string | null;
  remoteHome: string | null;
  remotePath: string | null;
  pollSecs: number;
  importArchives: boolean;
  enabled: boolean;
  hasSecret: boolean;
}

export type RemoteInstanceInput = Omit<RemoteInstance, "hasSecret"> & {
  password?: string | null;
};

export interface TestStep {
  label: string;
  ok: boolean;
  detail: string;
}

export interface TestReport {
  ok: boolean;
  steps: TestStep[];
}

// --------------------------------------------------------------------------- events

/** Emitted after any scan that actually stored or updated rows. */
export interface UsageUpdatedEvent {
  source: string;
  instance: string;
  added: number;
}

export interface SourceStatusEvent {
  source: string;
  instance: string;
  status: HealthStatus;
  error: string | null;
}
