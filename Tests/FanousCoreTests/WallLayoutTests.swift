// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousCore

/// Projector walls (DESIGN.md §9.9). The expected numbers are worked out by hand from
/// `p = 1 / (n − (n − 1) · overlap)`, `x = rect.x + rect.w · c · p · (1 − overlap)`, `w = rect.w · p`.
struct WallLayoutTests {
    /// Outputs 1…n with a 1920 × 1080 region (the region decides the pixel size).
    static func outputs(_ n: Int) -> [OutputConfig] {
        (1...n).map {
            var o = OutputConfig(id: $0)
            o.region = PixelRect(x: 0, y: 0, w: 1920, h: 1080)
            return o
        }
    }

    static func wall(cols: Int, rows: Int, overlap: WallOverlap, rect: MapRect = .full) -> WallConfig {
        var wall = WallConfig(id: 1, name: "Wall 1", cols: cols, rows: rows, outputs: Array(1...(cols * rows)), overlap: overlap)
        wall.rect = rect
        wall.seams = WallLayout.seams(cols: cols, rows: rows, outputs: wall.outputs)
        return wall
    }

    static func source(_ outputs: [OutputConfig], _ id: Int) -> MapRect { outputs.first { $0.id == id }!.slices[0].source }
    static func blend(_ outputs: [OutputConfig], _ id: Int) -> BlendSettings { outputs.first { $0.id == id }!.blend }

    static func near(_ a: MapRect, _ b: MapRect) -> Bool { abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 && abs(a.w - b.w) < 1e-9 && abs(a.h - b.h) < 1e-9 }
    static func overlaps(_ b: BlendSettings) -> [Double] { [b.left.overlap, b.right.overlap, b.top.overlap, b.bottom.overlap] }

    @Test func shareIsOneProjectorsPartOfTheWall() {
        #expect(abs(WallLayout.share(2, overlap: 0.2) - 1 / 1.8) < 1e-12)
        #expect(WallLayout.share(3, overlap: 0.25) == 0.4)
        #expect(WallLayout.share(1, overlap: 0.3) == 1, "one projector along an axis covers it all")
        #expect(WallLayout.share(4, overlap: 0) == 0.25)
    }

    /// 1 row × 2 columns, 20 % overlap: p = 1/1.8 = 0.5556; the second starts at p · 0.8 = 0.4444. Inner edges 0.2 × 1920 = 384 px.
    @Test func twoSideBySide() throws {
        var outputs = Self.outputs(2)
        try WallLayout.apply(Self.wall(cols: 2, rows: 1, overlap: WallOverlap(x: 0.2, y: 0.2)), to: &outputs, displayModes: [:])
        #expect(Self.near(Self.source(outputs, 1), MapRect(x: 0, y: 0, w: 0.5555555556, h: 1)))
        #expect(Self.near(Self.source(outputs, 2), MapRect(x: 0.4444444444, y: 0, w: 0.5555555556, h: 1)))
        #expect(Self.overlaps(Self.blend(outputs, 1)) == [0, 384, 0, 0], "left, right, top, bottom")
        #expect(Self.overlaps(Self.blend(outputs, 2)) == [384, 0, 0, 0])
        #expect(outputs.allSatisfy { $0.slices[0].canvas == 1 })
    }

    /// 3 in a row, 25 %: p = 1/2.5 = 0.4; starts 0, 0.4 · 0.75 = 0.3, 0.6. The middle one blends on both sides (480 px).
    /// The same as 3 rows × 1 column on the vertical axis (0.25 × 1080 = 270 px).
    @Test func threeInARowAndThreeInAColumn() throws {
        var outputs = Self.outputs(3)
        try WallLayout.apply(Self.wall(cols: 3, rows: 1, overlap: WallOverlap(x: 0.25, y: 0)), to: &outputs, displayModes: [:])
        #expect(Self.near(Self.source(outputs, 1), MapRect(x: 0, y: 0, w: 0.4, h: 1)))
        #expect(Self.near(Self.source(outputs, 2), MapRect(x: 0.3, y: 0, w: 0.4, h: 1)))
        #expect(Self.near(Self.source(outputs, 3), MapRect(x: 0.6, y: 0, w: 0.4, h: 1)))
        #expect(Self.overlaps(Self.blend(outputs, 1)) == [0, 480, 0, 0])
        #expect(Self.overlaps(Self.blend(outputs, 2)) == [480, 480, 0, 0])
        #expect(Self.overlaps(Self.blend(outputs, 3)) == [480, 0, 0, 0])

        outputs = Self.outputs(3)
        try WallLayout.apply(Self.wall(cols: 1, rows: 3, overlap: WallOverlap(x: 0, y: 0.25)), to: &outputs, displayModes: [:])
        #expect(Self.near(Self.source(outputs, 2), MapRect(x: 0, y: 0.3, w: 1, h: 0.4)))
        #expect(Self.near(Self.source(outputs, 3), MapRect(x: 0, y: 0.6, w: 1, h: 0.4)))
        #expect(Self.overlaps(Self.blend(outputs, 1)) == [0, 0, 0, 270])
        #expect(Self.overlaps(Self.blend(outputs, 2)) == [0, 0, 270, 270])
    }

