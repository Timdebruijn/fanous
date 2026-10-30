// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

// Edit-time math of DESIGN.md §9.2–9.4: blend maps, warp displacement fields, mask rasters and slice meshes.
// Pure functions over plain arrays; the engine uploads the results as textures and buffers.

public enum BlendMath {
    /// The projector gamma the output pass adds the black lift and offset at (DESIGN.md §9.9, M1.7); the shader uses it.
    public static let projectorGamma = 2.2

    /// S-curve across an overlap zone: `t` 0 at the outer edge, 1 at the inner edge; symmetric so that
    /// `curve(t) + curve(1 − t) == 1` and two projectors sum to a flat field in linear light.
    public static func curve(_ t: Double, power p: Double) -> Double {
        let t = min(1, max(0, t))
        return t < 0.5 ? 0.5 * pow(2 * t, p) : 1 - 0.5 * pow(2 * (1 - t), p)
    }

    /// The factor applied to the (gamma-encoded) signal so the projector's light follows the curve. With a `channel`
    /// (0 r, 1 g, 2 b) the edge's `gammaRGB` for it; nil, or not three values (project files are not clamped on load),
    /// means `gamma`.
    public static func factor(_ t: Double, edge: BlendEdge, channel: Int? = nil) -> Double {
        let gamma = channel.flatMap { c in edge.gammaRGB.flatMap { $0.count == 3 ? $0[c] : nil } } ?? edge.gamma
        return pow(curve(t, power: edge.power), 1 / max(0.1, gamma))
    }

    /// Four floats per pixel, row-major from the top-left: (factor r, g, b, lift term). `out = in · factor + lift term`.
    /// With overlaps on both axes the lift term follows the coverage, so every point reaches the four-projector black (§9.10).
    public static func map(_ s: BlendSettings, width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height * 4)
        guard width > 0, height > 0 else { return out }
        func rgb(_ t: Double, _ edge: BlendEdge) -> SIMD3<Double> { SIMD3((0..<3).map { factor(t, edge: edge, channel: $0) }) }
        // factor (r, g, b) and "inside a zone" per axis
        func axis(_ n: Int, _ low: BlendEdge, _ high: BlendEdge) -> (factor: [SIMD3<Double>], zone: [Double]) {
            var factor = [SIMD3<Double>](repeating: .one, count: n)
            var zone = [Double](repeating: 0, count: n)  // 1 inside an overlap zone, feathered beyond it
            for i in 0..<n {
                let c = Double(i) + 0.5
                var f = SIMD3<Double>.one
                var inZone = 0.0
                if low.overlap > 0 {
                    if c < low.overlap { f *= rgb(c / low.overlap, low); inZone = 1 }
                    else if s.liftFeather > 0 { inZone = max(inZone, 1 - min(1, (c - low.overlap) / s.liftFeather)) }
                }
                if high.overlap > 0 {
                    let d = Double(n) - c
                    if d < high.overlap { f *= rgb(d / high.overlap, high); inZone = 1 }
                    else if s.liftFeather > 0 { inZone = max(inZone, 1 - min(1, (d - high.overlap) / s.liftFeather)) }
                }
                factor[i] = f
                zone[i] = inZone
            }
            return (factor, zone)
        }
        let x = axis(width, s.left, s.right)
        let y = axis(height, s.top, s.bottom)
        // ponytail: coverage 4 from the output's own edges (2 per axis); three projectors on one axis still count as 2,
        // take the coverage from the wall's layout if such a rig shows up
        let grid = (s.left.overlap > 0 || s.right.overlap > 0) && (s.top.overlap > 0 || s.bottom.overlap > 0)
        // lift × ((4 − n) / n)^(1/γ); `pow` only on feather pixels, the whole numbers are the same floats without it
        let single = s.lift * pow(3, 1 / projectorGamma)
        func coverageLift(_ n: Double) -> Double {
            switch n {
            case 1: single
            case 2: s.lift
            case 4: 0
            default: s.lift * pow((4 - n) / n, 1 / projectorGamma)
            }
        }
        for row in 0..<height {
            for col in 0..<width {
                let i = (row * width + col) * 4
                let f = x.factor[col] * y.factor[row]
                (out[i], out[i + 1], out[i + 2]) = (Float(f.x), Float(f.y), Float(f.z))
                let inZone = max(x.zone[col], y.zone[row])
                let n = (1 + x.zone[col]) * (1 + y.zone[row])  // projectors lighting the pixel, feathered: 1, 2 or 4
                out[i + 3] = Float(grid ? coverageLift(n) : s.lift * (1 - inZone))
            }
        }
        return out
    }
}

