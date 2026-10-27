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
        func at(_ x: Int, _ y: Int) -> (Float, Float) { (map[(y * 8 + x) * 2], map[(y * 8 + x) * 2 + 1]) }
        #expect(at(7, 3) == (1, 0.1), "outside every zone: full signal plus lift")
        #expect(abs(at(0, 3).0 - 0.125) < 1e-6 && at(0, 3).1 == 0, "left zone: linear ramp, no lift")
        #expect(abs(at(3, 3).0 - 0.875) < 1e-6)
        #expect(abs(at(0, 0).0 - 0.125 * 0.25) < 1e-6, "corner multiplies both axes")
        #expect(at(7, 0).1 == 0, "inside the top zone")
        #expect(BlendSettings().isIdentity)
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
        let data = try JSONEncoder().encode(output)
        let back = try JSONDecoder().decode(OutputConfig.self, from: data)
        #expect(back == output)
        #expect(OutputConfig(id: 1).slices.count == 1 && OutputConfig(id: 1).name == "Output 1")
    }
}
