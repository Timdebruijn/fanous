// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Metal
import Synchronization

/// The point Warp & Slices has selected (`output.overlay`'s `selected`, DESIGN.md §9.10 item 4): corner `point` of the
/// corner pin, mesh point `point` (row-major), corner `point` of slice `slice` (its index in `slices`), or point `point`
/// of that slice's mask `mask` (its index in `masks`; the point, not a handle).
public struct OverlaySelection: Equatable, Sendable {
    public enum Kind: String, Sendable { case corner, mesh, slice, mask }
    public var slice: Int
    public var kind: Kind
    public var mask: Int
    public var point: Int
    public init(slice: Int = 0, kind: Kind, mask: Int = 0, point: Int) {
        (self.slice, self.kind, self.mask, self.point) = (slice, kind, mask, point)
    }
}

/// One line of the overlay, as `OverlaySegment` in Shaders.swift reads it (40 bytes): its ends in output coordinates
/// before the warp, and offsets in pixels added after the warp and the keystone (the crosshair and its label are drawn
/// in pixels around one point).
struct OverlaySegment: Equatable {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var offsetA = SIMD2<Float>.zero
    var offsetB = SIMD2<Float>.zero
    /// 1 = the selection (yellow), 2 = wide (its crosshair).
    var flags: UInt32 = 0
}

/// The on-output edit overlay (DESIGN.md §9.10 item 4) of every output, by output id: the lease of `output.overlay`, its
/// selection and the lines built from them and the edited mapping. An output's entry is its box: the coordinator owns
/// this, hands it to every plan it compiles and swaps one entry whole when a lease starts, renews or changes its
/// selection or an edit recompiles, so a selection change never recompiles a plan. Written on the main actor only, so
/// two builds never race (`@MainActor`); the render threads and `live.outputs` read it.
public final class EditOverlay: @unchecked Sendable {
    /// A lease runs this long after its last renewal (the UI renews every 2 s); the render threads stop drawing it then.
    static let lease: Double = 5
    /// Segments per output (640 KB): a 33 × 33 mesh is 4,224 and a slice 256. Past it the last lines (the last slices'
    /// outlines and masks) are not drawn; the selection always is.
    static let maxSegments = 16_384
    /// Pieces per mesh line and slice edge: the slice tessellation, so a slice's outline runs through its mesh's edge
    /// vertices and lies on the picture's edge under any warp.
    static let pieces = OutputCompiler.sliceSubdivisions

    struct Lines: @unchecked Sendable {  // the buffer is immutable once built
        let buffer: MTLBuffer
        let count: Int
    }
    private struct Entry: @unchecked Sendable {
        var until: Double
        var selected: OverlaySelection?
        var lines: Lines?
    }
    private let device: MTLDevice
    private let entries = Mutex<[Int: Entry]>([:])

    init(device: MTLDevice) { self.device = device }

    /// `output.overlay` for output `id` (`config`: its edited mapping, nil when it is gone): on starts or renews the
    /// lease until `now` + 5 s with this call's selection, the latest; a renewal that keeps the selection keeps the
    /// lines. Off ends it.
    @MainActor func lease(_ id: Int, on: Bool, selected: OverlaySelection?, config: OutputConfig?, at now: Double) {
        guard on, let config else { return entries.withLock { $0[id] = nil } }
        let kept = entries.withLock { $0[id] }.flatMap { $0.until > now && $0.selected == selected ? $0.lines : nil }
        let entry = Entry(until: now + Self.lease, selected: selected, lines: kept ?? build(config, selected))
        entries.withLock { $0[id] = entry }
    }

    /// An edit (every rebind): each running lease's lines from its output's mapping now. A lease that ran out or whose
    /// output went is dropped with its lines.
    @MainActor func rebuild(_ outputs: [OutputConfig], at now: Double) {
        let running = entries.withLock { $0.filter { $0.value.until > now } }
        var next: [Int: Entry] = [:]
        for (id, entry) in running {
            guard let config = outputs.first(where: { $0.id == id }) else { continue }
            next[id] = Entry(until: entry.until, selected: entry.selected, lines: build(config, entry.selected))
        }
        entries.withLock { $0 = next }
    }

