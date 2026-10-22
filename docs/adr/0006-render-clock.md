# ADR-0006: CAMetalDisplayLink per display, compositor on the master display

Status: Proposed · 2026-10-22

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