public enum WarpMath {
    /// Row-major 3×3 homography mapping the unit square (0,0),(1,0),(1,1),(0,1) onto `quad` (TL, TR, BR, BL).
    /// Heckbert's square-to-quad; falls back to the identity for a degenerate quad.
    public static func homography(to quad: [MapPoint]) -> [Double] {
        guard quad.count == 4 else { return [1, 0, 0, 0, 1, 0, 0, 0, 1] }
        let (p0, p1, p2, p3) = (quad[0], quad[1], quad[2], quad[3])
        let sx = p0.x - p1.x + p2.x - p3.x
        let sy = p0.y - p1.y + p2.y - p3.y
        var g = 0.0, h = 0.0
        if abs(sx) > 1e-12 || abs(sy) > 1e-12 {
            let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x
            let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y
            let det = dx1 * dy2 - dx2 * dy1
            guard abs(det) > 1e-12 else { return [1, 0, 0, 0, 1, 0, 0, 0, 1] }
            g = (sx * dy2 - dx2 * sy) / det
            h = (dx1 * sy - sx * dy1) / det
        }
        let a = p1.x - p0.x + g * p1.x
        let b = p3.x - p0.x + h * p3.x
        let c = p0.x
        let d = p1.y - p0.y + g * p1.y
        let e = p3.y - p0.y + h * p3.y
        let f = p0.y
        return [a, b, c, d, e, f, g, h, 1]
    }

    public static func apply(_ m: [Double], _ u: Double, _ v: Double) -> MapPoint {
        let w = m[6] * u + m[7] * v + m[8]
        let s = abs(w) < 1e-12 ? 1 : 1 / w
        return MapPoint((m[0] * u + m[1] * v + m[2]) * s, (m[3] * u + m[4] * v + m[5]) * s)
    }

    /// The Keystone fixture's homography (DESIGN.md §6.4a, §9.10 item 2) from its raw values in channel-map order: the
    /// unit square onto the corners moved by the offsets, guarded as `keystone(to:)`. Centred values give the identity exactly.
    public static func keystone(raw: [UInt16]) -> [Double]? {
        guard raw.count == ChannelMap.keystone.count else { return nil }
        let offsets = zip(ChannelMap.keystone, raw).map { $0.physical(fromRaw: $1) / 100 }
        return keystone(to: WarpSettings().cornerPin.enumerated().map { i, p in MapPoint(p.x + offsets[2 * i], p.y + offsets[2 * i + 1]) })
    }

