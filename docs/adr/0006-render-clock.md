# ADR-0006: CAMetalDisplayLink per display, compositor on the master display

Status: Accepted · 2026-10-22

## Context
The brief fixes `CAMetalDisplayLink` as the clock. Displays may have
different refresh rates (allowed, with a warning). Blocking on another
display's `nextDrawable()` from one thread would couple all outputs to the
slowest display.

## Decision
- Each display with outputs has its own thread, RunLoop and
  `CAMetalDisplayLink` (`preferredFrameLatency = 1`).
- The project's "clock master" display (default: first output's display)
  drives the **compositor**: layer clocks advance and canvases render on its
  ticks. Canvas textures are triple-buffered; completion is signalled via the
  command buffer's completion handler.
- Other display threads run only the output pass from the latest completed
  canvas on their own ticks (repeat/skip on mismatched rates).
- With no displays, a `mach_wait_until` loop at the canvas rate drives the
  compositor (previews, benchmark).

## Consequences
+ One display's stall never blocks another; the master display defines the
  content cadence, which is what projection blends need.
− Secondary displays at a different rate show cadence artifacts; documented,
  warned, and measured.

## Amendment 2026-10-23 (Phase 2): CAMetalDisplayLink stalls on macOS 27.0.1

Measured on the M1 Pro reference machine (macOS 27.0.1, build 26A434):
`CAMetalDisplayLink` delivers exactly three updates and then none, as soon as
the delegate presents the update's drawable (`commandBuffer.present(drawable)`).
This happened in every variant tried: delegate on a background run loop or on
main, `preferredFrameLatency` 1 or 2, fixed or default frame-rate range,
`maximumDrawableCount` 2 or 3, layer-hosting or layer-backed view, borderless
or titled window, shielding or normal level, accessory or regular app, bare
executable, embedded Info.plist, and a real `.app` launched by LaunchServices.
A delegate that does not present keeps receiving ~60 updates/s, and the classic
`CAMetalLayer.nextDrawable()` path presents 156 frames in 2.5 s in the same
window, so the window, the layer and presentation itself are fine. GPU
completion handlers and `addPresentedHandler` fire for the three frames.

Decision: the output driver is a dedicated thread paced by the engine's mach
clock at the canvas rate that takes `nextDrawable()` from a `displaySyncEnabled`
layer with `maximumDrawableCount = 2` (one frame of latency), and presents
through the command buffer. Missed frames show up as target-time gaps, exactly
as with the display link. `DisplayLinkDriver` stays in the tree behind
`SceneConfig.useDisplayLink` so the behaviour can be re-tested on later macOS
releases; the brief's "no CVDisplayLink" rule is still honoured. The two
drivers share the compositor, so switching back is a one-line change.
Follow-up: file Feedback with Apple with the standalone reproduction
(`scratchpad/linktest5.swift` saved as `docs/benchmarks/cametaldisplaylink-repro.swift`).

Re-test 2026-10-23 (Phase 3): a macOS 27 control app by a third party
(`rrva/metal-display-link-pacing`, M2 Max, 27 beta) runs the link at full
rate from a `.regular`, activated app with a key, titled window. The
reproduction was extended with exactly those variants (`.regular` policy,
`activate`, `makeKeyAndOrderFront`, titled window, occlusion check): still
three updates in every combination on 27.0.1 / M1 Pro. Window visibility is
therefore ruled out; the drawable-loop driver stays. Apple's own guidance
(WWDC26, game-porting-toolkit skills, 2026-06) still names CAMetalDisplayLink
the intended render loop, and no replacement API exists in the macOS 26/27
SDKs, so the switch remains worth re-testing per macOS release.
