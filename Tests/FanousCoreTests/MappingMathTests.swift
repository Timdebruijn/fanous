// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousCore

struct MappingMathTests {
    @Test func blendCurveIsSymmetricAndSumsToOne() {
        for p in [1.0, 2.0, 3.0] {
            for i in 0...20 {
                let t = Double(i) / 20
                #expect(abs(BlendMath.curve(t, power: p) + BlendMath.curve(1 - t, power: p) - 1) < 1e-12)
            }
            #expect(BlendMath.curve(0, power: p) == 0 && BlendMath.curve(1, power: p) == 1 && BlendMath.curve(0.5, power: p) == 0.5)
        }
        // gamma compensation: factor^gamma follows the curve
        let edge = BlendEdge(overlap: 100, power: 2, gamma: 2.2)
        #expect(abs(pow(BlendMath.factor(0.3, edge: edge), 2.2) - BlendMath.curve(0.3, power: 2)) < 1e-12)
    }

    @Test func blendMapHasZonesLiftAndCornersMultiply() {
        var s = BlendSettings()
        s.left = BlendEdge(overlap: 4, power: 1, gamma: 1)
        s.top = BlendEdge(overlap: 2, power: 1, gamma: 1)
        s.lift = 0.1
        s.liftFeather = 0
        let map = BlendMath.map(s, width: 8, height: 4)
        // four floats per pixel: factor r, g, b, lift term
        #expect(map.count == 8 * 4 * 4)
        func at(_ x: Int, _ y: Int) -> (Float, Float) { (map[(y * 8 + x) * 4], map[(y * 8 + x) * 4 + 3]) }
        // both axes: the lift follows the coverage (M2.1), 3^(1/γ) lifts outside every zone, 1 in a zone, 0 in the corner
        #expect(at(7, 3).0 == 1 && abs(at(7, 3).1 - Float(0.1 * pow(3, 1 / 2.2))) < 1e-6, "outside every zone: full signal plus lift")
        #expect(abs(at(0, 3).0 - 0.125) < 1e-6 && at(0, 3).1 == 0.1, "left zone: linear ramp, one lift")
        #expect(abs(at(3, 3).0 - 0.875) < 1e-6)
        #expect(abs(at(0, 0).0 - 0.125 * 0.25) < 1e-6 && at(0, 0).1 == 0, "corner multiplies both axes, no lift")
        #expect(at(7, 0).1 == 0.1, "inside the top zone")
        #expect(BlendSettings().isIdentity)
    }

    /// OPEN-14: inside an overlap each channel takes its own gamma (a corner multiplies the two axes per channel);
    /// without gammaRGB the three factors are the single factor. Top runs its gammaRGB the other way round, so a corner
    /// that took one axis's channels from the wrong place fails.
    @Test func blendMapGammaRGBGivesEachChannelItsFactor() {
        var s = BlendSettings()
        s.left = BlendEdge(overlap: 10, gammaRGB: [1.8, 2.2, 2.6])
        s.top = BlendEdge(overlap: 4, gammaRGB: [2.6, 2.2, 1.8])
        s.bottom = BlendEdge(overlap: 4, gamma: 2.4)
        s.lift = 0.05
        let map = BlendMath.map(s, width: 20, height: 12)
        func rgb(_ x: Int, _ y: Int) -> [Float] { Array(map[(y * 20 + x) * 4..<(y * 20 + x) * 4 + 3]) }
        func lift(_ x: Int, _ y: Int) -> Float { map[(y * 20 + x) * 4 + 3] }
        let inside = rgb(3, 6)  // left zone at t = 0.35, between the top and bottom zones
        #expect(Set(inside).count == 3, "three different factors: \(inside)")
        for (i, gamma) in [1.8, 2.2, 2.6].enumerated() {
            let single = BlendMath.factor(0.35, edge: BlendEdge(overlap: 10, gamma: gamma))
            #expect(inside[i] == Float(single), "channel \(i): \(inside[i]), expected \(single)")
            #expect(BlendMath.factor(0.35, edge: s.left, channel: i) == single)
            #expect(rgb(3, 0)[i] == Float(single * BlendMath.factor(0.125, edge: s.top, channel: i)), "corner, channel \(i)")
        }
        #expect(lift(3, 6) == 0.05, "one zone of a grid: one lift (M2.1)")
        #expect(rgb(15, 6) == [1, 1, 1] && abs(lift(15, 6) - Float(0.05 * pow(3, 1 / 2.2))) < 1e-6, "outside every zone: full signal plus lift")
        // gammaRGB nil: R = G = B = the single factor
        #expect(rgb(15, 10) == Array(repeating: Float(BlendMath.factor(0.375, edge: s.bottom)), count: 3), "\(rgb(15, 10))")
    }