    /// The homography onto `quad` (TL, TR, BR, BL); nil when the quad is not strictly convex (the four corner cross
    /// products differ in sign or one is 0: crossed, concave or degenerate) or w ≤ 0 at a corner, which would turn the
    /// picture inside out.
    public static func keystone(to quad: [MapPoint]) -> [Double]? {
        guard quad.count == 4 else { return nil }
        let crosses = (0..<4).map { i in
            let (a, b, c) = (quad[i], quad[(i + 1) % 4], quad[(i + 2) % 4])
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        guard crosses.allSatisfy({ $0 > 1e-12 }) || crosses.allSatisfy({ $0 < -1e-12 }) else { return nil }
        let m = homography(to: quad)
        guard [(0.0, 0.0), (1, 0), (1, 1), (0, 1)].allSatisfy({ m[6] * $0.0 + m[7] * $0.1 + m[8] > 0 }) else { return nil }
        return m
    }

    /// Catmull-Rom spline through uniformly spaced values; the phantom points beyond the ends are extrapolated
    /// linearly, so a straight sequence stays exactly straight (an undistorted mesh is the identity).
    static func catmullRom(_ values: [Double], _ t: Double) -> Double {
        let n = values.count
        guard n > 1 else { return values.first ?? 0 }
        let x = min(max(t, 0), 1) * Double(n - 1)
        let i = min(n - 2, Int(x))
        let f = x - Double(i)
        let p1 = values[i], p2 = values[i + 1]
        let p0 = i > 0 ? values[i - 1] : 2 * p1 - p2
        let p3 = i + 2 < n ? values[i + 2] : 2 * p2 - p1
        return 0.5 * ((2 * p1) + (-p0 + p2) * f + (2 * p0 - 5 * p1 + 4 * p2 - p3) * f * f + (-p0 + 3 * p1 - 3 * p2 + p3) * f * f * f)
    }

    /// The displacement field (DESIGN.md §9.3): `cols × rows` samples of the warped position, two floats each,
    /// row-major from the top-left; sample (c, r) stands for the undistorted point (c/(cols−1), r/(rows−1)).
    /// The mesh is evaluated separably (every control row along u, then each column along v), so a 33×33 mesh
    /// at 480×270 samples is ~150 k spline evaluations.
    public static func field(_ warp: WarpSettings, cols: Int, rows: Int) -> [Float] {
        let cols = max(2, cols), rows = max(2, rows)
        let h = homography(to: warp.cornerPin)
        var out = [Float](repeating: 0, count: cols * rows * 2)
        if let mesh = warp.mesh, mesh.cols >= 2, mesh.rows >= 2, mesh.points.count == mesh.cols * mesh.rows {
            // pass 1: each control row sampled at every u
            var rowX = [Double](repeating: 0, count: mesh.rows * cols)
            var rowY = [Double](repeating: 0, count: mesh.rows * cols)
            var xs = [Double](repeating: 0, count: mesh.cols), ys = xs
            for r in 0..<mesh.rows {
                for c in 0..<mesh.cols {
                    xs[c] = mesh.points[r * mesh.cols + c].x
                    ys[c] = mesh.points[r * mesh.cols + c].y
                }
                for c in 0..<cols {
                    let u = Double(c) / Double(cols - 1)
                    rowX[r * cols + c] = catmullRom(xs, u)
                    rowY[r * cols + c] = catmullRom(ys, u)
                }
            }
            // pass 2: for each sample column, the spline across the control rows at v
            var colX = [Double](repeating: 0, count: mesh.rows), colY = colX
            for c in 0..<cols {
                for r in 0..<mesh.rows {
                    colX[r] = rowX[r * cols + c]
                    colY[r] = rowY[r * cols + c]
                }
                for r in 0..<rows {
                    let v = Double(r) / Double(rows - 1)
                    let p = apply(h, catmullRom(colX, v), catmullRom(colY, v))
                    let i = (r * cols + c) * 2
                    out[i] = Float(p.x)
                    out[i + 1] = Float(p.y)
                }
            }
        } else {
            for r in 0..<rows {
                let v = Double(r) / Double(rows - 1)
                for c in 0..<cols {
                    let p = apply(h, Double(c) / Double(cols - 1), v)
                    let i = (r * cols + c) * 2
                    out[i] = Float(p.x)
                    out[i + 1] = Float(p.y)
                }
            }
        }
        return out
    }
}

public enum MaskMath {
    /// Signed distance from a point to a polygon in the same units: positive inside, negative outside.
    public static func signedDistance(_ x: Double, _ y: Double, polygon: [(x: Double, y: Double)]) -> Double {
        let n = polygon.count
        guard n >= 3 else { return -1 }
        var inside = false
        var best = Double.infinity
        var j = n - 1
        for i in 0..<n {
            let (ax, ay) = polygon[i], (bx, by) = polygon[j]
            // even-odd crossing test
            if (ay > y) != (by > y) {
                let xAtY = ax + (y - ay) / (by - ay) * (bx - ax)
                if x < xAtY { inside.toggle() }
            }
            // distance to the segment a–b
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(1, max(0, ((x - ax) * dx + (y - ay) * dy) / len2)) : 0
            let px = ax + t * dx - x, py = ay + t * dy - y
            best = min(best, px * px + py * py)
            j = i
        }
        return (inside ? 1 : -1) * best.squareRoot()
    }

