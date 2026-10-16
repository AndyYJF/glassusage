# GlassUsage Pure Flutter Migration Status

> Target Repository: `c:\Users\AndyYan\AGV\glassusage`  
> Master Plan: [`PLAN.md`](../PLAN.md)

## Stage Progress Overview

| Stage | Name | Status | Verification |
|---|---|---|---|
| **P0** | 仓库重置与旧代码归档 + Flutter SDK 环境准备 | ✅ Completed | Upstream archived to `reference/upstream/`; Flutter SDK at `c:\Users\AndyYan\AGV\flutter-sdk` |
| **P1** | 新建 Flutter Windows 工程骨架 + 存储与定价层 | ✅ Completed | `test/pricing_test.dart` & `test/store_test.dart` passed |
| **P2** | 后台常驻 Isolate 服务框架 + 防抖事件流 | ✅ Completed | `UsageWorkerIsolate` & `UsageServiceClient` implemented with 150ms coalescing & 30s `detect()` TTL |
| **P3** | 10 个 Agent 采集器完整实现 + 纯 Dart Zstd 解码器 | ✅ Completed | All 10 collectors (`Claude`, `Codex`, `Cursor`, `Antigravity`, `OpenCode`, `Hermes`, `OpenClaw`, `Pi`, `Kimi`, `DSH`) + `test/collectors_test.dart` passed |
| **P4** | 远程 SSH 同步、DPAPI 凭据加密与状态管理 | ✅ Completed | `dpapi.dart`, `ssh_client.dart`, `remote_sync.dart`, `app_providers.dart` |
| **P5** | Liquid Glass UI 全面开发（含 GPU 预算与帧率约束） | ✅ Completed | `DashboardPage`, `UsagePage`, `ComparePage`, `AgentDetailPage`, `SettingsPage`, `MiniCardView`, `OnboardingModal` + `test/widget_test.dart` passed |
| **P6** | 桌面集成（系统托盘、全局热键、双模窗口切换、开机自启） | ✅ Completed | `win32_bridge.dart` + `flutter_window.cpp` + `win32_window.cpp` (`Shell_NotifyIconW`, `Ctrl+Alt+G`, DWM Acrylic/Mica, 24px→12px edge snap, `HKCU\...\Run\GlassUsage`) |
| **P7** | 全量测试、性能审计与 Windows Release 构建 | ✅ Completed | `flutter analyze` (0 issues), `flutter test` (16/16 passed), `flutter build windows --release` |

---

## Anti-Jank Architectural Checklist (Enforced from `PLAN.md` §2.1, §3.2, §5.1, §6.1)

- [x] **Rule 1 (Zero Main-Isolate I/O)**: All SQLite queries (`getOverview`, `getTimeseries`, `getAgentStats`, `getUsageLog`, `getGroupStats`, `getSourceHealth`, `exportCsv`, `exportJson`, `exportMonthlyReport`) and filesystem `detect()` checks execute strictly inside `usageWorkerIsolateMain` (`lib/data/isolate/usage_worker_isolate.dart`).
- [x] **Rule 2 (SQLite Indexing & Rollup Fast-Paths)**:
  - [x] Enabled `PRAGMA journal_mode = WAL;` and `PRAGMA busy_timeout = 5000;` in `lib/data/database/app_database.dart`
  - [x] Created composite index `idx_ev_src_inst_ts ON usage_events(source, instance, ts_ms)`
  - [x] Rewrote `_rebuildRollupDaysTx` to use range bounds `WHERE ts_ms >= ?2 AND ts_ms < ?3` instead of `WHERE date(ts_ms/1000, ...)`
  - [x] Routed `overview` (`today`, `yesterday`, `thisWeek`, `lastWeek`) and `day`/`week` `timeseries` queries through `daily_rollup`
- [x] **Rule 3 (Single-Stream `LiveRates` & In-Memory Today Cache)**:
  - [x] Background Isolate pushes `LiveRates` once per second via `live-tick`; today's totals are cached in memory (`_cachedTodayDay`, `_cachedTodayTokens`, `_cachedTodayCost`) and invalidated only on new ingestion or day rollover.
- [x] **Rule 4 (Debounced Health & Usage Streams)**:
  - [x] Coalesced `source-status` and `usage-updated` notifications within a `150ms` window; cached `detect()` paths for `30s` (`_kDetectCacheTtlMs = 30000`).
- [x] **Rule 5 (Flutter GPU & Widget Rebuild Discipline)**:
  - [x] Enforced `BackdropFilter` budget (`GlassCard.useBlur` defaults to `false`; only Sidebar, TopBar, and Modal overlays enable `BackdropFilter`)
  - [x] Paused `Odometer` animations via `TickerMode(enabled: isWindowVisible)` when hidden to tray or when `animatedBackground == false`
  - [x] Kept refraction slider drag in local `StatefulWidget` state (`_draggingRefraction`) and persisted only on `onChangeEnd`
  - [x] Wrapped `Odometer`, `Sparkline`, `UsageChart`, and `CalendarHeatmap` in `RepaintBoundary`
  - [x] Scoped `liveRatesProvider` (`1 Hz`) subscriptions exclusively to `_LiveTelemetryBanner`, `_HeaderLiveBadge`, and `MiniCardView`