    /// M2.1 (DESIGN §9.10 item 1): with overlaps on both axes the lift follows the coverage n = (1 + zx)(1 + zy):
    /// lift × ((4 − n) / n)^(1/γ), so 3^(1/γ) lifts where one projector lights the pixel, 1 in a seam, 0 where four
    /// overlap, continuous over the lift feather. An output blended on one axis keeps lift × (1 − in a zone).
    @Test func blendMapLiftFollowsTheCoverageOnBothAxes() {
        let lift = 0.05, single = Float(lift * pow(3, 1 / 2.2))
        for feather in [0.0, 4] {
            var s = BlendSettings()
            s.left = BlendEdge(overlap: 4)
            s.top = BlendEdge(overlap: 2)
            s.lift = lift
            s.liftFeather = feather
            let map = BlendMath.map(s, width: 16, height: 12)
            func at(_ x: Int, _ y: Int) -> Float { map[(y * 16 + x) * 4 + 3] }
            #expect(abs(at(15, 11) - single) < 1e-6, "n = 1, feather \(feather): \(at(15, 11))")
            #expect(at(1, 11) == Float(lift) && at(15, 0) == Float(lift), "n = 2, feather \(feather): \(at(1, 11)) \(at(15, 0))")
            #expect(at(1, 0) == 0, "n = 4, feather \(feather): \(at(1, 0))")
            guard feather > 0 else { continue }
            // the feather beyond the left zone (columns 4…7): rising from the seam's lift to the single lift
            let band = (3...8).map { at($0, 11) }
            #expect(band.first == Float(lift) && abs(band.last! - single) < 1e-6 && zip(band, band.dropFirst()).allSatisfy { $0 < $1 }, "\(band)")
            let n = 1 + (1 - 1.5 / 4)  // column 5: 1.5 px into the feather
            #expect(abs(at(5, 11) - Float(lift * pow((4 - n) / n, 1 / 2.2))) < 1e-6, "\(at(5, 11))")
        }
        // one axis (left and right): the lift as before, also in the feather
        var s = BlendSettings()
        s.left = BlendEdge(overlap: 4)
        s.right = BlendEdge(overlap: 3)
        s.lift = lift
        s.liftFeather = 4
        let map = BlendMath.map(s, width: 16, height: 2)
        for col in 0..<16 {
            let c = Double(col) + 0.5, d = 16 - c
            let inZone = max(c < 4 ? 1 : 1 - min(1, (c - 4) / 4), d < 3 ? 1 : 1 - min(1, (d - 3) / 4))
            #expect(map[col * 4 + 3] == Float(lift * (1 - inZone)) && map[(16 + col) * 4 + 3] == map[col * 4 + 3], "column \(col): \(map[col * 4 + 3])")
        }
    }

