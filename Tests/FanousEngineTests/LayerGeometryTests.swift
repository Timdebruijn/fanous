// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Testing

@testable import FanousEngine

struct LayerGeometryTests {
    /// B19: an anamorphic movie's quad is as wide as its pixels are shown, not as they are coded. 320×176 at 4:3 pixels
    /// is 426.67×176 on screen: wider than a 16:9 canvas, so Fit makes it canvas-wide and 0.733 half-heights tall
    /// (square pixels would give 0.978); Native draws it 426.67 canvas pixels wide.
    @Test func pixelAspectWidensTheQuad() {
        var p = LayerParameters()
        p.fitMode = .fit
        let square = Compositor.geometry(for: p, mediaWidth: 320, mediaHeight: 176, canvasWidth: 1920, canvasHeight: 1080).1
        let wide = Compositor.geometry(for: p, mediaWidth: 320, mediaHeight: 176, pixelAspect: 4.0 / 3, canvasWidth: 1920, canvasHeight: 1080).1
        #expect(abs(square.w - 0.978) < 0.001 && abs(square.z - 1.778) < 0.001, "\(square)")
        #expect(abs(wide.w - 0.733) < 0.001 && abs(wide.z - 1.778) < 0.001, "\(wide)")
        p.fitMode = .native
        let native = Compositor.geometry(for: p, mediaWidth: 320, mediaHeight: 176, pixelAspect: 4.0 / 3, canvasWidth: 1920, canvasHeight: 1080).1
        #expect(abs(native.z - 426.67 / 1080) < 0.001 && abs(native.w - 176.0 / 1080) < 0.001, "\(native)")
    }
}
