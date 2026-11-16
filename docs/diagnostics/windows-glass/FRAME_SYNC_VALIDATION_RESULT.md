# Frame-callback synchronized drag: failed acceptance

2026-11-13. No code/build changes in this analysis turn. The previous native prototype remains an unaccepted local experiment on fix/windows-glass-parity, not a deployed repair.

## Capture validity

- CandidateDebug PID8228, existing synthetic stripe/code pattern, optics0/0; same standalone classified-pixel reader. No screenshot helper or simulated mouse input.
- Reader completed20seconds/exit0:1236desktop-image updates,42accumulated/missed updates.1196decoded,40rejected(11no code row,28row disagreement,1stripe failure),0partial-code frames.
- Actual capture-overlapped mouse target changes span4.6602seconds; movement loop started~0.476seconds before first accepted image and ended4.7086seconds after it. Remaining sampling time was largely idle. Do not present this as20seconds of sustained drag or a matched-speed A/B with the earlier baseline.
-3261target records,153native synchronized commits,273decoded images tied to nonzero sync tokens. These exact token-tagged images are the acceptance subset, not the decoder's broader time-near-motion heuristic.

## Acceptance result

-234/273token-tagged images align;39still mismatch(36new texture with old composed geometry,3new geometry with older texture).
-Absolute horizontal mismatch median0px,p95145px,max338px. Median0is therefore NOT sufficient to declare success.
-Native commit interval median32.9766ms,p9539.0223ms,max44.5355ms: updates effectively~30Hz during this gesture.
-Prepared texture to native commit: median15.7421ms,p9523.1806ms.
-Texture callback to native commit: median5.7557ms,p957.4763ms.
-Matched requested-coordinate sample to commit median25.052ms; this is NOT raw input-to-physical-display latency. Static/revisited coordinates can inflate target-age estimates; the195ms maximum must not be called a195ms input stall. Excluding already-current targets gives median24.8571ms,p9533.0328ms, but does not remove all coordinate-revisit ambiguity.
-At commit time, latest requested target and committed x differ by median35px,p95188px. The prototype has both residual content/geometry mismatch and a measurable cursor/window-following cost.
-Five overlapping native summary buckets report0fallbacks/0outside. The demonstrated residual mismatch is not caused by the old out-of-prefetch crop fallback.

## Decisive token106 / texture seq14580

All coordinates physical pixels; QPC frequency10000000.

| Event | QPC | Position |
|---|---:|---|
| Prepared frame |79954205736|target1721,733|
| Texture callback |79954331988|view1721,733,2369,1183;token106|
| SetWindowPos commit logged |79954395832|window1721,733|
| Composed desktop image |79954467251|window pixels start1383;texture still encodesview1721|
| Next observed image of same texture |79954515607|window pixels start1721;view1721,now aligned|

At the bad image,7.1419ms AFTER the native move commit, GetWindowRect/live bounds and latest native position are1721, yet the independently decoded composed-window left is1383. The new texture is visible in the old composed geometry,338px out of register. The same texture becomes aligned11.9775ms after the native commit.

Raw row check: RLE origin1321, full code cluster starts1383, lower code samples encode244(14580&255). Upper stripe green edge is1710, matching original absolute stripe edge2048 shifted by-338. Thus this is not solely inference from native coordinates or one decoder counter.

Across all39mismatches, observed image timestamps after corresponding native commit have median4.7013ms,p9510.9094ms,max12.4707ms. These are observed samples, not an exact continuous mismatch duration for every transition.

## Causal interpretation

The Flutter frame-drawn callback occurs after renderer submission, not at an atomic DWM geometry/content presentation point. Posting a callback and then calling SetWindowPos leaves the swapchain content and native top-level geometry on separately observable composition timelines. This experiment shifts most residual mismatches into the inverse direction(new texture / old geometry), rather than eliminating the fundamental split.

The single-inflight protocol plus60Hz worker cadence is consistent with the~33ms commit interval: waiting for completion can miss the next capture tick. This is a source-and-timing-supported explanation, not justification for blindly changing pacing; faster wakeups alone do not fix non-atomic composition.

Conclusion: reject this prototype as the final repair. Do not deploy it, claim zero lag from the aligned median, or add DwmFlush/sleeps/repeated callbacks without a method that can couple visual content and position at the compositor boundary. A genuinely coupled native composition design must be assessed before another implementation. DirectComposition by itself is not a guarantee if it still moves the top-level HWND independently.

Physical scanout, UU delivery and subjective response remain unmeasured by this reader. Original shader-free local mismatch is still real, but neither callback counting nor this failed prototype closes all end-to-end causes.

## Restoration and source state

- Diagnostic8228 and reader stopped. Original installed C:/App/GlassUsage/glassusage.exe relaunched without probe flags,PID41912. Installation files not changed.
- Only widgetRefraction/widgetChromatic restored45.2/0.3 and verified twice. No stripe/0/0 state intentionally left running.
- Native prototype source remains in local dirty worktree for inspection, with inherited-state patch/binaries in before-frame-synced-drag. No source revert in this read-only analysis turn; no commit,push,release,or further rebuild.
