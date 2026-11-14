# Native refraction + Flutter foreground validation — 2026-11-13

## Outcome

The independent prototype demonstrates native SDF lens/seven-path dispersion rendering from a GPU desktop snapshot, transparent Flutter RGBA foreground, and same-device surface/visual-position commits. Automatic movement produces no position-tag mismatch in accepted composed images, including the high-rate segment.

This is not the GlassUsage repair. Background is frozen; actual physical drag and complete input/hit testing have not been exercised. No project source, installed binary, database, credentials, screen-exclusion setting or saved desktop image changed. User selected “later; save results first” for the physical drag step.

## Evidence and controls

### A — initial attempt: invalid movement sample

`native-refraction-20261113T015326Z-source.log` / `-pixels.log`, PID33268.

- Native lens shaders compile and render to offscreen textures, but child cloaking fails with E_HANDLE before movement begins. This new branch omitted the already-established layered-child prerequisite; restored it in the temporary fixture only.
- No native movement updates or decoded tags. Zero observed mismatches here is NOT a pass.
- The initial frozen-input lens-on/off comparison changes0pixels; this alone does not show a shader failure or a useful textured input.
- Earlier diagnostic compile error was an ambiguous RectangleClip zero literal between animation-pointer/float overloads; fixed only0 ->0.f.

### B — valid ordinary frozen desktop, automatic motion

`native-refraction-20261113T015602Z-source.log` / `-pixels.log`, PID36476.

- 3786 desktop-image observations,3411 decoded position/sequence images; all0px mismatch.
- Requested60Hz:463updates, all463 independently observed; actual57.8615Hz;1150decoded images. CPU prepare-to-Commit median0.2955ms/p950.4154ms. Prepare-to-first-observed-desktop-image median4.6677ms/p957.7747ms.
- Requested240Hz:1890updates,1887independently observed; actual210.1086Hz;2261decoded images. CPU prepare-to-Commit median0.2575ms/p950.3956ms. First desktop observation median4.2381ms/p956.3493ms. Three updates not independently observed; this is not proof that each was displayed or dropped.
- Offscreen frozen-input lens-on/off still changes0pixels, with258176visible pixels. A separately uploaded known checker changes27203pixels/max RGBdelta253. All representable-premultiplied checks pass; corner alpha0.
- Thus native optics operates on a known textured input, but this ordinary frozen desktop sample is not a textured-backdrop optics acceptance.

### C — controlled desktop source: complete frozen-input chain

`native-refraction-20261113T015829Z-source.log` / `-pixels.log`, PID14788.

Before capture, a bounded1280x520owned GDI checker window is displayed and DwmFlush completes. Desktop Duplication copies one frame to a GPU shader-resource texture. The owned checker window exits immediately after capture. The host then presents a matching frozen snapshot and the refracted moving card. No monitor-wide input window, continuous feedback capture, exclusion toggles or image files.

- Captured output0,0–2560,1600, BGRA87. `ProtectedContentMaskedOut=1`: DXGI reports some protected content masked somewhere in the output. Its location/cause is not established; no attempt was made to disable protection. The controlled checker region is present and varied, with flat-render RGB range02CB3F–FF25B1.
- On the captured checker, refraction45.2/chromatic0.3 changes27081pixels, max RGBdelta253; known uploaded checker control changes27203pixels. Both show258176visible pixels,0invalid premultiplied pixels,corner alpha0.
- 3670 desktop-image observations,3325 accepted joint position/sequence images;0mismatches,0px max deviation.345images lack a complete accepted tag pair, including startup/boundaries. No ambiguous accepted tag pair.

| Requested rate | Actual submit rate | Submitted / independently observed updates | Decoded images | Mismatch | First desktop observation median / p95 |
|---|---:|---:|---:|---:|---:|
|60Hz|57.6492Hz|461 /461|1149|0px|4.7309 /6.9482ms|
|240Hz|209.5774Hz|1886 /1857|2176|0px|4.2224 /6.3779ms|

High-rate29updates were not independently observed. Seven accumulated reader updates were reported missed. Frame merging, capture sampling and reader misses are not separated; do not claim every submitted frame displayed.

CPU prepare-to-Commit:60Hz median0.2922/p950.4118/max1.932ms; high-rate median0.23945/p950.390425/max1.1925ms. These are CPU wall times, not GPU execution measurements. Submit intervals:60Hz median17.2471/p9518.1873ms; high-rate median4.7111/p955.5466ms. The requested240Hz cadence was not attained.

Flutter foreground remains a5Hzfixture.105RGBA messages received. At seconds5 in RGBA mode, private host-to-child click at64,64 yields Dart pointer_down64,64/clicks1. This is a routed-message input proof, not physical mouse capture or input-to-display latency.

## Measurement method and limits

- Fixed1280x520host at120,220;648x400card moves horizontally inside it. The HWND itself does not move. Same-device EndDraw + visual offset + Commit is the transaction being validated.
- Two native28px-total diagnostic bands bypass optics:12x54px cells encode texture's intended absolute left and sequence. Their actual desktop-image positions are measured independently of encoded left. The rest runs the native lens shader beneath the separate transparent foreground.
- Initial decoder expected one contiguous648px G/M cluster. The controlled checker also falls in G/M classifier ranges, merging with tags; that decoder returned no samples. Corrected offline without recapture: require twelve complete uniform54px cells in both rows, unique joint decoding, and sequence/source-position consistency. The decoder does NOT require actual left==encoded left; that difference is the measured error. Rejected or ambiguous images are not counted as aligned.
- Tag alignment proves geometry and tagged surface consistency, not pixel-for-pixel equivalence of the full refracted image to GLSL or scene features. HLSL port includes SDF lens, depth normal and seven-path dispersion with saturation1.25; blur, interactive glow, original framework widgets, real foreground export cost and full optical parity are not accepted here.
- Snapshot is captured once. Live dynamic-background freshness, screen-exclusion feedback topology, physical mouse dragging, capture cancellation, click-through, vertical movement, cross-monitor/DPI, and native-host bounds/repositioning remain unverified.
- DXGI LastPresentTime is a local desktop-image update observation, not physical scanout or UU delivery. The4–7ms statistics are preparation-to-first-observed image times for this prototype, not total user-visible latency or a guarantee of improvement over installed GlassUsage.

## State at handoff

- Both valid20second runs exited0; each reader exited0; orchestrator settings SHA256 before/after matches.
- Installed GlassUsage remained running; optics45.2/0.3 left unchanged.
- All probe code/builds/logs are under this temporary directory. Product branch remains fix/windows-glass-parity with inherited dirty work and the earlier rejected frame-callback prototype preserved. No commit/push/release/install.
- Physical drag sample deferred by user; do not launch it until user resumes. Next useful step is an independent manual horizontal-drag entry point and a movement-triggered bounded capture; never tell the user to drag an unstarted instance.
