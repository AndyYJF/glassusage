# Flutter timeline: actual user drag, 2026-11-12

## Capture and validity

- Ordinary Debug preview PID34044, HWND393462; both synthetic-probe flags unset. Capture exclusion affinity17 retained. No screen capture helper, synthetic stripes, WPR, code rebuild or source change.
- First marker-triggered recording was idle: user explicitly clarified that no drag took place. Second marker sample had1233 valid identical window rectangles and232 cursor positions: not moving-window evidence. Preserve both as non-drag samples, not latency measurements.
- Final motion-trigger sample: motion-trigger-vm-34044.json,20.175103seconds,268825 events,1220 valid window samples and576 coordinate changes. Main sustained movement approximately5.7-14.9seconds, additional short movements near beginning and18seconds.
- Window sampling uses GetWindowRect/GetCursorPos, not screenshots. VM/QPC calibration half-round-trip uncertainty12.05625ms. Cannot use this data for sub-frame coordinate-to-present latency.
- Ring readback every~1second; maximum RPC walltime121.5069ms. Framework PipelineItem IDs are consecutive through long gaps, with texture-only events present inside those gaps. There are8 unmatched raster end records at the capture boundary; do not infer perfect trace completeness.

## Measured CPU-side event durations

| Event | Median | p95 | Maximum |
|---|---:|---:|---:|
| Framework Frame |0.288ms|1.234ms|4.190ms|
| UI-produced item to GPURasterizer::Draw entry |0.014ms|0.028ms|0.343ms|
| Rasterizer::DrawToSurfaces near motion |1.241ms|1.982ms|18.833ms|
| FlutterCompositorPresentLayers callback |0.131ms|0.394ms|0.798ms|

PipelineItem flow end occurs AFTER consumer drawing, not at raster start. Its t-to-f median0.929ms includes drawing; it must not be labelled queue wait. Queue metric above matches each flow end to its containing GPURasterizer::Draw span and measures t-to-span-entry instead.

## Frame cadence: important interpretation

GPURasterizer::Draw / Framework Frame omit texture-only redraws. Largest apparent framework gap546ms contains32 VsyncFireCallback begin/end pairs plus texture rendering work. It is NOT a546ms rendering freeze.

Local engine source proves the reason:
- shell/common/shell.cc OnPlatformViewMarkTextureFrameAvailable schedules Engine::ScheduleFrame(false), without rebuilding the layer tree.
- shell/common/rasterizer.cc DrawLastLayerTrees calls DrawToSurfaces directly, bypassing the GPURasterizer::Draw event.
- shell/common/pipeline.h Consume ends PipelineItem only after consumer returns.

Using Rasterizer::DrawToSurfaces instead,537 intervals overlapped at least one sampled coordinate change: median13.297ms,p9520.864ms. Two long intervals166.577ms and136.456ms each contain only ONE sampled coordinate change. The next-largest is35.659ms with2 changes. Without same-frame crop/content data and with12ms alignment uncertainty, the two isolated-change gaps are not proof of150ms continuous-drag stalls, nor can they simply be discarded as harmless.

## What this supports, and what remains missing

No evidence here of a repeated150ms framework computation, raster execution, or framework-to-raster backlog. This narrows the investigation; it does NOT prove zero end-to-end lag, prove UU responsible, or establish physical display latency.

FlutterCompositorPresentLayers returns after the Windows compositor's SwapBuffers call; its CPU duration is not GPU completion, DWM scanout, or UU delivery. SceneDisplayLag is computed against target-vsync times by Flutter, not a physical presentation observation. Also no same-run native crop/frame-sequence log was found at the expected temp path. Therefore this trace cannot link a specific background sample to its eventual composed pixels.

Follow-up2026-11-13: native34044 log became available after exit. Approximate alignment yielded20summary buckets,645callbacks,585worker-sampled moves,0fallback/outside and0.361ms weighted callback duration(max1.217ms). The earlier missing-log statement describes the observation at analysis time, not its final availability. User subsequently approved and completed a continuous synthetic sequence/pixel probe; see CONTINUOUS_COMPOSED_RESULT.md for measured ordinary coordinate/content mismatch and extreme fallback. No application code diagnostics were added for that follow-up.

## Restoration

- Stopped verified Debug PID34044 only after capture finished.
- Launched installed C:/App/GlassUsage/glassusage.exe without either probe flag. PID38336 verified, installed desktop_glass_plugin.dll and flutter_windows.dll loaded. Installed main window is currently hidden/tray state; no visual rendering acceptance claimed.
- Persisted widgetRefraction45.2 and widgetChromatic0.3 match the original backup exactly; no settings edit needed. Top-level refraction0.203125 is a DIFFERENT main-window setting, not mini-window optics.
- No source/build/test/package/commit/push/release this phase. Only disposable diagnostic clients and reports changed.
