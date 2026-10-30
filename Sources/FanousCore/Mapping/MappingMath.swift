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
    /// Segment i of a closed mask path, from point i to the next (the last back to the first): a line, or with a handle at
    /// either end a cubic Bézier through the point's `out` handle and the next one's `in` (a missing one is its own point).
    public struct Edge: Sendable {
        public var a: MapPoint, c1: MapPoint, c2: MapPoint, b: MapPoint
        public var curved: Bool
        /// The point at t (0…1) along it.
        public func at(_ t: Double) -> MapPoint {
            guard curved else { return MapPoint(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t) }
            let s = 1 - t
            let (wa, w1, w2, wb) = (s * s * s, 3 * s * s * t, 3 * s * t * t, t * t * t)
            return MapPoint(wa * a.x + w1 * c1.x + w2 * c2.x + wb * b.x, wa * a.y + w1 * c1.y + w2 * c2.y + wb * b.y)
        }
    }

    public static func edges(_ path: [MaskPoint]) -> [Edge] {
        path.indices.map { i in
            let p = path[i], q = path[(i + 1) % path.count]
            let out = p.out ?? MapPoint(0, 0), into = q.in ?? MapPoint(0, 0)
            return Edge(
                a: MapPoint(p.x, p.y), c1: MapPoint(p.x + out.x, p.y + out.y), c2: MapPoint(q.x + into.x, q.y + into.y), b: MapPoint(q.x, q.y),
                curved: p.out != nil || q.in != nil)
        }
    }

    /// The closed outline of `path` in pixels of a w × h output, a line per straight segment and curves flattened to
    /// within a quarter pixel: what the fill and the feather both use.
    public static func outline(_ path: [MaskPoint], width: Int, height: Int) -> [(x: Double, y: Double)] {
        let (sx, sy) = (Double(width), Double(height))
        var out: [(x: Double, y: Double)] = []
        for e in edges(path) {
            var n = 1
            if e.curved {
                // a cubic cut into n equal steps of t is off by at most ¾ · dd / n² (dd the larger second difference of its
                // points): a quarter pixel needs n² ≥ 3 · dd. Clamped before the conversion (`min` keeps 1024 for NaN)
                let dd = max(
                    hypot((e.a.x - 2 * e.c1.x + e.c2.x) * sx, (e.a.y - 2 * e.c1.y + e.c2.y) * sy),
                    hypot((e.c1.x - 2 * e.c2.x + e.b.x) * sx, (e.c1.y - 2 * e.c2.y + e.b.y) * sy))
                n = max(1, Int(min(1024, (3 * dd).squareRoot().rounded(.up))))
            }
            for k in 0..<n {
                let p = e.at(Double(k) / Double(n))
                out.append((p.x * sx, p.y * sy))
            }
        }
        return out
    }

    /// The grid a path mask is rasterised on (DESIGN.md §9.10 item 5): every `step`-th output pixel. Under a 2 px feather
    /// the anti-aliased edge needs every pixel. A feather is a smooth ramp the shader samples linearly: up to 32 px the grid
    /// of the compile before M2.7 (up to 4 px), wider 8 samples across the ramp, so the cost stays bounded at any feather.
    public static func step(feather: Double) -> Int {
        guard feather >= 2 else { return 1 }
        return max(Int(min(4, feather / 2)), Int(min(1_000_000, feather / 8)))  // clamped before the conversion
    }

    /// A coordinate in grid cells as an index, clamped to −1…hi before the conversion (a point at 1e19 would trap it; `max`
    /// keeps −1 for NaN).
    private static func index(_ v: Double, _ hi: Int) -> Int { Int(min(Double(hi), max(-1, v))) }

    /// The nonzero fill of a closed outline (output pixels) at the centres of a w × h grid whose cells are `cell` output
    /// pixels wide and high: 255 inside, 0 outside, row-major from the top-left. The sign under a feather: CoreGraphics'
    /// aliased fill sets every pixel the path touches, up to a pixel outside the edge, so it would not agree with the
    /// distance.
    public static func fill(_ outline: [(x: Double, y: Double)], width: Int, height: Int, cell: (x: Double, y: Double) = (1, 1)) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(0, width * height))
        guard width > 0, height > 0 else { return out }
        // per row, where a segment crosses the row's centre line and which way: half-open in y, so a point two segments
        // share counts once
        var crossings = [[(x: Double, winding: Int)]](repeating: [], count: height)
        for i in outline.indices {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            guard a.y != b.y else { continue }
            let (lo, hi) = a.y < b.y ? (a, b) : (b, a)
            let first = max(0, index((lo.y / cell.y - 0.5).rounded(.up), height))
            let last = min(height - 1, index((hi.y / cell.y - 0.5).rounded(.up), height) - 1)
            guard first <= last else { continue }
            for row in first...last {
                let y = (Double(row) + 0.5) * cell.y
                crossings[row].append((lo.x + (y - lo.y) / (hi.y - lo.y) * (hi.x - lo.x), a.y < b.y ? 1 : -1))
            }
        }
        out.withUnsafeMutableBufferPointer { out in
            for row in 0..<height where crossings[row].count >= 2 {
                let sorted = crossings[row].sorted { $0.x < $1.x }
                var winding = 0
                for k in 0..<(sorted.count - 1) {
                    winding += sorted[k].winding
                    guard winding != 0 else { continue }
                    // the centres from this crossing up to the next
                    let from = max(0, index((sorted[k].x / cell.x - 0.5).rounded(.up), width))
                    let to = min(width - 1, index((sorted[k + 1].x / cell.x - 0.5).rounded(.up), width) - 1)
                    if from <= to { UnsafeMutableBufferPointer(rebasing: out[(row * width + from)...(row * width + to)]).update(repeating: 255) }
                }
            }
        }
        return out
    }

    /// A path's coverage with its feather (DESIGN.md §9.10 item 5) on a w × h grid of `cell`-sized cells, row-major from
    /// the top-left: the nonzero fill, and within feather/2 of the filled region's edge 0.5 + d / feather, d the distance
    /// to it, positive inside: a linear ramp, 0.5 on the edge. Banded: each segment of the closed `outline` (output pixels)
    /// visits only the samples within feather/2 of it (per row, the part of the segment within feather/2 of that row),
    /// keeping the nearest, instead of every segment for every sample; it measures to its parts on the edge (`edgeParts`).
    public static func feathered(
        _ outline: [(x: Double, y: Double)], feather: Double, width: Int, height: Int, cell: (x: Double, y: Double) = (1, 1)
    ) -> [UInt8] {
        var coverage = fill(outline, width: width, height: height, cell: cell)
        let r = feather / 2
        guard r > 0, outline.count >= 2 else { return coverage }
        let parts = edgeParts(outline, area: (Double(width) * cell.x, Double(height) * cell.y))
        coverage.withUnsafeMutableBufferPointer { out in
            for i in outline.indices where !parts[i].isEmpty {
                let a = outline[i], b = outline[(i + 1) % outline.count]
                let (dx, dy) = (b.x - a.x, b.y - a.y)
                let len2 = dx * dx + dy * dy
                guard len2 > 0 else { continue }  // a repeated point: its neighbours have it as an end
                // rows whose centre lies within r of the segment's y range
                let top = max(0, index(((min(a.y, b.y) - r) / cell.y - 0.5).rounded(.up), height))
                let bottom = min(height - 1, index(((max(a.y, b.y) + r) / cell.y - 0.5).rounded(.down), height))
                guard top <= bottom else { continue }
                for row in top...bottom {
                    let yc = (Double(row) + 0.5) * cell.y
                    // the part of the segment within r of this row, widened by r: every sample of the row within r of it
                    var (t0, t1) = (0.0, 1.0)
                    if dy != 0 {
                        let (ta, tb) = ((yc - r - a.y) / dy, (yc + r - a.y) / dy)
                        (t0, t1) = (max(0, min(ta, tb)), min(1, max(ta, tb)))
                    }
                    guard t0 <= t1 else { continue }
                    let (xa, xb) = (a.x + t0 * dx, a.x + t1 * dx)
                    let left = max(0, index(((min(xa, xb) - r) / cell.x - 0.5).rounded(.up), width))
                    let right = min(width - 1, index(((max(xa, xb) + r) / cell.x - 0.5).rounded(.down), width))
                    guard left <= right else { continue }
                    for col in left...right {
                        let (px, py) = ((Double(col) + 0.5) * cell.x - a.x, yc - a.y)
                        let along = (px * dx + py * dy) / len2
                        var d2 = Double.infinity
                        for part in parts[i] {
                            let t = min(part.upperBound, max(part.lowerBound, along))
                            let (ex, ey) = (px - t * dx, py - t * dy)
                            d2 = min(d2, ex * ex + ey * ey)
                        }
                        guard d2 < r * r else { continue }
                        // a sample keeps its side while segments write it: inside values stay ≥ 128 and outside ones ≤ 128
                        // (both 128 on the edge itself), so the nearest segment wins with min inside and max outside
                        let k = row * width + col, inside = out[k] >= 128
                        let v = UInt8(((0.5 + (inside ? 1 : -1) * d2.squareRoot() / feather) * 255).rounded())
                        out[k] = inside ? min(out[k], v) : max(out[k], v)
                    }
                }
            }
        }
        return coverage
    }

    /// Where the filled region's edge runs along a closed outline (output pixels, around an area of that size): per
    /// segment, its parts (0…1 along it) with winding 0 on one side. Where the path crosses or overlaps itself (the
    /// nonzero rule fills it) it runs through the filled region, and those parts are no edge; a simple path is edge all
    /// along. The winding beside the path changes only where another segment crosses it: from one ray cast, a walk along
    /// the path through its crossings gives it everywhere.
    static func edgeParts(_ outline: [(x: Double, y: Double)], area: (width: Double, height: Double)) -> [[ClosedRange<Double>]] {
        let n = outline.count
        let whole: [ClosedRange<Double>] = [0...1]
        // ponytail: points shifted by up to 1e-5 px, so a path through one of its own corners crosses at a segment's inside
        // (a crossing exactly at a corner counts as none); a symbolic tie-break if a show ever needs better
        let p = outline.indices.map { i -> (x: Double, y: Double) in
            let s = sin(Double(i) * 12.9898) * 43758.5453
            return (outline[i].x + (s - s.rounded(.down) - 0.5) * 2e-5, outline[i].y + (s * 7 - (s * 7).rounded(.down) - 0.5) * 2e-5)
        }
        // crossings between segments, per bucket, each counted in the bucket that holds it; the winding left of segment i
        // (where the cross product with its direction is positive) changes by `change` at `t` along it
        let size = max(8, (area.width * area.height / Double(n)).squareRoot())
        func bucket(_ v: Double, _ count: Int) -> Int { Int(min(Double(count - 1), max(0, v / size))) }  // NaN to 0
        let columns = Int(min(256, (area.width / size).rounded(.up))) + 1, rows = Int(min(256, (area.height / size).rounded(.up))) + 1
        var buckets = [[Int]](repeating: [], count: columns * rows)
        for i in 0..<n {
            let (a, b) = (p[i], p[(i + 1) % n])
            for y in bucket(min(a.y, b.y), rows)...bucket(max(a.y, b.y), rows) {
                for x in bucket(min(a.x, b.x), columns)...bucket(max(a.x, b.x), columns) { buckets[y * columns + x].append(i) }
            }
        }
        var turns = [[(t: Double, change: Int)]](repeating: [], count: n)
        for (index, segments) in buckets.enumerated() where segments.count >= 2 {
            for (k, i) in segments.enumerated() {
                let (a, b) = (p[i], p[(i + 1) % n])
                let (rx, ry) = (b.x - a.x, b.y - a.y)
                for j in segments[(k + 1)...] where j != (i + 1) % n && i != (j + 1) % n {
                    let (c, d) = (p[j], p[(j + 1) % n])
                    let (sx, sy) = (d.x - c.x, d.y - c.y)
                    let cross = rx * sy - ry * sx
                    guard cross != 0 else { continue }
                    let (ax, ay) = (c.x - a.x, c.y - a.y)
                    let (t, u) = ((ax * sy - ay * sx) / cross, (ax * ry - ay * rx) / cross)
                    guard t >= 0, t < 1, u >= 0, u < 1, bucket(a.y + t * ry, rows) * columns + bucket(a.x + t * rx, columns) == index else { continue }
                    // just before the crossing, the left of i is on j's left when j runs to i's left (a positive cross
                    // product), and crossing to j's right adds 1, as `winding` counts a downward segment; the same for j
                    // the other way round
                    turns[i].append((t, cross > 0 ? 1 : -1))
                    turns[j].append((u, cross > 0 ? -1 : 1))
                }
            }
        }
        // the winding just left of the middle of the first segment of some length, by the fill's rule (a level ray to the
        // left, half-open in y)
        guard let first = (0..<n).first(where: { p[$0] != p[($0 + 1) % n] }) else { return [[ClosedRange<Double>]](repeating: whole, count: n) }
        let (a0, b0) = (p[first], p[(first + 1) % n])
        let length = hypot(b0.x - a0.x, b0.y - a0.y)
        let probe = ((a0.x + b0.x) / 2 - (b0.y - a0.y) / length * 1e-4, (a0.y + b0.y) / 2 + (b0.x - a0.x) / length * 1e-4)
        var left = 0
        for i in 0..<n {
            let (a, b) = (p[i], p[(i + 1) % n])
            guard a.y != b.y else { continue }
            let (lo, hi) = a.y < b.y ? (a, b) : (b, a)
            if lo.y <= probe.1, probe.1 < hi.y, lo.x + (probe.1 - lo.y) / (hi.y - lo.y) * (hi.x - lo.x) < probe.0 { left += a.y < b.y ? 1 : -1 }
        }
        left -= turns[first].reduce(0) { $0 + ($1.t < 0.5 ? $1.change : 0) }
        // the walk: a part is edge where the winding left of it, or right of it (one more), is 0
        var parts = [[ClosedRange<Double>]](repeating: [], count: n)
        let start = left
        for step in 0..<n {
            let i = (first + step) % n
            var from = 0.0
            for turn in turns[i].sorted(by: { $0.t < $1.t }) + [(t: 1.0, change: 0)] {
                if left == 0 || left == -1 {
                    if let last = parts[i].last, last.upperBound == from { parts[i][parts[i].count - 1] = last.lowerBound...turn.t } else { parts[i].append(from...turn.t) }
                }
                (left, from) = (left + turn.change, turn.t)
            }
        }
        // a walk that does not close (a path NaN or far beyond the output put out of the buckets): edge all along, as
        // before M2.7
        return left == start ? parts : [[ClosedRange<Double>]](repeating: whole, count: n)
    }

    /// A w × h grid resampled bilinearly to a W × H one, as a texture's linear sampling reads it (sample centres aligned,
    /// clamped at the edges): a feathered mask on its own grid combined with one that needs a finer grid.
    public static func resample(_ bytes: [UInt8], width w: Int, height h: Int, to W: Int, _ H: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(0, W * H))
        guard w > 0, h > 0, bytes.count == w * h else { return out }
        // the two source samples around output sample i and the second one's weight
        func taps(_ i: Int, _ n: Int, _ N: Int) -> (Int, Int, Float) {
            let s = min(Double(n - 1), max(0, (Double(i) + 0.5) * Double(n) / Double(N) - 0.5))
            return (Int(s), min(n - 1, Int(s) + 1), Float(s - s.rounded(.down)))
        }
        let columns = (0..<W).map { taps($0, w, W) }
        // per output row: the source rows mixed once, then each output sample from two of them
        var mixed = [Float](repeating: 0, count: w)
        bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                mixed.withUnsafeMutableBufferPointer { mixed in
                    for y in 0..<H {
                        let (r0, r1, fy) = taps(y, h, H)
                        for x in 0..<w { mixed[x] = Float(src[r0 * w + x]) + (Float(src[r1 * w + x]) - Float(src[r0 * w + x])) * fy }
                        for (x, (c0, c1, fx)) in columns.enumerated() { dst[y * W + x] = UInt8((mixed[c0] + (mixed[c1] - mixed[c0]) * fx).rounded()) }
                    }
                }
            }
        }
        return out
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
