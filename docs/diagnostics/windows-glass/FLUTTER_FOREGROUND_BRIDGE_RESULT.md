# Flutter foreground bridge validation — 2026-11-13

## Scope and outcome

Independent, bounded native DirectComposition host only. Installed GlassUsage PID30744 stayed running. No product source, engine binary, installed files or settings changed. Temporary fixture/reader builds only; no image files, global mouse injection, release or packaging.

The initial `CreateSurfaceFromHwnd` Flutter bridge fails the alpha requirement. A direct premultiplied RGBA foreground upload passes the narrow alpha/live-content gate. This is NOT a completed drag repair or evidence of a production-ready/high-refresh-rate implementation.

## Controlled evidence

First alpha-control run:

- Logs: `flutter-bridge-20261113T013024Z-source.log` and `-pixels.log`.
- Same compositor, same foreground visual, same blue-gray native underlay RGB204060.
- Flutter HWND source: 1514 decoded images; opaque red/green patch updates after routed click, but half-red is800000 and clear is000000.
- Known `UpdateLayeredWindow(AC_SRC_ALPHA)` source replacing only foreground: 1690 decoded code197 images; all opaque red FF0000, half-red902030, clear204060.
- Therefore the compositor's foreground blending and HWND wrapper can preserve per-pixel alpha with the known source. This Flutter HWND export route does not. The exact Flutter/ANGLE/redirection internal stage is not isolated, and this candidate-bridge limitation is distinct from the original drag lag.

Three-path confirmation:

- Logs: `flutter-bridge-20261113T013229Z-source.log` and `-pixels.log`.
- Native fixture moves only the DirectComposition visual group inside a fixed1280x520host. No physical HWND drag or physical input test.
- Seconds3–11: Flutter layered/cloaked HWND foreground. 1376 decoded images, 42 distinct foreground codes. All303 before-click samples FF0000/800000/000000; all1073 after-click samples00FF00/800000/000000. Alpha fails again.
- Seconds11–15: known native alpha foreground. All579 decoded code197 images FF0000/902030/204060. Positive control passes.
- Seconds15–20: same Dart picture exported via `Picture.toImageSync` -> `Image.toByteData(rawRgba)` -> private binary messenger -> BGRA `IDCompositionSurface`. All735 decoded images00FF00/902030/204060. Observed all26 codes141–166; content is live, not a static window shell. No invalid-color sample among decoded RGBA images;5 boundary/exit images lack a complete code and are not accepted samples.
- Received pixels log half=0x80800000, clear=0x00000000. Local SDK documents rawRgba as premultiplied alpha; channel swap to BGRA does not repremultiply it.
- One private routed click at seconds5: native local64,64 -> Dart `pointer_down` physical64,64,clicks1 -> composed patch changes red to green. It occurred during the HWND phase. This is not proof of physical mouse drag, mouse capture, DPI transforms, hit-through outside the card, or post-switch input latency.
- Probe and reader both exited0; orchestrator verified settings SHA256 unchanged. Final process inventory: installed30744 still running; no flutter_bridge_probe.exe or lagprobe_bridge.exe remains.

## Interpretation and remaining work

Together with NATIVE_ATOMIC_PROBE_RESULT.md, evidence supports separating the stable native host/atomic background geometry from a transparent Flutter foreground. It does not justify wrapping the current opaque Flutter HWND as-is.

The RGBA route is a compatibility proof, not the selected production architecture: it performs GPU readback, CPU channel conversion and reupload. Fixture content changes only every200ms (about5Hz), not60/240Hz. Real widgets, rounded edges, slider interaction, texture lifecycle, multi-monitor/DPI, and export cost still require targeted validation before integration.

Next useful independent gate: actual native refracted background plus the proven transparent foreground, measuring geometry/background mismatch and cadence, with genuine drag/hit-test behavior. Keep original screen exclusion topology and avoid full-screen input interception. Do not treat more frame-callback waits on the rejected prototype as a repair.

Physical scanout and UU delivery latency remain unmeasured. DXGI composed-image timestamps here are local desktop-image observations, not physical display times. Original optics45.2/0.3 and installed app remained untouched.