    /// 2 × 2 on the rectangle (0.1, 0.2, 0.8 × 0.6), overlap 20 % / 10 %:
    /// px = 1/1.8, w = 0.8 · 5/9 = 0.4444, second column at 0.1 + 0.8 · 5/9 · 0.8 = 0.4556 (ends at 0.9);
    /// py = 1/1.9, h = 0.6/1.9 = 0.3158, second row at 0.2 + 0.6/1.9 · 0.9 = 0.4842 (ends at 0.8).
    @Test func twoByTwoOnARectangle() throws {
        var outputs = Self.outputs(4)
        let wall = Self.wall(cols: 2, rows: 2, overlap: WallOverlap(x: 0.2, y: 0.1), rect: MapRect(x: 0.1, y: 0.2, w: 0.8, h: 0.6))
        #expect(wall.seams.map { [$0.a, $0.b] } == [[1, 2], [1, 3], [2, 4], [3, 4]])
        try WallLayout.apply(wall, to: &outputs, displayModes: [:])
        #expect(Self.near(Self.source(outputs, 1), MapRect(x: 0.1, y: 0.2, w: 0.4444444444, h: 0.3157894737)))
        #expect(Self.near(Self.source(outputs, 2), MapRect(x: 0.4555555556, y: 0.2, w: 0.4444444444, h: 0.3157894737)))
        #expect(Self.near(Self.source(outputs, 3), MapRect(x: 0.1, y: 0.4842105263, w: 0.4444444444, h: 0.3157894737)))
        #expect(Self.near(Self.source(outputs, 4), MapRect(x: 0.4555555556, y: 0.4842105263, w: 0.4444444444, h: 0.3157894737)))
        // inner edges: 0.2 × 1920 = 384 horizontally, 0.1 × 1080 = 108 vertically; outer edges 0
        #expect(Self.overlaps(Self.blend(outputs, 1)) == [0, 384, 0, 108])
        #expect(Self.overlaps(Self.blend(outputs, 2)) == [384, 0, 0, 108])
        #expect(Self.overlaps(Self.blend(outputs, 3)) == [0, 384, 108, 0])
        #expect(Self.overlaps(Self.blend(outputs, 4)) == [384, 0, 108, 0])
    }

    @Test func seamValuesGoToBothFacingEdgesOnly() throws {
        var outputs = Self.outputs(2)
        outputs[0].blend.left = BlendEdge(overlap: 50, power: 5, gamma: 3)  // outer: the wall zeroes the overlap, keeps the tuning
        var wall = Self.wall(cols: 2, rows: 1, overlap: WallOverlap(x: 0.15, y: 0.15))
        wall.seams[0].power = 3
        wall.seams[0].gamma = 1.8
        wall.seams[0].gammaRGB = [2.0, 2.2, 2.4]
        try WallLayout.apply(wall, to: &outputs, displayModes: [:])
        for edge in [Self.blend(outputs, 1).right, Self.blend(outputs, 2).left] {
            #expect(edge.power == 3 && edge.gamma == 1.8 && edge.gammaRGB == [2.0, 2.2, 2.4])
        }
        #expect(Self.blend(outputs, 1).left == BlendEdge(overlap: 0, power: 5, gamma: 3))
        #expect(Self.blend(outputs, 2).right == BlendEdge())
    }

    @Test func manualFieldsAndOtherSlicesStayAsTheyAre() throws {
        var outputs = Self.outputs(2)
        let handMade = MapRect(x: 0.5, y: 0.1, w: 0.3, h: 0.3)
        outputs[1].slices[0].source = handMade
        var second = SliceConfig(id: 2)
        second.source = MapRect(x: 0.2, y: 0.2, w: 0.1, h: 0.1)
        second.canvas = 2
        outputs[0].slices.append(second)
        outputs[0].blend.right.overlap = 100
        var wall = Self.wall(cols: 2, rows: 1, overlap: WallOverlap(x: 0.2, y: 0))
        wall.manual = [WallManualField(output: 2, field: .source), WallManualField(output: 1, field: .overlapRight)]
        wall.seams[0].gamma = 2.0
        try WallLayout.apply(wall, to: &outputs, displayModes: [:])
        #expect(Self.source(outputs, 2) == handMade)
        #expect(outputs[0].slices[1] == second, "slice 2 is not the wall's")
        #expect(Self.blend(outputs, 1).right.overlap == 100, "manual overlap kept")
        #expect(Self.blend(outputs, 1).right.gamma == 2.0, "tuning still follows the seam")
        #expect(Self.blend(outputs, 2).left.overlap == 384)
        #expect(Self.near(Self.source(outputs, 1), MapRect(x: 0, y: 0, w: 0.5555555556, h: 1)))
    }

