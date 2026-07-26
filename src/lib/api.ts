/** Typed wrappers over the Tauri command layer in `src-tauri/src/commands.rs`. */
import { invoke } from "@tauri-apps/api/core";
import type {
  AgentStats,
  AppSettings,
  CursorStatus,
  GroupStat,
  LiveRates,
  ModelPrice,
  OverviewStats,
  Page,
  PricingInfo,
  RemoteInstance,
  RemoteInstanceInput,
  SeriesPoint,
  SourceHealth,
  TestReport,
  TimeRange,
  UsageFilter,
  UsageRow,
} from "./types";

export type Bucket = "hour" | "day" | "week";
export type GroupBy = "source" | "model_norm" | "provider" | "instance" | "project";

export const api = {
  overview: (range: TimeRange) => invoke<OverviewStats>("get_overview", { range }),

  agentStats: (source: string, range: TimeRange) =>
    invoke<AgentStats>("get_agent_stats", { source, range }),

  timeseries: (range: TimeRange, groupBy: GroupBy, bucket: Bucket, source?: string) =>
    invoke<SeriesPoint[]>("get_timeseries", { range, groupBy, bucket, source }),

  usageLog: (filter: UsageFilter, page: number, pageSize: number) =>
    invoke<Page<UsageRow>>("get_usage_log", { filter, page, pageSize }),

  groupStats: (column: GroupBy, filter: UsageFilter) =>
    invoke<GroupStat[]>("get_group_stats", { column, filter }),

  sourceHealth: () => invoke<SourceHealth[]>("get_source_health"),

  filterOptions: () => invoke<Record<string, string[]>>("get_filter_options"),

  rescanSource: (source: string, instance?: string, purge = false) =>
    invoke<void>("rescan_source", { source, instance, purge }),

  rescanAll: () => invoke<void>("rescan_all"),

  liveRates: () => invoke<LiveRates>("get_live_rates"),

  exportCsv: (filter: UsageFilter, path?: string) =>
    invoke<string>("export_csv", { filter, path }),

  exportJson: (filter: UsageFilter, path?: string) =>
    invoke<string>("export_json", { filter, path }),

  exportMonthlyReport: (filter: UsageFilter, path?: string) =>
    invoke<string>("export_monthly_report", { filter, path }),

  // settings
  getSettings: () => invoke<AppSettings>("get_settings"),
  setSettings: (patch: Partial<AppSettings> | Record<string, unknown>) =>
    invoke<AppSettings>("set_settings", { patch }),

  // pricing
  pricingInfo: () => invoke<PricingInfo>("get_pricing_info"),
  setPricingOverrides: (overrides: Record<string, ModelPrice>) =>
    invoke<number>("set_pricing_overrides", { overrides }),
  removePricingOverride: (model: string) =>
    invoke<number>("remove_pricing_override", { model }),
  refreshPricing: () => invoke<number>("refresh_pricing"),

  // cursor
  cursorStatus: () => invoke<CursorStatus>("get_cursor_status"),
  setCursorCookie: (token: string) => invoke<void>("set_cursor_cookie", { token }),
  syncCursorNow: () => invoke<void>("sync_cursor_now"),

  // remote
  listRemote: () => invoke<RemoteInstance[]>("list_remote_instances"),
  upsertRemote: (cfg: RemoteInstanceInput) => invoke<void>("upsert_remote_instance", { cfg }),
  deleteRemote: (name: string) => invoke<void>("delete_remote_instance", { name }),
  testRemote: (cfg: RemoteInstanceInput) => invoke<TestReport>("test_remote_instance", { cfg }),
  syncRemote: (name: string) => invoke<number>("sync_remote_instance", { name }),

  // window & app
  toggleWidgetMode: (on: boolean) => invoke<void>("toggle_widget_mode", { on }),
  showMainWindow: (route?: string) => invoke<void>("show_main_window", { route }),
  minimize: (label: string) => invoke<void>("window_minimize", { label }),
  toggleMaximize: (label: string) => invoke<void>("window_toggle_maximize", { label }),
  closeWindow: (label: string) => invoke<void>("window_close", { label }),
  setWidgetAlwaysOnTop: (on: boolean) => invoke<void>("set_widget_always_on_top", { on }),
  snapWidget: () => invoke<void>("widget_snap_to_edge"),
  quit: () => invoke<void>("quit_app"),
  openDataDir: () => invoke<void>("open_data_dir"),
};
