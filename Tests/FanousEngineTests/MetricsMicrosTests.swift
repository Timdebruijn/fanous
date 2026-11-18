// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import FanousEngine

/// The seconds-to-microseconds conversion of the frame metrics (B263): a command buffer that never started reports GPU
/// start 0, so end − start is the host uptime; past 4295 s the plain `UInt32` conversion trapped the render thread.
struct MetricsMicrosTests {
    @Test func clampsEveryDifferenceIntoUInt32() {
        #expect(Compositor.micros(5000 - 0) == 4_000_000_000)  // GPU start 0, end 5000 s of uptime
        #expect(Compositor.micros(.infinity) == 4_000_000_000)
        #expect(Compositor.micros(-0.002) == 0)
        #expect(Compositor.micros(-.infinity) == 0)
        #expect(Compositor.micros(.nan) == 4_000_000_000)  // min(4e9, nan) keeps 4e9: no trap, the ceiling
        #expect(Compositor.micros(0.0042) == 4200)
    }
}