    @Test func pixelSizeIsRegionThenModeThenDisplay() throws {
        var output = OutputConfig(id: 1)
        output.display = DisplayIdentity(uuid: "U1", name: "Epson")
        let modes = ["U1": DisplayModeConfig(width: 3840, height: 2160, hz: 60)]
        #expect(WallLayout.pixelSize(of: output, displayModes: modes)! == (3840, 2160))
        #expect(WallLayout.pixelSize(of: output, displayModes: [:]) == nil, "display not connected")
        output.mode = DisplayModeConfig(width: 1920, height: 1200, hz: 60)
        #expect(WallLayout.pixelSize(of: output, displayModes: modes)! == (1920, 1200))
        output.region = PixelRect(x: 0, y: 0, w: 1280, h: 800)
        #expect(WallLayout.pixelSize(of: output, displayModes: modes)! == (1280, 800))
    }

    @Test func outputsOfDifferentOrUnknownSizeAreRefused() {
        var outputs = Self.outputs(2)
        outputs[1].region = nil
        outputs[1].mode = DisplayModeConfig(width: 1920, height: 1200, hz: 60)
        let wall = Self.wall(cols: 2, rows: 1, overlap: WallOverlap(x: 0.15, y: 0))
        #expect(throws: WallLayout.Refusal("the outputs of a wall need one pixel size: output 1 is 1920 × 1080, output 2 is 1920 × 1200")) {
            try WallLayout.apply(wall, to: &outputs, displayModes: [:])
        }
        outputs[1].mode = nil
        #expect(throws: WallLayout.Refusal("output 2 has no pixel size yet: bind it to a display, or set its region or display mode")) {
            try WallLayout.apply(wall, to: &outputs, displayModes: [:])
        }
        outputs[1].display = DisplayIdentity(uuid: "U2", name: "Epson")
        #expect(throws: Never.self) { try WallLayout.apply(wall, to: &outputs, displayModes: ["U2": DisplayModeConfig(width: 1920, height: 1080, hz: 60)]) }
        var one = [outputs[0]]
        #expect(throws: WallLayout.Refusal("no output 2")) { try WallLayout.apply(wall, to: &one, displayModes: [:]) }
    }

    /// cols · w − (cols − 1) · overlap · w: 2 × 1920 − 0.15 · 1920 = 3552; 2 × 1920 − 0.2 · 1920 = 3456 by 2 × 1080 − 0.1 · 1080 = 2052;
    /// 2 × 1920 − 0.123 · 1920 = 3603.84 → 3604 (even). 4 × 3840 at 15 % is 13632 × 2160, scaled by 8192/13632 to 8192 × 1298.
    @Test func makeCanvasSizeIsEvenAndWithinTheCanvasLimits() {
        let sides = 320...8192
        func size(_ cols: Int, _ rows: Int, _ x: Double, _ y: Double, _ w: Int, _ h: Int) -> (width: Int, height: Int) {
            WallLayout.canvasSize(Self.wall(cols: cols, rows: rows, overlap: WallOverlap(x: x, y: y)), output: (w, h), sides: sides)
        }
        #expect(size(2, 1, 0.15, 0.15, 1920, 1080) == (3552, 1080))
        #expect(size(2, 2, 0.2, 0.1, 1920, 1080) == (3456, 2052))
        #expect(size(2, 1, 0.123, 0, 1920, 1080) == (3604, 1080))
        #expect(size(4, 1, 0.15, 0, 3840, 2160) == (8192, 1298), "scaled down whole: the canvas keeps the wall's shape")
        #expect(size(2, 1, 0, 0, 200, 100) == (400, 320), "each side at least 320")
    }

    @Test func shapeChecks() {
        func refusal(_ cols: Int, _ rows: Int, _ outputs: [Int], _ x: Double = 0.15) -> String? {
            let wall = WallConfig(id: 1, name: "W", cols: cols, rows: rows, outputs: outputs, overlap: WallOverlap(x: x, y: 0.15))
            do {
                try WallLayout.check(wall)
                return nil
            } catch {
                return (error as? WallLayout.Refusal)?.message
            }
        }
        #expect(refusal(2, 1, [1, 2]) == nil)
        #expect(refusal(4, 4, Array(1...16)) == nil)
        #expect(refusal(1, 1, [1]) == "a wall has 1–4 columns and 1–4 rows, and at least two projectors")
        #expect(refusal(5, 1, Array(1...5)) != nil)
        #expect(refusal(2, 2, [1, 2, 3]) == "a 2 × 2 wall needs 4 outputs, row by row from the top left")
        #expect(refusal(2, 1, [1, 1]) == "each output can be in the wall once")
        #expect(refusal(2, 1, [1, 2], 0.6) == "overlap x and y must be 0–0.5 (a fraction of one projector)")
    }

    @Test func seamsOfAGridKeepTheValuesOfPairsThatStay() {
        let seams = WallLayout.seams(cols: 3, rows: 2, outputs: [1, 2, 3, 4, 5, 6])
        #expect(seams.map { [$0.a, $0.b] } == [[1, 2], [1, 4], [2, 3], [2, 5], [3, 6], [4, 5], [5, 6]])
        #expect(seams.allSatisfy { $0.power == 2 && $0.gamma == 2.2 && $0.gammaRGB == nil })
        var tuned = seams
        tuned[0].gamma = 1.9
        let regrown = WallLayout.seams(cols: 3, rows: 1, outputs: [1, 2, 7], keeping: tuned)
        #expect(regrown == [SeamConfig(a: 1, b: 2, gamma: 1.9), SeamConfig(a: 2, b: 7)])
    }

    @Test func handEditsBecomeManualOrFollowTheSeam() throws {
        var outputs = Self.outputs(3)
        var wall = Self.wall(cols: 3, rows: 1, overlap: WallOverlap(x: 0.2, y: 0))
        try WallLayout.apply(wall, to: &outputs, displayModes: [:])

        func edit(_ id: Int, _ change: (inout OutputConfig) -> Void) -> [WallManualField.Field] {
            let index = outputs.firstIndex { $0.id == id }!
            let old = outputs[index]
            change(&outputs[index])
            return WallLayout.follow(edit: outputs[index], was: old, wall: &wall, outputs: &outputs)
        }
        // tuning an inner edge moves the seam, and the neighbour's facing edge follows
        #expect(edit(2) { $0.blend.right.gamma = 1.7 } == [])
        #expect(wall.seams[1].gamma == 1.7 && Self.blend(outputs, 3).left.gamma == 1.7)
        #expect(edit(2) { $0.blend.left.gammaRGB = [2, 2.1, 2.3] } == [])
        #expect(Self.blend(outputs, 1).right.gammaRGB == [2, 2.1, 2.3] && wall.seams[0].gammaRGB == [2, 2.1, 2.3])
        // geometry: an inner overlap and slice 1's source become manual, once
        #expect(edit(2) { $0.blend.right.overlap = 300 } == [.overlapRight])
        #expect(edit(2) { $0.blend.right.overlap = 310 } == [])
        #expect(edit(3) { $0.slices[0].source.x = 0.61 } == [.source])
        #expect(edit(1) { $0.slices[0].canvas = 2 } == [.source])
        #expect(wall.manual == [WallManualField(output: 2, field: .overlapRight), WallManualField(output: 3, field: .source), WallManualField(output: 1, field: .source)])
        // outer edges and other slices are not the wall's
        #expect(edit(1) { $0.blend.left.overlap = 40 } == [])
        #expect(edit(1) { $0.blend.left.gamma = 3 } == [])
        #expect(wall.seams.map(\.gamma) == [2.2, 1.7])
        #expect(edit(1) { $0.slices.append(SliceConfig(id: 2)) } == [])
        // a re-compile keeps the manual fields
        try WallLayout.apply(wall, to: &outputs, displayModes: [:])
        #expect(Self.blend(outputs, 2).right.overlap == 310 && Self.blend(outputs, 3).left.overlap == 384)
        #expect(Self.source(outputs, 3).x == 0.61)
        #expect(Self.blend(outputs, 1).left.overlap == 0, "outer edges go back to 0")
    }

    @Test func oldProjectsDecodeWithoutTheNewFields() throws {
        let edge = try JSONDecoder().decode(BlendEdge.self, from: Data(#"{"overlap": 10, "power": 2, "gamma": 2.2}"#.utf8))
        #expect(edge.gammaRGB == nil)
        let encoded = String(decoding: try JSONEncoder().encode(BlendEdge()), as: UTF8.self)
        #expect(!encoded.contains("gammaRGB"), "a project without RGB gamma is written as before")
        var wall = Self.wall(cols: 2, rows: 2, overlap: WallOverlap(x: 0.15, y: 0.1))
        wall.manual = [WallManualField(output: 3, field: .overlapTop)]
        wall.seams[2].gammaRGB = [2, 2.2, 2.4]
        let json = try JSONEncoder().encode(wall)
        #expect(try JSONDecoder().decode(WallConfig.self, from: json) == wall)
        #expect(String(decoding: json, as: UTF8.self).contains(#""field":"overlap.top""#))
    }
}