    /// 8-bit coverage, row-major from the top-left: 255 inside, 0 outside, a linear ramp over `feather` pixels
    /// centred on the edge (exact signed-distance feathering, DESIGN.md §9.4). `step` > 1 evaluates every
    /// step-th pixel (the result is `ceil(width/step) × ceil(height/step)`, sampled linearly by the shader):
    /// a smooth distance field loses nothing when the feather spans a few samples.
    public static func raster(_ mask: MaskSettings, width: Int, height: Int, step: Int = 1) -> (width: Int, height: Int, bytes: [UInt8]) {
        let step = max(1, step)
        let cols = (width + step - 1) / step, rows = (height + step - 1) / step
        var out = [UInt8](repeating: 0, count: max(0, cols * rows))
        guard width > 0, height > 0, mask.path.count >= 3 else { return (cols, rows, out) }
        let polygon = mask.path.map { (x: $0.x * Double(width), y: $0.y * Double(height)) }
        let feather = max(0, mask.feather)
        for r in 0..<rows {
            let y = (Double(r) + 0.5) * Double(height) / Double(rows)
            for c in 0..<cols {
                let x = (Double(c) + 0.5) * Double(width) / Double(cols)
                let d = signedDistance(x, y, polygon: polygon)
                let v: Double = feather > 0 ? min(1, max(0, 0.5 + d / feather)) : (d >= 0 ? 1 : 0)
                out[r * cols + c] = UInt8((v * 255).rounded())
            }
        }
        return (cols, rows, out)
    }
}

public enum SliceMesh {
    /// One vertex: position in normalized output coordinates, texture coordinate on the canvas.
    public struct Vertex: Equatable, Sendable {
        public var x: Float, y: Float, u: Float, v: Float
        public init(x: Float, y: Float, u: Float, v: Float) {
            self.x = x
            self.y = y
            self.u = u
            self.v = v
        }
    }

    /// `subdivisions × subdivisions` quads as a triangle list. Positions interpolate the destination quad
    /// bilinearly (TL, TR, BR, BL); UVs cover the source rectangle.
    public static func build(_ slice: SliceConfig, subdivisions n: Int) -> (vertices: [Vertex], indices: [UInt32]) {
        let n = max(1, n)
        guard slice.dest.count == 4 else { return ([], []) }
        let (tl, tr, br, bl) = (slice.dest[0], slice.dest[1], slice.dest[2], slice.dest[3])
        var vertices: [Vertex] = []
        vertices.reserveCapacity((n + 1) * (n + 1))
        for r in 0...n {
            let v = Double(r) / Double(n)
            for c in 0...n {
                let u = Double(c) / Double(n)
                let top = MapPoint(tl.x + (tr.x - tl.x) * u, tl.y + (tr.y - tl.y) * u)
                let bottom = MapPoint(bl.x + (br.x - bl.x) * u, bl.y + (br.y - bl.y) * u)
                vertices.append(
                    Vertex(
                        x: Float(top.x + (bottom.x - top.x) * v), y: Float(top.y + (bottom.y - top.y) * v),
                        u: Float(slice.source.x + slice.source.w * u), v: Float(slice.source.y + slice.source.h * v)))
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(n * n * 6)
        for r in 0..<n {
            for c in 0..<n {
                let a = UInt32(r * (n + 1) + c), b = a + 1, d = a + UInt32(n + 1), e = d + 1
                indices += [a, d, b, b, d, e]
            }
        }
        return (vertices, indices)
    }
}