    @Test func homographyMapsTheCornersAndKeepsTheIdentity() {
        let identity = WarpMath.homography(to: WarpSettings().cornerPin)
        #expect(identity == [1, 0, 0, 0, 1, 0, 0, 0, 1])
        let quad = [MapPoint(0.1, 0.05), MapPoint(0.9, 0.1), MapPoint(0.95, 0.9), MapPoint(0.05, 0.85)]
        let h = WarpMath.homography(to: quad)
        for (i, (u, v)) in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].enumerated() {
            let p = WarpMath.apply(h, u, v)
            #expect(abs(p.x - quad[i].x) < 1e-9 && abs(p.y - quad[i].y) < 1e-9, "corner \(i)")
        }
        // a perspective quad maps the centre away from the bilinear centre
        let trapezoid = [MapPoint(0.25, 0), MapPoint(0.75, 0), MapPoint(1, 1), MapPoint(0, 1)]
        let centre = WarpMath.apply(WarpMath.homography(to: trapezoid), 0.5, 0.5)
        #expect(abs(centre.x - 0.5) < 1e-9 && abs(centre.y - 1.0 / 3) < 1e-9, "the centre lands where the diagonals cross")
    }

    /// Keystone (DESIGN.md §9.10 item 2): raw values → moved corners → the unit square's homography onto them; centred is
    /// the identity; a crossed or concave quad, or a degenerate one, is refused.
    @Test func keystoneMovesTheCornersAndRefusesQuadsThatAreNotConvex() throws {
        func raw(_ offsets: [Double]) -> [UInt16] { zip(ChannelMap.keystone, offsets).map { $0.raw(fromPhysical: $1) } }
        #expect(WarpMath.keystone(raw: ChannelMap.defaults(for: .keystone)) == [1, 0, 0, 0, 1, 0, 0, 0, 1])
        // TL 10 % right, TR 5 % down, BR 20 % left and 10 % up, BL untouched
        let m = try #require(WarpMath.keystone(raw: raw([10, 0, 0, 5, -20, -10, 0, 0])))
        let expected = [MapPoint(0.1, 0), MapPoint(1, 0.05), MapPoint(0.8, 0.9), MapPoint(0, 1)]
        for (i, (u, v)) in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].enumerated() {
            let p = WarpMath.apply(m, u, v)
            #expect(abs(p.x - expected[i].x) < 1e-4 && abs(p.y - expected[i].y) < 1e-4, "corner \(i): \(p)")
        }
        #expect(WarpMath.keystone(raw: raw([50, 50, 0, -20, 0, 0, 0, 0])) == nil, "TL pulled in past the TR–BL diagonal: concave")
        #expect(WarpMath.keystone(raw: raw([0, 0, 0, 0, -50, -50, 0, 50])) == nil, "BR pulled in past the TR–BL diagonal: concave")
        #expect(WarpMath.keystone(raw: raw([50, 50, 0, 0, 0, 0, 0, 0])) == nil, "TL on the diagonal: degenerate")
        #expect(WarpMath.keystone(raw: raw([50, 0, -50, 0, 0, 0, 0, 0])) == nil, "TL onto TR: degenerate")
        #expect(WarpMath.keystone(raw: [0x8000]) == nil, "not a Keystone fixture's values")
        // ±50 % cannot cross two edges (opposite edges only touch at 50 %); the guard refuses a bow-tie all the same
        #expect(WarpMath.keystone(to: [MapPoint(0, 0), MapPoint(1, 0), MapPoint(0, 1), MapPoint(1, 1)]) == nil, "crossed")
        #expect(WarpMath.keystone(to: [MapPoint(0.2, 0.1), MapPoint(0.9, 0), MapPoint(1, 1), MapPoint(0, 0.8)]) != nil)
        // the extremes that stay convex: every corner 50 % outwards, or the whole picture 50 % to the left
        #expect(WarpMath.keystone(raw: raw([-50, -50, 50, -50, 50, 50, -50, 50])) != nil)
        #expect(WarpMath.keystone(raw: raw([-50, 0, -50, 0, -50, 0, -50, 0])) != nil)
    }

    @Test func meshWarpIdentityAndSmoothness() {
        var warp = WarpSettings()
        warp.mesh = .identity(cols: 5, rows: 4)
        #expect(warp.isIdentity)
        let field = WarpMath.field(warp, cols: 9, rows: 5)
        for r in 0..<5 {
            for c in 0..<9 {
                #expect(abs(Double(field[(r * 9 + c) * 2]) - Double(c) / 8) < 1e-6)
                #expect(abs(Double(field[(r * 9 + c) * 2 + 1]) - Double(r) / 4) < 1e-6)
            }
        }
        // move the centre control point: the surface passes through it and stays put at the corners
        var mesh = MeshWarp.identity(cols: 3, rows: 3)
        mesh.points[4] = MapPoint(0.6, 0.4)
        let p = WarpMath.meshPoint(mesh, 0.5, 0.5)
        #expect(abs(p.x - 0.6) < 1e-9 && abs(p.y - 0.4) < 1e-9)
        #expect(WarpMath.meshPoint(mesh, 0, 0) == MapPoint(0, 0) && WarpMath.meshPoint(mesh, 1, 1) == MapPoint(1, 1))
        #expect(!mesh.isIdentity)
    }

    @Test func warpFieldOf33x33CompilesQuickly() {
        var warp = WarpSettings()
        warp.mesh = .identity(cols: 33, rows: 33)
        warp.mesh!.points[33 * 16 + 16] = MapPoint(0.52, 0.49)
        let field = WarpMath.field(warp, cols: 480, rows: 270)  // 1080p / 4
        // best of five: in a parallel test run the other suites share the CPU with this measurement
        var ms = Double.infinity
        for _ in 0..<5 {
            let start = Date()
            _ = WarpMath.field(warp, cols: 480, rows: 270)
            ms = min(ms, Date().timeIntervalSince(start) * 1000)
        }
        #expect(field.count == 480 * 270 * 2)
        // the 100 ms budget is measured on the reference Mac; a hosted CI VM (CI=true) is about 2× slower in debug, so there
        // the bound only catches a gross regression
        let budget = ProcessInfo.processInfo.environment["CI"] != nil ? 1000.0 : 100.0
        #expect(ms < budget, "33×33 warp compiled in \(ms) ms")
    }

    @Test func maskRasterCoversTheInsideAndFeathersTheEdge() {
        let square = MaskSettings(path: [MapPoint(0.25, 0.25), MapPoint(0.75, 0.25), MapPoint(0.75, 0.75), MapPoint(0.25, 0.75)])
        let hard = MaskMath.raster(square, width: 40, height: 40).bytes
        #expect(hard[20 * 40 + 20] == 255 && hard[0] == 0 && hard[5 * 40 + 20] == 0)
        #expect(hard.filter { $0 == 255 }.count == 400, "20×20 pixels inside")
        var soft = square
        soft.feather = 8
        let s = MaskMath.raster(soft, width: 40, height: 40).bytes
        let coarse = MaskMath.raster(soft, width: 40, height: 40, step: 4)
        #expect(coarse.width == 10 && coarse.height == 10 && coarse.bytes[5 * 10 + 5] == 255 && coarse.bytes[0] == 0)
        #expect(s[20 * 40 + 20] == 255)
        // across the left edge (x = 10): values rise monotonically over the 8 px band
        let row = (6..<14).map { s[20 * 40 + $0] }
        #expect(row == row.sorted() && row.first! < 64 && row.last! > 191)
        #expect(MaskMath.signedDistance(0.5, 0.5, polygon: [(0, 0), (1, 0), (1, 1), (0, 1)]) == 0.5)
        #expect(MaskMath.signedDistance(2, 0.5, polygon: [(0, 0), (1, 0), (1, 1), (0, 1)]) == -1)
    }

    @Test func sliceMeshTessellatesTheDestinationQuad() {
        var slice = SliceConfig(id: 1)
        slice.source = MapRect(x: 0.5, y: 0, w: 0.5, h: 1)
        slice.dest = [MapPoint(0, 0), MapPoint(0.5, 0), MapPoint(0.5, 1), MapPoint(0, 1)]
        let (vertices, indices) = SliceMesh.build(slice, subdivisions: 2)
        #expect(vertices.count == 9 && indices.count == 24)
        #expect(vertices[0] == SliceMesh.Vertex(x: 0, y: 0, u: 0.5, v: 0))
        #expect(vertices[8] == SliceMesh.Vertex(x: 0.5, y: 1, u: 1, v: 1))
        #expect(vertices[4] == SliceMesh.Vertex(x: 0.25, y: 0.5, u: 0.75, v: 0.5))
        #expect(indices.allSatisfy { $0 < 9 })
    }

    @Test func outputConfigRoundTripsAsJSON() throws {
        var output = OutputConfig(id: 2, name: "Left projector")
        output.display = DisplayIdentity(uuid: "ABC", name: "Epson")
        output.region = PixelRect(x: 0, y: 0, w: 1920, h: 1200)
        output.blend.right = BlendEdge(overlap: 240)
        output.warp.mesh = .identity(cols: 3, rows: 3)
        output.slices[0].mask = MaskSettings(path: [MapPoint(0, 0), MapPoint(1, 0), MapPoint(0.5, 1)], feather: 12)
        output.color = OutputColor(gain: [0.9, 1, 1.05], black: 0.02)
        let data = try JSONEncoder().encode(output)
        let back = try JSONDecoder().decode(OutputConfig.self, from: data)
        #expect(back == output)
        #expect(OutputConfig(id: 1).slices.count == 1 && OutputConfig(id: 1).name == "Output 1")
    }

    /// Projects saved before per-output colour (M1.7) load unchanged, with gain 1 and black 0.
    @Test func anOutputWithoutColourDecodesWithTheDefault() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OutputConfig(id: 3))) as! [String: Any]
        json["color"] = nil
        let old = try JSONDecoder().decode(OutputConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old == OutputConfig(id: 3))
        #expect(old.color.gain == [1, 1, 1] && old.color.black == 0)
        // the other fields stay required, as before
        json["slices"] = nil
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(OutputConfig.self, from: JSONSerialization.data(withJSONObject: json)) }
    }
}
