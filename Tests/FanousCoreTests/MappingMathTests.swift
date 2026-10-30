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
        warp.mesh = mesh
        let moved = WarpMath.field(warp, cols: 3, rows: 3)
        #expect(abs(moved[8] - 0.6) < 1e-6 && abs(moved[9] - 0.4) < 1e-6)
        #expect(abs(moved[0]) < 1e-6 && abs(moved[1]) < 1e-6 && abs(moved[16] - 1) < 1e-6 && abs(moved[17] - 1) < 1e-6)
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

    /// DESIGN.md §9.10 item 5: masks round-trip with handles and an image; a point without handles is a plain point.
    @Test func masksRoundTripWithHandlesAndAnImage() throws {
        var slice = SliceConfig(id: 1)
        slice.masks = [
            MaskShape(feather: 4, path: [MaskPoint(0.1, 0.1, out: MapPoint(0.25, 0)), MaskPoint(0.9, 0.1, in: MapPoint(-0.25, 0)), MaskPoint(0.5, 0.9)]),
            MaskShape(mode: .subtract, image: MaskImage(folder: 3, file: 5)),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(slice), as: UTF8.self)
        #expect(
            json.contains(
                #""masks":[{"feather":4,"mode":"add","path":[{"out":{"x":0.25,"y":0},"x":0.1,"y":0.1},{"in":{"x":-0.25,"y":0},"x":0.9,"y":0.1},{"x":0.5,"y":0.9}]},{"feather":0,"image":{"file":5,"folder":3},"mode":"subtract"}]"#
            ), "\(json)")
        #expect(try JSONDecoder().decode(SliceConfig.self, from: Data(json.utf8)) == slice)
        #expect(slice.masks.allSatisfy { $0.problem == nil })
        #expect(try !String(decoding: encoder.encode(SliceConfig(id: 1)), as: UTF8.self).contains("masks"), "none: no key")
    }

    /// What `output.set` refuses and the compile leaves out: a non-finite feather (a negative one is none), a path of fewer
    /// than 3 points or with a non-finite number (handles included), neither or both of path and image, an image outside
    /// 1–255. A mask without a mode or feather decodes as an add mask without one.
    @Test func aMaskThatCannotBeDrawnSaysWhy() throws {
        let triangle = [MaskPoint(0, 0), MaskPoint(1, 0), MaskPoint(0, 1)]
        #expect(MaskShape(feather: -3, path: triangle).problem == nil)
        let bare = try JSONDecoder().decode(MaskShape.self, from: Data(#"{"path":[{"x":0,"y":0},{"x":1,"y":0},{"x":0,"y":1}]}"#.utf8))
        #expect(bare == MaskShape(mode: .add, feather: 0, path: triangle))
        let refused = [
            MaskShape(feather: .infinity, path: triangle), MaskShape(feather: .nan, path: triangle), MaskShape(path: Array(triangle.prefix(2))),
            MaskShape(path: triangle + [MaskPoint(.nan, 0)]), MaskShape(path: triangle + [MaskPoint(0, 0, out: MapPoint(0, .infinity))]), MaskShape(),
            MaskShape(path: triangle, image: MaskImage(folder: 1, file: 1)), MaskShape(image: MaskImage(folder: 0, file: 1)),
            MaskShape(image: MaskImage(folder: 1, file: 256)),
        ]
        for mask in refused { #expect(mask.problem != nil, "\(mask)") }
        #expect(MaskShape(feather: 0, path: triangle).problem == nil && MaskShape(image: MaskImage(folder: 255, file: 1)).problem == nil)
    }

    /// A point's handles make its segments cubic Béziers: four points with κ = 4/3 (√2 − 1) handles lie on a circle, and the
    /// flattened outline stays within a quarter pixel of the curve (the approximation itself is off by 0.03 %); a path
    /// without handles is its own points.
    @Test func handlesMakeCurvesAndTheOutlineFollowsThem() {
        let (c, r) = (0.5, 0.25), k = 4.0 / 3 * (2.0.squareRoot() - 1) * r
        let circle = [
            MaskPoint(c + r, c, in: MapPoint(0, -k), out: MapPoint(0, k)), MaskPoint(c, c + r, in: MapPoint(k, 0), out: MapPoint(-k, 0)),
            MaskPoint(c - r, c, in: MapPoint(0, k), out: MapPoint(0, -k)), MaskPoint(c, c - r, in: MapPoint(-k, 0), out: MapPoint(k, 0)),
        ]
        let edges = MaskMath.edges(circle)
        #expect(edges.count == 4 && edges.allSatisfy(\.curved))
        let mid = edges[0].at(0.5)
        #expect(abs(hypot(mid.x - c, mid.y - c) - r) < 0.0003 * r && mid.x > c && mid.y > c)
        let outline = MaskMath.outline(circle, width: 1000, height: 1000)
        #expect(outline.count > 40, "\(outline.count) points")
        #expect(outline.allSatisfy { abs(hypot($0.x - 500, $0.y - 500) - 250) < 0.25 + 0.0003 * 250 })
        // the chord between two outline points stays within a quarter pixel (and the approximation) of the circle
        for (i, p) in outline.enumerated() {
            let q = outline[(i + 1) % outline.count]
            #expect(hypot((p.x + q.x) / 2 - 500, (p.y + q.y) / 2 - 500) > 250 - 0.25 - 0.0003 * 250)
        }
        let square = [MaskPoint(0.25, 0.25), MaskPoint(0.75, 0.25), MaskPoint(0.75, 0.75), MaskPoint(0.25, 0.75)]
        #expect(MaskMath.outline(square, width: 40, height: 20).map { [$0.x, $0.y] } == [[10, 5], [30, 5], [30, 15], [10, 15]])
    }

    /// The feather (DESIGN.md §9.10 item 5): a linear ramp, 0.5 on the edge and 0 or 1 at ±feather/2 (here a right edge
    /// through the centres of column 20 and a left one through those of column 19, with an 8 px feather), and the banded
    /// pass gives exactly what the distance to every segment from every pixel gives, slanted edges and both directions
    /// included.
    @Test func theFeatherIsALinearRampWithinHalfItsWidth() {
        let (w, h) = (40, 9)
        // the 8 px ramp at `d` px inside the edge (typed apart: inline in #expect it times out the type checker on CI)
        func ramp(_ d: Int) -> UInt8 { UInt8((min(1, max(0, 0.5 + Double(d) / 8)) * 255).rounded()) }
        // only the edge at x = 20.5 is within 4 px of a pixel centre
        let right = MaskMath.feathered([(-10, -10), (20.5, -10), (20.5, 19), (-10, 19)], feather: 8, width: w, height: h)
        let row = Array(right[(4 * w)..<(5 * w)])
        #expect(row[20] == 128, "on the edge")
        #expect(row[16] == 255 && row[17] == 223 && row[23] == 32 && row[24] == 0, "±feather/2 and between")
        #expect(row == (0..<w).map { ramp(20 - $0) })
        // every row the same, but for rounding on the edge itself (0.5 ± 1e-16 is 127 or 128)
        #expect((0..<h).allSatisfy { y in (0..<w).allSatisfy { abs(Int(right[y * w + $0]) - Int(row[$0])) <= ($0 == 20 ? 1 : 0) } })
        // the fill counts a centre on a left edge inside: still 0.5 there
        let left = MaskMath.feathered([(19.5, -10), (60, -10), (60, 19), (19.5, 19)], feather: 8, width: w, height: h)
        #expect(Array(left[(4 * w)..<(5 * w)]) == (0..<w).map { ramp($0 - 19) })

        // a pentagon with slanted, nearly flat and nearly upright edges, and an arrow with two reflex corners, against the
        // brute force over every segment, in both directions
        let pentagon: [(x: Double, y: Double)] = [(5.2, 3.1), (60.7, 9.4), (61.3, 44.8), (30.1, 58.6), (2.9, 40.2)]
        let arrow: [(x: Double, y: Double)] = [(4.3, 20.2), (34.6, 20.7), (35.1, 4.4), (60.2, 31.9), (34.8, 59.3), (34.2, 42.1), (4.9, 41.6)]
        let (n, feather) = (64, 6.5)
        for polygon in [pentagon, arrow] {
            func inside(_ x: Double, _ y: Double) -> Bool {
                var odd = false
                for i in polygon.indices {
                    let (a, b) = (polygon[i], polygon[(i + 1) % polygon.count])
                    if (a.y > y) != (b.y > y), x < a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x) { odd.toggle() }
                }
                return odd
            }
            var brute = [UInt8](repeating: 0, count: n * n)
            for i in brute.indices {
                let (x, y) = (Double(i % n) + 0.5, Double(i / n) + 0.5)
                var d = Double.infinity
                for j in polygon.indices {
                    let (a, b) = (polygon[j], polygon[(j + 1) % polygon.count])
                    let t = min(1, max(0, ((x - a.x) * (b.x - a.x) + (y - a.y) * (b.y - a.y)) / (pow(b.x - a.x, 2) + pow(b.y - a.y, 2))))
                    d = min(d, hypot(a.x + t * (b.x - a.x) - x, a.y + t * (b.y - a.y) - y))
                }
                brute[i] = UInt8((min(1, max(0, 0.5 + (inside(x, y) ? d : -d) / feather)) * 255).rounded())
            }
            for outline in [polygon, polygon.reversed()] {
                #expect(MaskMath.fill(outline, width: n, height: n).map { $0 != 0 } == brute.indices.map { inside(Double($0 % n) + 0.5, Double($0 / n) + 0.5) })
                let banded = MaskMath.feathered(outline, feather: feather, width: n, height: n)
                #expect(banded == brute, "\(polygon.count) corners: \(zip(banded, brute).filter { $0 != $1 }.count) pixels differ")
            }
        }
    }

    /// Where a path crosses or overlaps itself (the nonzero rule fills it) its segments inside the filled region make no
    /// ramp: a pentagram drawn in one stroke, a freehand loop that ends inside itself and a bow-tie through one point darken
    /// no sample farther than feather/2 from the filled region's edge (found on a grid 4 × finer), and inside the ramp
    /// follows the distance to that edge, also at the corners where the path crosses itself.
    @Test func aSelfCrossingPathFeathersOnlyAtTheFilledRegionsEdge() {
        func samples(_ outline: [(x: Double, y: Double)], size n: Int, feather: Double) -> (seams: Int, ramp: Int, off: Int) {
            let raster = MaskMath.feathered(outline, feather: feather, width: n, height: n)
            let (k, fine) = (4, n * 4)
            let finer = MaskMath.fill(outline, width: fine, height: fine, cell: (0.25, 0.25))
            // per sample, the distance to the edge within feather/2 (and a fine cell): to the midpoints between a fine
            // inside sample and its outside neighbour
            let reach = feather / 2 + 1 / Double(k)
            var distance = [Double](repeating: .infinity, count: n * n)
            for fy in 0..<fine {
                for fx in 0..<fine where finer[fy * fine + fx] != 0 {
                    for (x, y) in [(fx - 1, fy), (fx + 1, fy), (fx, fy - 1), (fx, fy + 1)] where x < 0 || y < 0 || x >= fine || y >= fine || finer[y * fine + x] == 0 {
                        let (cx, cy) = ((Double(fx + x) / 2 + 0.5) / Double(k), (Double(fy + y) / 2 + 0.5) / Double(k))
                        for sy in max(0, Int(cy - reach))...min(n - 1, Int(cy + reach)) {
                            for sx in max(0, Int(cx - reach))...min(n - 1, Int(cx + reach)) {
                                distance[sy * n + sx] = min(distance[sy * n + sx], hypot(Double(sx) + 0.5 - cx, Double(sy) + 0.5 - cy))
                            }
                        }
                    }
                }
            }
            let winding = MaskMath.fill(outline, width: n, height: n)
            var (seams, ramp, off) = (0, 0, 0)
            for i in raster.indices where winding[i] != 0 {
                if raster[i] < 255 { if distance[i] <= reach { ramp += 1 } else { seams += 1 } }
                // within a fine cell of the true distance
                if distance[i] < feather / 2 - 1, abs(Double(raster[i]) - (0.5 + distance[i] / feather) * 255) > 255 / (Double(k) * feather) + 1 { off += 1 }
            }
            return (seams, ramp, off)
        }
        let star = (0..<5).map { i -> (x: Double, y: Double) in
            let a = -Double.pi / 2 + Double(i * 2) * 2 * .pi / 5
            return (100 + 90 * cos(a), 100 + 90 * sin(a))
        }
        // one turn of a circle, then 30° more spiralling inward to 0.85 r: the finger lifts inside, and the path closes
        let loop = (0..<240).map { i -> (x: Double, y: Double) in
            let a = Double(i) / 240 * 2 * .pi
            return (100 + 80 * cos(a), 100 + 80 * sin(a))
        } + (0...20).map { i -> (x: Double, y: Double) in
            let a = 2 * .pi + Double(i) / 20 * (.pi / 6), r = 80 * (1 - 0.15 * Double(i) / 20)
            return (100 + r * cos(a), 100 + r * sin(a))
        }
        // two triangles drawn in one stroke that meet at one point: the path passes it twice and touches itself there
        // without crossing
        let bowtie: [(x: Double, y: Double)] = [(100, 100), (20, 40), (20, 160), (100, 100), (180, 170), (180, 30)]
        for (name, outline, feather) in [("pentagram", star, 8.0), ("loop", loop, 12.0), ("bow-tie", bowtie, 8.0)] {
            let (seams, ramp, off) = samples(outline, size: 200, feather: feather)
            #expect(seams == 0 && ramp > 0 && off == 0, "\(name): \(seams) samples darkened away from the edge, \(ramp) on the ramp, \(off) off it")
        }
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
        output.slices[0].masks = [
            MaskShape(feather: 12, path: [MaskPoint(0, 0), MaskPoint(1, 0, in: MapPoint(0, -0.1)), MaskPoint(0.5, 1)]),
            MaskShape(mode: .subtract, image: MaskImage(folder: 2, file: 9)),
        ]
        output.color = OutputColor(gain: [0.9, 1, 1.05], black: 0.02)
        let data = try JSONEncoder().encode(output)
        let back = try JSONDecoder().decode(OutputConfig.self, from: data)
        #expect(back == output)
        #expect(OutputConfig(id: 1).slices.count == 1 && OutputConfig(id: 1).name == "Output 1")
    }

    /// DESIGN.md §9.10 item 3: an output without presets encodes byte for byte as before M2.4 (the literal is the
    /// synthesized encoding of that release, for a slice without a mask: masks v2 changed a masked one); presets
    /// round-trip, and a project without the key loads with none.
    @Test func presetsEncodeOnlyWhenThereAreAny() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var o = OutputConfig(id: 2, name: "Left")
        o.display = DisplayIdentity(uuid: "U", name: "Epson")
        o.warp.mesh = .identity(cols: 2, rows: 2)
        let before = #"{"blend":{"bottom":{"gamma":2.2,"overlap":0,"power":2},"left":{"gamma":2.2,"overlap":0,"power":2},"lift":0,"liftFeather":0,"right":{"gamma":2.2,"overlap":0,"power":2},"top":{"gamma":2.2,"overlap":0,"power":2}},"color":{"black":0,"gain":[1,1,1]},"display":{"name":"Epson","uuid":"U"},"id":2,"intensity":1,"name":"Left","slices":[{"canvas":1,"dest":[{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1},{"x":0,"y":1}],"id":1,"opacity":1,"source":{"h":1,"w":1,"x":0,"y":0}}],"testPattern":0,"warp":{"cornerPin":[{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1},{"x":0,"y":1}],"mesh":{"cols":2,"points":[{"x":0,"y":0},{"x":1,"y":0},{"x":0,"y":1},{"x":1,"y":1}],"rows":2}}}"#
        #expect(String(decoding: try encoder.encode(o), as: UTF8.self) == before)
        #expect(try JSONDecoder().decode(OutputConfig.self, from: Data(before.utf8)).presets.isEmpty)

        o.slices[0].masks = [MaskShape(feather: 2, path: [MaskPoint(0, 0), MaskPoint(1, 0), MaskPoint(0, 1)])]
        o.storePreset(3, name: nil)
        o.warp.cornerPin[0] = MapPoint(0.1, 0)
        let replacedNew = o.storePreset(1, name: "Wide")
        #expect(!replacedNew)
        let back = try JSONDecoder().decode(OutputConfig.self, from: encoder.encode(o))
        #expect(back == o && back.presets.map(\.number) == [1, 3], "kept in number order")
        #expect(back.preset(3)?.name == "Preset 3" && back.preset(3)?.warp.cornerPin[0] == MapPoint(0, 0) && back.preset(3)?.slices[0].masks.count == 1)
    }

    /// Store replaces a number (keeping its name unless one is given), recall copies warp and slices back and nothing
    /// else; numbers and names are validated.
    @Test func storeReplaceAndRecallAPreset() {
        var o = OutputConfig(id: 1)
        o.warp.cornerPin[1] = MapPoint(0.9, 0.05)
        let replacedNew = o.storePreset(7, name: "Stage")
        #expect(!replacedNew)
        o.warp.cornerPin[1] = MapPoint(1, 0)
        o.slices[0].opacity = 0.5
        o.blend.lift = 0.1
        let recalled = o.recallPreset(7)
        #expect(recalled && o.warp.cornerPin[1] == MapPoint(0.9, 0.05) && o.slices[0].opacity == 1)
        #expect(o.blend.lift == 0.1, "the blend is not in a preset")
        o.slices[0].opacity = 0.25
        let replaced = o.storePreset(7, name: nil)
        #expect(replaced)
        #expect(o.presets.count == 1 && o.preset(7)?.name == "Stage" && o.preset(7)?.slices[0].opacity == 0.25)
        let missing = o.recallPreset(8)
        #expect(!missing)

        #expect(MappingPreset.numberProblem(1) == nil && MappingPreset.numberProblem(255) == nil)
        #expect(MappingPreset.numberProblem(0) != nil && MappingPreset.numberProblem(256) != nil && MappingPreset.numberProblem(nil) != nil)
        #expect(MappingPreset.nameProblem("Stage left") == nil)
        #expect(MappingPreset.nameProblem("") != nil && MappingPreset.nameProblem(String(repeating: "x", count: 65)) != nil)
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
