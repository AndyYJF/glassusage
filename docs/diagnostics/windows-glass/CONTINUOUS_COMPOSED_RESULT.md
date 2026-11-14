# Continuous motion: measured local position/content mismatch

Date:2026-11-13. Existing Debug probe only; no application source change or rebuild.

## Result

Two distinct mechanisms are supported by same-run callback, native movement and composed-pixel evidence:

1. A callback can crop at the correct current window coordinate, yet the same texture remains visible after the independently moving window has advanced. This happens without prefetch fallback. The local composed desktop already contains position/content mismatch; UU is not its sole possible origin.
2. During extreme motion, the window can leave the256px prefetched region before the callback. Existing code then uses frame.window_rect, not current geometry. This adds stale-crop error on top of subsequent callback-to-composition movement.

This is NOT evidence of a150ms blocking API or proof that all subjective/remote latency has been explained. The precise split among texture marking/coalescing, upload, GPU queue and DWM inside the callback-to-image phase is not individually instrumented.

## Scope and artifacts

- Native PID20244, HWND2428982; GLASSUSAGE_LAG_PROBE=1, extra move notification absent, mini optics0/0.
- User manually dragged; watcher used per-monitor-v2 DPI awareness and launched existing lagprobe.exe after real movement. No mouse simulation or screenshot helper.
- Reader: continuous-composed-20244.log. Native: C:/Users/AndyYan/AppData/Local/Temp/glassusage-latency-20244.log. Shared QPC frequency10000000.
-20second reader finished exit0:1690 desktop-image frames,35 accumulated/missed updates.
-1431 decoded frames passed code-row consistency and independent64px stripe-phase crosscheck.44 have partially clipped codes. Full8bit subset1387 frames used for crop-vs-motion decomposition.
-259 frames rejected:150 no usable code row,75 disagreeing rows,23 stripe check failures,11 old/ambiguous code matches. Retain rejection accounting; do not interpolate these as known-good samples.
-2764 native position events and958 callback events within accepted capture bounds. Callback gaps median17.721ms,p9535.1632ms,max54.6556ms. These are not actual monitor refresh rates.

## Observed age and normal-motion evidence

- First OBSERVED composed image of each decoded callback sequence:820 sequences, median9.4139ms,p9517.1865ms,max36.0652ms after callback log. Capture may miss intermediate updates, so these are observation timestamps, not a guarantee of first physical presentation.
- All decoded images include texture reuse: age median13.2071ms,p9531.2377ms,max50.0236ms. This is callback-to-observed-desktop-image age, NOT source-desktop content age or UU delivery time.
- First5seconds/full-code443frames: crop coordinate matched the latest native movement exactly in every frame; horizontal mismatch median6px,p9528px,max101px. Callback age median13.39ms,p9531.0651ms. Therefore prefetch fallback does not explain the ordinary-motion mismatch.

### Clean same-sequence example

Callback seq2845 atQPC59373115450 chose physical view1702,161,2350,611; native window coordinate was also1702,161, with9.4084ms since preceding movement and2.7876ms until next movement. No crop-position ambiguity.

| Observed image QPC | Age after callback | Composed window left | Texture sampled left | Horizontal mismatch |
|---|---:|---:|---:|---:|
|59373201931|8.6481ms|1695|1702|-7px|
|59373290988|17.5538ms|1695|1702|-7px|
|59373379196|26.3746ms|1678|1702|-24px|

At the last image, both native geometry at image time and reader live bounds are1678; the pattern still encodes seq2845/view1702. Thus the displayed window has moved24px while its background texture remains anchored to the earlier coordinate. Intermediate image geometry1695 vs live1683 also shows native/composed window movement can differ transiently; use decoded pixel bounds, not GetWindowRect alone, for displayed geometry.

Raw row forQPC59373379196: the decoded lower code band starts1678 and encodes2845&255=29. Upper stripe green edge occurs2024, matching original screen-anchored edge2048 shifted by-24. Code and stripe provide independent checks.

## Extreme-motion fallback is a separate amplifier

-13 full-code decoded frames have callback crop coordinate differing by>32px from latest native position. Overlapping native per-second summaries report outside/fallback counts1,7,16,4 in the extreme-motion portion; both counters agree.
- Example seq3672 atQPC59542333871: callback view.left1789, but latest native x983 (preceding move8.2717ms earlier; next move4.2762ms later). Already806px stale at callback.
- At composed imageQPC59542536467,20.2596ms later, window pixels are atx484 while texture still samples1789: total mismatch-1305px = -806px stale crop plus -499px subsequent displayed-window displacement. This is not1305px caused entirely by a20ms presentation delay.
- Native code at MiniDesktopCapture's PixelBuffer callback initializes view=frame.window_rect and replaces it only if current client rect fits frame.source_rect and monitor matches. Read-only source tracing plus outside/fallback counters explain the stale-crop mechanism.

## Reused ordinary-mode evidence

The previous Debug34044 logfile became available after exit and was preserved. Approximate alignment of its20second Flutter trace with native metrics (QPC/GetTickCount64 calibration from the later probe, so bucket precision only) finds20summary buckets:645callbacks,585worker-sampled moves,0fallbacks/outside; weighted callback CPU duration0.361ms,max1.217ms. It corroborates that ordinary-mode delay did not require a slow CPU crop or out-of-prefetch fallback. Do not add position-sample-to-crop age to late-cropped geometry age; they are different quantities.

## Limits and repair direction

- Despite planned horizontal movement, capture includes vertical motion and screen-edge clipping, especially extreme late segments. Full-code/early subsets and raw checks are reported separately; extreme maxima are not typical-user latency estimates.
- Synthetic pattern replaces real desktop pixels and intentionally allows capture of the mini. It retains callback/texture/compositor paths, not real desktop content-age behavior. Independent readback itself adds load.
-9-31ms local texture age at a240Hz monitor spans multiple refresh periods, but exact physical scanout and UU latency remain unmeasured.
- Correct repair target is position/content synchronization plus the out-of-prefetch fallback policy. Extra notification alone was already inconclusive in paired runs; increasing padding/frame rate alone cannot guarantee alignment after callback. Any renderer/drag architecture change needs a scoped implementation proposal and controlled validation, not another blind patch.

## Restoration verified

- Probe20244 and reader exited. Original installed C:/App/GlassUsage/glassusage.exe is running asPID25696, no probe flags in launch.
- Only mini optical settings restored45.2/0.3; all other settings preserved. While first restored instance10332 was running, the file later contained44.784775/0.475317 (writer attribution not proven). Stopped that verified installed process, patched only the two fields while stopped, relaunchedPID25696; two subsequent reads confirm45.2/0.3.
- No claim of visual acceptance of the restored main window; installed app is in tray/hidden-main state. No source/build/test/commit/push/release.