    /// Show mode and show lock end every lease at once.
    @MainActor func endAll() { entries.withLock { $0.removeAll() } }

    /// What output `id` draws at `now` (host time): its lines while its lease runs. Allocates nothing (render threads).
    func lines(_ id: Int, at now: Double) -> Lines? {
        entries.withLock { $0[id].flatMap { now < $0.until ? $0.lines : nil } }
    }

    /// A lease runs for output `id` at `now` (`live.outputs`).
    public func asked(_ id: Int, at now: Double) -> Bool { entries.withLock { ($0[id]?.until ?? 0) > now } }

    private func build(_ config: OutputConfig, _ selected: OverlaySelection?) -> Lines? {
        let segments = Self.segments(config, selected: selected)
        guard !segments.isEmpty,
            let buffer = device.makeBuffer(bytes: segments, length: segments.count * MemoryLayout<OverlaySegment>.stride, options: .storageModeShared)
        else { return nil }
        buffer.label = "overlay \(config.id)"
        return Lines(buffer: buffer, count: segments.count)
    }

    /// The overlay of `config`, all before the warp: the warp (the mesh's grid lines, else the corner pin's edges, the
    /// output's own edges through the warp), each slice's outline and its mask's, then the selected point's crosshair and
    /// label on top. A selection the mapping does not have (an edit since) draws none.
    static func segments(_ config: OutputConfig, selected: OverlaySelection?) -> [OverlaySegment] {
        let marks = selected.flatMap { mark(config, $0) } ?? []
        var lines: [OverlaySegment] = []
        // appending stops at the cap, which keeps room for the selection: nothing bounds a point's coordinates
        func curve(_ at: (Double) -> MapPoint, pieces n: Int) {
            func point(_ t: Double) -> SIMD2<Float> {
                let p = at(t)
                return SIMD2(Float(p.x), Float(p.y))
            }
            for k in 0..<max(0, min(n, maxSegments - marks.count - lines.count)) {
                lines.append(OverlaySegment(a: point(Double(k) / Double(n)), b: point(Double(k + 1) / Double(n))))
            }
        }
        func line(_ p: MapPoint, _ q: MapPoint) { curve({ MapPoint(p.x + (q.x - p.x) * $0, p.y + (q.y - p.y) * $0) }, pieces: pieces) }
        if let mesh = config.warp.mesh, mesh.cols >= 2, mesh.rows >= 2, mesh.points.count == mesh.cols * mesh.rows {
            for r in 0..<mesh.rows { line(MapPoint(0, Double(r) / Double(mesh.rows - 1)), MapPoint(1, Double(r) / Double(mesh.rows - 1))) }
            for c in 0..<mesh.cols { line(MapPoint(Double(c) / Double(mesh.cols - 1), 0), MapPoint(Double(c) / Double(mesh.cols - 1), 1)) }
        } else {
            for (i, p) in WarpSettings().cornerPin.enumerated() { line(p, WarpSettings().cornerPin[(i + 1) % 4]) }
        }
        for slice in config.slices where slice.dest.count == 4 {
            for (i, p) in slice.dest.enumerated() { line(p, slice.dest[(i + 1) % 4]) }
            // masks are sampled per pixel before the warp: each path edge, curves included, in pieces of at most 1/64 of the
            // output (by its points' extent), clamped before the conversion (a point at 1e19 would trap it); an image has none
            for mask in slice.masks {
                guard let path = mask.path, path.count >= 3 else { continue }
                for e in MaskMath.edges(path) {
                    let extent = max(max(e.a.x, e.c1.x, e.c2.x, e.b.x) - min(e.a.x, e.c1.x, e.c2.x, e.b.x), max(e.a.y, e.c1.y, e.c2.y, e.b.y) - min(e.a.y, e.c1.y, e.c2.y, e.b.y))
                    curve(e.at, pieces: max(1, Int(min(Double(maxSegments), (extent * Double(pieces)).rounded(.up)))))
                }
            }
        }
        return lines + marks
    }

