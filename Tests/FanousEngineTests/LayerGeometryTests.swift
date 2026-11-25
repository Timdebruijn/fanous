// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Testing
import simd

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

    /// A combined rotation turns about X first, then Y, then Z: Rz · Ry · Rx, after the projection of an unrotated layer
    /// (no position, scale 1). The reversed product fails.
    @Test func aCombinedRotationTurnsXThenYThenZ() {
        var p = LayerParameters()
        let flat = Compositor.geometry(for: p, mediaWidth: 1920, mediaHeight: 1080, canvasWidth: 1920, canvasHeight: 1080).0
        (p.rotationX, p.rotationY, p.rotationZ) = (0.3, -0.7, 1.1)
        let turned = Compositor.geometry(for: p, mediaWidth: 1920, mediaHeight: 1080, canvasWidth: 1920, canvasHeight: 1080).0
        let (cx, sx) = (cos(p.rotationX), sin(p.rotationX))
        let (cy, sy) = (cos(p.rotationY), sin(p.rotationY))
        let (cz, sz) = (cos(p.rotationZ), sin(p.rotationZ))
        let rx = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, cx, sx, 0), SIMD4(0, -sx, cx, 0), SIMD4(0, 0, 0, 1))
        let ry = simd_float4x4(SIMD4(cy, 0, -sy, 0), SIMD4(0, 1, 0, 0), SIMD4(sy, 0, cy, 0), SIMD4(0, 0, 0, 1))
        let rz = simd_float4x4(SIMD4(cz, sz, 0, 0), SIMD4(-sz, cz, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
        let expected = flat * rz * ry * rx
        let worst = (0..<4).flatMap { c in (0..<4).map { r in abs(turned[c][r] - expected[c][r]) } }.max() ?? .infinity
        #expect(worst < 1e-6, "\(turned) vs \(expected)")
    }
}
