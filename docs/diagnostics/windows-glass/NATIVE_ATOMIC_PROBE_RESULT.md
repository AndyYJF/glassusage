# Independent fixed-host DirectComposition probe

Date2026-11-13. User explicitly approved a standalone native test window. No GlassUsage source/build/installation changes and no app shutdown in this phase.

## Construction

- Independent native_comp_probe.exe; bounded1280x520popup host atphysical120,220, not a full-monitor/input-intercepting host. Program auto-exits20seconds after start; Esc abort supported.
- Host HWND never moves. Gray host background and648x400green/magenta card are DirectComposition visuals on ONE device.
- Each card update calls IDCompositionSurface::BeginDraw, updates BGRA pixels, EndDraw, changes the card's X offset, and calls Commit once. Surface content encodes absolute screen stripe phase and an8bit sequence. Offset and new surface contents therefore belong to the same batch.
- Automatic sinusoidal motion spans card left152..720; slower2second cycles then faster0.5second cycles. This is not mouse input or a live desktop-refraction workload.
- Existing standalone lagprobe.exe reads six classified pixel rows; no desktop screenshots stored. An isolated start event coordinates processes, then both auto-exit. Installed GlassUsage PID30744 remained running.

## Artifacts

- native_comp_probe.cpp; build-native-comp.bat; run_native_comp_probe.py.
- native-atomic-20261113T010350Z-source.log: surface-update origins,sequence,QPC,Commit return times.
- native-atomic-20261113T010350Z-pixels.log: classified composed rows/QPC, not images.
- native-atomic-20261113T010350Z-pixels.log.decoded.json: decoded frame records.
- Decoder gained explicit --surface and --pattern-width=648 options. It reads visual_frame as a planned surface update, NOT a Flutter callback. Existing probe defaults preserved.

## Observations

- Source program and reader exit0.652total surface updates, including one initial stationary update and651dynamic updates during20seconds.
- Reader1608desktop-image updates,1accumulated/missed update.1606decoded frames;2no-code frames around window exit. No partially clipped codes.
- Excluding initial waiting/sequence0:1595decoded dynamic images, covering ALL651dynamic source sequences.
- Horizontal content-to-visible-position error across these1595images: median0px,p950px,maximum0px;0nonzero mismatches. Decoder uses both independent sequence bits and absolute stripe phase, the same checks that detected338px mismatches in the failed HWND/frame-callback prototype.
- First OBSERVED composed image after each planned surface-update timestamp: median5.2916ms,p957.4086ms,max27.352ms. This is not physical scanout or mouse-to-display latency. The initial stationary sequence waited for capture setup and is explicitly excluded; its~400ms age is not a rendering stall.
- CPU preparation/update/Commit-return duration: median0.8816ms,p951.2178ms,max2.6516ms.
- Source update interval: median30.6998ms,p9531.658ms,max32.9156ms(~33Hz). Current simple sleep-based test pacing was not a60/240Hz performance benchmark. Do not infer a DirectComposition frame-rate ceiling or a cursor-latency improvement from this run.

## Interpretation

PASS for the narrowly defined geometry/content coherence gate: in this run, a fixed host plus same-device surface-content/visual-offset Commit avoided the split observed with SwapBuffers plus independent SetWindowPos. This supports the architectural direction; it is NOT completion of the GlassUsage repair.

Not tested: real desktop capture and optical shader workload; live Flutter foreground export/alpha; mouse-hit routing/click-through; focus; DPI/multiple monitors; UU visual equivalence; input-to-display latency;60/240Hz pacing. These are separate integration gates. Do not transplant the prior failed callback prototype or claim production readiness based only on this synthetic success.

## Preservation

- Source and reader processes exited; process inventory shows only the pre-existing installedGlassUsagePID30744.
- SHA256of settings.json before/after run is identical. Installed app and settings not edited or restarted. Original45.2/0.3 values remain intact.
- Only temporary diagnostic code/decoder/report files changed. No project code edit, project build, dependency install, commit,push or release.
- Initial diagnostic compile failed because IDC_ARROW defaulted to an ANSI resource pointer with explicit LoadCursorW; defined UNICODE and rebuilt successfully. No app build involved.
