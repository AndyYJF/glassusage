# Fixed Flutter host candidate — 2026-11-14

Status: candidate implementation, not deployed. Base checkpoint eaca649.

## Change

The Windows mini card now moves inside a fixed transparent virtual-desktop host.
The captured texture stays in desktop coordinates. Card placement and the
inverse texture sampling transform are submitted in the same Flutter scene.
The existing liquid_glass.frag optics remain unchanged. The failed
frame-callback/SetWindowPos drag protocol is no longer called.

A layered host uses mouse hit routing before User32 dispatch to pass outside
clicks to other applications, while keeping Flutter mouse capture during drag.
The capture worker assembles all attached outputs into a stable desktop atlas.
Only desktop changes publish a new texture; card movement does not require a
capture publication. CPU readback/upload remains a performance cost.

## Completed checks

- Windows Debug build and targeted Dart analysis passed for first candidate.
- Isolated application data directory; installed app and its settings untouched.
- Actual candidate HWND remained at physical 0,0–2560,1600 while card moved.
- Automated mouse gesture lasted approximately8seconds with929target samples;
  12second desktop reader observed1682images and10accumulated missed updates.
- Refraction32 / dispersion1.2 remained enabled. Full64px interior green strips
  in1096images gave5428independent edge observations, all0px error against fixed
  screen coordinates (green start at multiples of512). Other images lacked
  eligible full strips and were not counted as aligned.
- Of distinct observed card positions, 770 had eligible edges,
  4043 edge observations, maximum0px error.
- Observed card left positions span588..1895px. Classifier uses rows160..220;
  foreground text and refracted card boundaries are excluded by interior
  distance and exact full-stripe-width requirements. This is not a complete
  per-pixel optical comparison or proof that every submitted frame displayed.
- Returning to main restored native bounds80,60–1910,1260 and normal styles;
  no crash observed in this transition.
- Real-desktop run with normal capture exclusion started and reported valid
  frames, approximately59fps and a12.95ms last-frame age sample. This alone does
  not establish dynamic-background pixel accuracy or end-to-end latency.

## Pending

Multi-monitor/mixed-DPI, display reconfiguration,
capture cancellation under interference, and long-running performance remain
unverified on this machine. The fixed host retains its own DPI across monitors;
monitor-specific card scaling needs explicit evaluation before release.
Do not call local composed-image timing physical scanout or UU latency.

Raw evidence and disposable tools:
C:/Users/AndyYan/Desktop/codex/.codex_tmp/glassusage-fixed-host/

## Final native build and real-background checks

- Final native targets built into an isolated bundle after card-luminance and
  hidden-resume corrections; EXE and DLL changes verified. Direct Link target
  initially skipped work, so only the subsequent full native Build counts.
- Final running candidate: PID11524 at observation time,
  C:/Users/AndyYan/Desktop/codex/.codex_tmp/glassusage-fixed-host/candidate-final/glassusage.exe.
  PID is historical: consult candidate.pid and process state before acting.
- Live desktop source displayed behind the card in three2.5second stages, with
  WDA_EXCLUDEFROMCAPTURE still0x11. Expected/observed sampled luminance:
  #101010=0.062745098; #e0e0e0=0.878431373; #208040=0.403802353.
  This validates the captured atlas under the card changes correctly despite
  host exclusion; it is not a full optical/output-pixel or latency measurement.
- Actual Win32 mouse clicks to owned underlying window: outside1click received,
  rounded transparent corner1click, card interior0clicks. Target root HWND was
  verified before sending each click. Initial fixture let activation raise the
  source window; corrected the fixture to non-activating and repeated.
- Hide/resume: valid/running epoch1 → invalid/paused epoch2 → valid/running
  epoch4, fresh background age13.73ms on return. No runtime exception logged.
- Existing installed application and settings were not overwritten. Isolated
  candidate optics32/1.2 differ from historical installed45.2/0.3 defaults;
  product code still reads the user's saved settings normally.

## User acceptance — 2026-11-14

The user tried the real-background Debug candidate and explicitly confirmed:
“拖动背景已正常，效果保留”。 This accepts the reported background-drag issue
and preservation of refraction/dispersion in the current setup. It is subjective
user evidence, not a measurement of physical scanout or UU end-to-end latency.
Multi-monitor/mixed-DPI and the other limits above remain unverified. No
deployment, installation, commit or push was requested by this feedback.
