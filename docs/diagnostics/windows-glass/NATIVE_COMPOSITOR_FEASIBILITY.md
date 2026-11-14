# Native compositor feasibility, 2026-11-13

Research only. Existing failed callback prototype not accepted, no tracked source or build changes in this phase. Installed app remains running, currentPID30744/pathC:/App/GlassUsage/glassusage.exe verified; it is minimized. Mini optics still45.2/0.3.

## Verified API contracts

1. IDCompositionDevice::Commit batches DirectComposition calls for ONE device into one transaction; independent devices have no same-frame guarantee. This does not include arbitrary SetWindowPos calls.
   https://learn.microsoft.com/en-us/windows/win32/api/dcomp/nf-dcomp-idcompositiondevice-commit
   https://learn.microsoft.com/en-us/windows/win32/directcomp/basic-concepts
2. IDCompositionSurface BeginDraw/EndDraw allows bitmap updates to be committed with visual-property changes. Candidate must use this rather than assume a separate DXGI swapchain Present joins the same transaction.
   https://learn.microsoft.com/en-us/windows/win32/api/dcomp/nf-dcomp-idcompositionsurface-begindraw
   https://learn.microsoft.com/en-us/windows/win32/directcomp/composition-surface
3. CompositionEffectBrush cannot take arbitrary custom shaders. Win2D DisplacementMapEffect is explicitly NoComposition/not supported by Windows.UI.Composition. A host backdrop brush with native blur is therefore NOT an equivalent port of the existing SDF refraction/chromatic shader.
   https://learn.microsoft.com/en-us/uwp/api/windows.ui.composition.compositioneffectbrush
   https://microsoft.github.io/Win2D/WinUI3/html/T_Microsoft_Graphics_Canvas_Effects_DisplacementMapEffect.htm
4. CreateSurfaceFromHwnd wraps a LAYERED window's rasterization for composition. A cloaked layered source may continue composing; off-screen or zero-size sources stop composing. This is only a candidate Flutter-content bridge, not proven compatibility.
   https://learn.microsoft.com/en-us/windows/win32/api/dcomp/nf-dcomp-idcompositiondevice-createsurfacefromhwnd
   https://learn.microsoft.com/en-us/windows/win32/directcomp/how-to--animate-the-bitmap-of-a-layered-child-window

## Current implementation boundary

- SDK source FlutterWindow::InitializeChild creates a normal WS_CHILD|WS_VISIBLE window with exstyle0. ANGLE Manager::CreateWindowSurface creates an EGL window surface; native compositor calls eglSwapBuffers.
- Read-only runtime metadata confirms installed FLUTTERVIEW HWND67752/exstyle0/classstyle3, not layered. Root also not layered(exstyle0x100). Must not assume CreateSurfaceFromHwnd will automatically expose the Flutter/ANGLE child plus alpha correctly.
- Public Flutter Windows headers provide native window/graphics adapter/external texture registration, not an exposed rendered-frame surface export in the inspected API. Do not fake such an API or hook private engine/DWM functions without an explicit architectural decision.
- TomLo-FStack/win-liquid-glass is itself a prototype, still displays its lens in a moving top-level HWND. Its native GPU path is useful for optics and capture reference but is NOT proof of atomic HWND movement/content presentation.
   https://github.com/TomLo-FStack/win-liquid-glass

## Candidate to verify, not yet implement into product

Keep a composition host stationary while the visible card is represented by a translated native visual. Render backdrop into IDCompositionSurface; commit surface update and the visible card's offset via the SAME device/batch. This avoids per-drag SetWindowPos of the visible host. All visible layers must share the same offset, including Flutter foreground; moving just the background would recreate a different synchronization split.

Two independent gates before integration:

1. A standalone fixed-host synthetic-pattern program, with classified-pixel readback, must show that content/offset really stay aligned and that latency is not merely shifted into mouse/visual response. It should auto-exit and not touch installed GlassUsage.
2. Flutter foreground export/alpha/live redraw and input coordinate routing need compatibility verification. Layering/cloaking is supported in general, but live Flutter/ANGLE content is not established. Also test hit testing/click-through outside the visible card, DPI/monitor changes, focus and UU visibility. A full-monitor transparent host is NOT approved or safe to assume; input interception is a material product change.

No full application migration should start merely because Commit exists. If the Flutter bridge is incompatible, either a custom rendering host or native mini UI would be a larger explicitly scoped change. Do not silently replace liquid refraction with Acrylic/blur.

## Tools and state

Requested Tavily CLI skill inspected; no tvly/tavily-cli executable installed, so used built-in web search and only primary Microsoft/GitHub project sources; no dependency install. Diagnostic window_state.py only gained read-only window style/child inventory fields.

Next authority required: permission to briefly display an independent bounded native composition test window, auto-exit, no app installation/source changes and no desktop screenshot files. Do not start a full-screen/input-intercepting host or cloak the installed app without approval.