    /// The selected point's crosshair and its digits-only label ("3·5" row·column for a mesh point, else the point
    /// number), in pixels around the point; nil when the mapping has no such point.
    static func mark(_ config: OutputConfig, _ s: OverlaySelection) -> [OverlaySegment]? {
        func digits(_ n: Int) -> [Int] { String(n).compactMap(\.wholeNumberValue) }
        let at: MapPoint, label: [Int]  // 10: the dot between a mesh point's row and column
        switch s.kind {
        case .corner:
            // ponytail: the output's corner through the whole warp, so under a mesh whose corner point moved this marks the
            // picture's corner, not the pin handle; give the vertex shader the pin alone for it if that confuses at the wall
            guard (0..<4).contains(s.point) else { return nil }
            (at, label) = (WarpSettings().cornerPin[s.point], digits(s.point + 1))
        case .mesh:
            guard let mesh = config.warp.mesh, mesh.cols >= 2, mesh.rows >= 2, mesh.points.count == mesh.cols * mesh.rows, mesh.points.indices.contains(s.point)
            else { return nil }
            let (r, c) = s.point.quotientAndRemainder(dividingBy: mesh.cols)
            (at, label) = (MapPoint(Double(c) / Double(mesh.cols - 1), Double(r) / Double(mesh.rows - 1)), digits(r + 1) + [10] + digits(c + 1))
        case .slice:
            guard config.slices.indices.contains(s.slice), config.slices[s.slice].dest.indices.contains(s.point) else { return nil }
            (at, label) = (config.slices[s.slice].dest[s.point], digits(s.point + 1))
        case .mask:
            guard config.slices.indices.contains(s.slice), config.slices[s.slice].masks.indices.contains(s.mask), let path = config.slices[s.slice].masks[s.mask].path,
                path.indices.contains(s.point)
            else { return nil }
            (at, label) = (MapPoint(path[s.point].x, path[s.point].y), digits(s.point + 1))
        }
        let p = SIMD2(Float(at.x), Float(at.y))
        func mark(_ from: SIMD2<Float>, _ to: SIMD2<Float>, flags: UInt32 = 1) -> OverlaySegment { OverlaySegment(a: p, b: p, offsetA: from, offsetB: to, flags: flags) }
        // four arms 6–24 px from the point, so the point itself stays visible
        var marks = [SIMD2<Float>(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1)].map { mark($0 * 6, $0 * 24, flags: 3) }
        // the test patterns' seven-segment digits, 12 × 22 px, 30 px off towards the middle of the output (as the point
        // lies before the warp), so the label stays on it
        let (w, h, gap): (Float, Float, Float) = (12, 22, 8)
        let width = label.reduce(0) { $0 + ($1 == 10 ? 0 : w) } + gap * Float(label.count - 1)
        var x: Float = at.x <= 0.5 ? 30 : -30 - width
        let y: Float = at.y <= 0.5 ? 30 : -30 - h
        for c in label {
            guard c < 10 else {
                marks.append(mark(SIMD2(x, y + h / 2), SIMD2(x, y + h / 2)))  // no length: a square dot
                x += gap
                continue
            }
            let (l, r) = c == 1 ? (x + w / 2, x + w / 2) : (x, x + w)  // a 1 in the middle, as typeset
            let ends: [(SIMD2<Float>, SIMD2<Float>)] = [  // segments a…g, the bits of `sevenSegments`
                (SIMD2(x, y), SIMD2(x + w, y)), (SIMD2(r, y), SIMD2(r, y + h / 2)), (SIMD2(r, y + h / 2), SIMD2(r, y + h)),
                (SIMD2(x, y + h), SIMD2(x + w, y + h)), (SIMD2(l, y + h / 2), SIMD2(l, y + h)), (SIMD2(l, y), SIMD2(l, y + h / 2)),
                (SIMD2(x, y + h / 2), SIMD2(x + w, y + h / 2)),
            ]
            for (i, e) in ends.enumerated() where ShaderSource.sevenSegments[c] & (1 << i) != 0 { marks.append(mark(e.0, e.1)) }
            x += w + gap
        }
        return marks
    }
}
