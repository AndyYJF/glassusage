# GlassUsage

A Windows desktop monitor for the tokens your local AI coding agents are burning, with an
Apple Liquid Glass interface.

GlassUsage reads the logs and databases those agents already write to disk. It does not
proxy, intercept, or man-in-the-middle any traffic, and it never sends your data anywhere.

## What it reads

| Agent | Where the numbers come from | Update mode |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl` | File watcher |
| Codex | `~/.codex/sessions/**/*.jsonl` | File watcher |
| Cursor | Cursor dashboard API | Polling |
| Antigravity | IDE state database + CLI database | File watcher |
| OpenCode | `~/.local/share/opencode` storage | File watcher |
| Hermes Agent | `~/.hermes/state.db` | File watcher |
| OpenClaw | `~/.openclaw` databases and archives | File watcher |

Remote Hermes and OpenClaw instances can be added over SSH. GlassUsage pulls a consistent
read-only snapshot of the remote SQLite file; nothing is installed on the remote host.

## Requirements

- Windows 10 1809+ or Windows 11 (acrylic and mica need Windows 11 to look their best)
- WebView2 runtime (preinstalled on Windows 11, bundled by the installer otherwise)
- To build: Node 20+, Rust stable (MSVC toolchain), and the Visual Studio C++ build tools

## Install

Download the latest Windows installer from
[Releases](https://github.com/AndyYJF/glassusage/releases).

Upgrading from an older build: run the new `GlassUsage_*_x64-setup.exe` over the existing
install. Keep the same per-user installer — it reuses `com.glassusage.desktop` / `GlassUsage`
so the previous install directory is replaced in place and
`%APPDATA%\com.glassusage.desktop` (usage DB, settings, credentials) is left untouched.

From 0.3.0 onward you can also update in-app: **Settings → Updates → Check for updates**.
That path verifies a Tauri minisign signature from GitHub Releases before installing.

Or build from source:

```bash
npm install
npm run app:dev      # dev build with hot reload
npm run app:build    # NSIS installer → src-tauri/target/release/bundle/nsis/
```

`npm run dev` alone starts only the frontend, which is useful for UI work but shows no
data, since every query goes through the Rust backend. Note that a debug build loads the
Vite dev URL, so `cargo build` on its own gives a window that cannot connect until
`npm run dev` is also running — use `npm run app:dev` instead.

## How it works

```
agent log files ──> collectors (Rust) ──> normalize ──> usage.db (SQLite)
                                                            │
     file watcher / poll timer ─────────────────────────────┤
                                                            v
                                          Tauri IPC ──> React UI + mini card
```

Each collector turns its source's records into a common `UsageEvent` and writes them to a
local aggregate database. Three details do most of the work:

**Incremental reads.** Every file keeps a watermark of how far it has been parsed, so a
rescan reads only what is new. Rotation and truncation are detected and reset the
watermark rather than silently skipping data.

**Deduplication.** Every event carries a `dedup_key` derived from stable identifiers in the
source. Streaming agents rewrite the same message as it grows, so those sources upsert on
that key and the totals converge instead of accumulating. Re-importing from scratch is
therefore always safe.

**Costs.** A cost reported by the agent itself always wins. Only events that arrive without
one are priced from the LiteLLM table, and anything with no matching entry is shown as
`unpriced` rather than counted as zero.

Sources that are missing, disabled, or failing to parse say so on the dashboard, so a low
number is never mistaken for low usage.

## Where your data lives

Everything stays in `%APPDATA%\com.glassusage.desktop`:

- `usage.db` — the aggregate database
- `settings.json` — preferences
- `pricing-cache.json` — the LiteLLM price table, refreshed daily
- `remote/` — snapshots pulled from remote instances

Credentials (the Cursor session token, SSH passwords) are encrypted with Windows DPAPI and
are readable only by your Windows account on this machine.

## The glass

The refraction is a real optical effect, not a blur. `backdrop-filter: url(#lens-card)`
runs an SVG filter chain over whatever is behind the element: a displacement map bends the
backdrop where the surface curves, and running that displacement three times at slightly
different strengths — recombining one colour channel from each — produces the chromatic
fringe that real glass has at its rim.

This is expensive, so it is rationed. Primary surfaces get the lens; list rows and chips
get plain blur. The Settings slider scales the displacement and disables it entirely at
zero, which is the setting to reach for if dragging the window feels heavy on older
hardware.

The displacement maps and the app icon are generated, not hand-drawn. They are committed
because the Rust build reads the icons at compile time, but you can rebuild them with:

```bash
npm run assets
```

The mini card is toggled from the tray menu or with `Ctrl+Alt+G`. That chord is registered
globally, so it is deliberately not a `Ctrl+Shift+<letter>` combination — those belong to
whichever editor or browser you are actually working in.

## Project layout

```
src/                     React UI
  components/glass/      Glass primitives and the SVG filter definitions
  components/charts/     Recharts wrappers and the calendar heat map
  pages/                 Dashboard, Usage, Agent detail, Settings
  widget/                Always-on-top mini card (separate window)
  lib/                   Typed IPC layer, formatting, hooks, UI state
src-tauri/src/
  collectors/            One module per agent, plus the protobuf reader
  store.rs               SQLite schema, deduplication, rollups, queries
  pricing.rs             Price table, model normalization, overrides
  live.rs                Sliding-window RPM/TPM
  watcher.rs             File watchers, poll timers, debounce
  remote/                SSH transport and snapshot sync
scripts/                 Asset generators, plus schema probes and screenshot capture
```

`scripts/` also holds the tools used to verify a build against a real machine:
`probe-schema.mjs`, `probe-sqlite.mjs` and `probe-antigravity*.mjs` dump only the *shape* of
each agent's on-disk records (key paths, value types, DDL) so parsers can be checked without
reading anyone's conversations; `inspect-usage-db.mjs` and `probe-pricing.mjs` cross-check
what a run actually collected and priced; `capture-window.ps1` and `capture-widget.ps1`
screenshot the running app.

## Releases & signing

Tagged releases (`v*`) build through `.github/workflows/release.yml`.

**Updater signatures (required for in-app updates).** Tauri minisign keys:

- Private key: keep only as GitHub Actions secret `TAURI_SIGNING_PRIVATE_KEY` (and optional
  `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`). Locally it lives in `.tauri/glassusage.key` (gitignored).
- Public key: baked into `src-tauri/tauri.conf.json` → `plugins.updater.pubkey`.

Local signed build:

```bash
# PowerShell
$env:TAURI_SIGNING_PRIVATE_KEY_PATH = "$PWD\.tauri\glassusage.key"
npm run app:build
```

**Authenticode / SmartScreen (optional).** A purchased code-signing certificate reduces
Windows warnings. Set CI secrets `TAURI_SIGNING_CERTIFICATE` (base64 PFX) and
`TAURI_SIGNING_CERTIFICATE_PASSWORD`, or configure `bundle.windows.certificateThumbprint`
for a local certificate store. This is separate from the updater minisign key above.
