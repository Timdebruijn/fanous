// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

// Projector walls (DESIGN.md §9.9): a grid of outputs over a rectangle of one canvas. A wall compiles into fields the
// outputs already have (slice 1's source and the blend edges), so the render path does not change. The wall computes
// the geometry; the tuning (gamma and curve per seam, black floor and colour per projector) is set by eye.

/// Overlap between neighbours as a fraction of one projector's width (`x`) and height (`y`), 0…0.5.
public struct WallOverlap: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The edge between two neighbours, `b` right of or below `a`: one set of values for both facing blend edges.
public struct SeamConfig: Codable, Equatable, Sendable {
    public var a: Int
    public var b: Int
    public var power: Double = 2
    public var gamma: Double = 2.2
    /// Per-channel gamma; nil = `gamma` for all three.
    public var gammaRGB: [Double]? = nil
    public init(a: Int, b: Int, power: Double = 2, gamma: Double = 2.2, gammaRGB: [Double]? = nil) {
        self.a = a
        self.b = b
        self.power = power
        self.gamma = gamma
        self.gammaRGB = gammaRGB
    }

    /// Power 0.1…10, gamma 0.5…5 (each of gammaRGB too), as `output.set` clamps a blend edge.
    public mutating func clamp() {
        power = power.clamped(0.1, 10)
        gamma = gamma.clamped(0.5, 5)
        gammaRGB = gammaRGB?.map { $0.clamped(0.5, 5) }
    }
}

/// A geometry field of one output that was edited by hand: the wall leaves it alone until it is reset.
public struct WallManualField: Codable, Equatable, Hashable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case source
        case overlapLeft = "overlap.left"
        case overlapRight = "overlap.right"
        case overlapTop = "overlap.top"
        case overlapBottom = "overlap.bottom"
    }
    public var output: Int
    public var field: Field
    public init(output: Int, field: Field) {
        self.output = output
        self.field = field
    }
}

public struct WallConfig: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var canvas: Int
    /// The part of the canvas the wall covers (normalized).
    public var rect: MapRect = .full
    public var cols: Int
    public var rows: Int
    /// Row-major, `cols × rows`; an output belongs to at most one wall.
    public var outputs: [Int]
    public var overlap: WallOverlap
    /// One per neighbouring pair (`WallLayout.seams`).
    public var seams: [SeamConfig] = []
    public var manual: [WallManualField] = []

    public init(id: Int, name: String, canvas: Int = 1, cols: Int, rows: Int, outputs: [Int], overlap: WallOverlap) {
        self.id = id
        self.name = name
        self.canvas = canvas
        self.cols = cols
        self.rows = rows
        self.outputs = outputs
        self.overlap = overlap
    }
}

/// A blend edge of an output in a wall.
enum WallEdge: CaseIterable {
    case left, right, top, bottom

    var path: WritableKeyPath<BlendSettings, BlendEdge> {
        switch self {
        case .left: \.left
        case .right: \.right
        case .top: \.top
        case .bottom: \.bottom
        }
    }

    var field: WallManualField.Field {
        switch self {
        case .left: .overlapLeft
        case .right: .overlapRight
        case .top: .overlapTop
        case .bottom: .overlapBottom
        }
    }
}

/// Edit-time compile of a wall into its outputs (DESIGN.md §9.9). Pure; the engine passes in what it knows of the
/// displays (`displayModes`: the current mode per display UUID).
public enum WallLayout {
    public struct Refusal: Error, Equatable, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    /// Checks the shape: 1…4 columns and rows, at least two projectors, one output per cell and each once, overlaps 0…0.5.
    public static func check(_ wall: WallConfig) throws {
        guard (1...4).contains(wall.cols), (1...4).contains(wall.rows), wall.cols * wall.rows >= 2 else {
            throw Refusal("a wall has 1–4 columns and 1–4 rows, and at least two projectors")
        }
        guard wall.outputs.count == wall.cols * wall.rows else {
            throw Refusal("a \(wall.cols) × \(wall.rows) wall needs \(wall.cols * wall.rows) outputs, row by row from the top left")
        }
        guard Set(wall.outputs).count == wall.outputs.count else { throw Refusal("each output can be in the wall once") }
        guard (0...0.5).contains(wall.overlap.x), (0...0.5).contains(wall.overlap.y) else {
            throw Refusal("overlap x and y must be 0–0.5 (a fraction of one projector)")
        }
    }

    /// Share of the wall one of `n` projectors covers along an axis: `1 / (n − (n − 1) · overlap)`.
    public static func share(_ n: Int, overlap: Double) -> Double { 1 / (Double(n) - Double(n - 1) * overlap) }

    /// Slice 1's source rectangle for the output in column `col`, row `row` (from 0).
    public static func source(_ wall: WallConfig, col: Int, row: Int) -> MapRect {
        let px = share(wall.cols, overlap: wall.overlap.x), py = share(wall.rows, overlap: wall.overlap.y)
        return MapRect(
            x: wall.rect.x + wall.rect.w * Double(col) * px * (1 - wall.overlap.x),
            y: wall.rect.y + wall.rect.h * Double(row) * py * (1 - wall.overlap.y),
            w: wall.rect.w * px, h: wall.rect.h * py)
    }

    /// An output's pixels: its region, else its desired display mode, else its display's current mode; nil when none is known.
    public static func pixelSize(of output: OutputConfig, displayModes: [String: DisplayModeConfig]) -> (width: Int, height: Int)? {
        if let r = output.region { return (r.w, r.h) }
        if let m = output.mode { return (m.width, m.height) }
        if let uuid = output.display?.uuid, let m = displayModes[uuid] { return (m.width, m.height) }
        return nil
    }

    /// The pixel size every output of the wall has; refused when one is missing, has no known size, or they differ (v1).
    public static func outputSize(of wall: WallConfig, outputs: [OutputConfig], displayModes: [String: DisplayModeConfig]) throws -> (width: Int, height: Int) {
        var first: (width: Int, height: Int, output: Int)?
        for id in wall.outputs {
            guard let output = outputs.first(where: { $0.id == id }) else { throw Refusal("no output \(id)") }
            guard let size = pixelSize(of: output, displayModes: displayModes) else {
                throw Refusal("output \(id) has no pixel size yet: bind it to a display, or set its region or display mode")
            }
            if let first, (first.width, first.height) != size {
                throw Refusal(
                    "the outputs of a wall need one pixel size: output \(first.output) is \(first.width) × \(first.height), output \(id) is \(size.width) × \(size.height)")
            }
            if first == nil { first = (size.width, size.height, id) }
        }
        guard let first else { throw Refusal("a wall needs outputs") }
        return (first.width, first.height)
    }

    /// Canvas size for `fit: "makeCanvas"`: `cols · w − (cols − 1) · overlap.x · w` by the same in height, rounded to even.
    /// A wall larger than `sides` allows is scaled down as a whole, so the canvas keeps the wall's shape; each side then
    /// stays within `sides`.
    public static func canvasSize(_ wall: WallConfig, output: (width: Int, height: Int), sides: ClosedRange<Int>) -> (width: Int, height: Int) {
        let w = Double(output.width) / share(wall.cols, overlap: wall.overlap.x)
        let h = Double(output.height) / share(wall.rows, overlap: wall.overlap.y)
        let scale = min(1, Double(sides.upperBound) / max(w, h))
        func even(_ v: Double) -> Int { min(sides.upperBound, max(sides.lowerBound, 2 * Int((v * scale / 2).rounded()))) }
        return (even(w), even(h))
    }

    /// The seams of a grid, row-major: each output with its right neighbour, then with the one below. A pair in `old`
    /// keeps its values; a new one starts at power 2, gamma 2.2.
    public static func seams(cols: Int, rows: Int, outputs: [Int], keeping old: [SeamConfig] = []) -> [SeamConfig] {
        var result: [SeamConfig] = []
        for i in outputs.indices {
            var neighbours: [Int] = []
            if i % cols + 1 < cols { neighbours.append(i + 1) }
            if i / cols + 1 < rows { neighbours.append(i + cols) }
            for j in neighbours where j < outputs.count {
                let a = outputs[i], b = outputs[j]
                result.append(old.first { $0.a == a && $0.b == b } ?? SeamConfig(a: a, b: b))
            }
        }
        return result
    }

    /// Writes the wall into its outputs: slice 1's canvas and source rectangle, each edge's overlap (inner edges
    /// `overlap × the output's width or height` in pixels, outer edges 0), and every seam (`applySeams`). Fields in
    /// `manual` and slices other than slice 1 stay as they are. Refused when the outputs' pixel size is unknown or differs.
    public static func apply(_ wall: WallConfig, to outputs: inout [OutputConfig], displayModes: [String: DisplayModeConfig]) throws {
        let size = try outputSize(of: wall, outputs: outputs, displayModes: displayModes)
        for (i, id) in wall.outputs.enumerated() {
            guard let o = outputs.firstIndex(where: { $0.id == id }) else { continue }
            let col = i % wall.cols, row = i / wall.cols
            let manual = Set(wall.manual.filter { $0.output == id }.map(\.field))
            if !manual.contains(.source), let s = outputs[o].slices.firstIndex(where: { $0.id == 1 }) {
                outputs[o].slices[s].canvas = wall.canvas
                outputs[o].slices[s].source = source(wall, col: col, row: row)
            }
            let x = wall.overlap.x * Double(size.width), y = wall.overlap.y * Double(size.height)
            let overlap: [WallEdge: Double] = [
                .left: col > 0 ? x : 0, .right: col < wall.cols - 1 ? x : 0, .top: row > 0 ? y : 0, .bottom: row < wall.rows - 1 ? y : 0,
            ]
            for edge in WallEdge.allCases where !manual.contains(edge.field) { outputs[o].blend[keyPath: edge.path].overlap = overlap[edge] ?? 0 }
        }
        applySeams(wall, to: &outputs)
    }

    /// Writes each seam's power, gamma and gammaRGB into both facing edges, so the two sides never disagree. Tuning only:
    /// no pixel size needed.
    public static func applySeams(_ wall: WallConfig, to outputs: inout [OutputConfig]) {
        for seam in wall.seams {
            guard let edges = facingEdges(seam, in: wall) else { continue }
            for (id, edge) in [(seam.a, edges.a), (seam.b, edges.b)] {
                guard let o = outputs.firstIndex(where: { $0.id == id }) else { continue }
                outputs[o].blend[keyPath: edge.path].power = seam.power
                outputs[o].blend[keyPath: edge.path].gamma = seam.gamma
                outputs[o].blend[keyPath: edge.path].gammaRGB = seam.gammaRGB
            }
        }
    }

    /// A hand edit of a wall output (`output.set`), with `outputs` already holding `new`: a changed slice 1 source
    /// (or canvas) or a changed inner overlap is added to `manual`; a changed power, gamma or gammaRGB of an inner edge
    /// goes to its seam and from there to the neighbour's facing edge. Returns the fields newly marked manual.
    public static func follow(edit new: OutputConfig, was old: OutputConfig, wall: inout WallConfig, outputs: inout [OutputConfig]) -> [WallManualField.Field] {
        var marked: [WallManualField.Field] = []
        func mark(_ field: WallManualField.Field) {
            let entry = WallManualField(output: new.id, field: field)
            guard !wall.manual.contains(entry) else { return }
            wall.manual.append(entry)
            marked.append(field)
        }
        if let before = old.slices.first(where: { $0.id == 1 }), let after = new.slices.first(where: { $0.id == 1 }),
            before.source != after.source || before.canvas != after.canvas
        {
            mark(.source)
        }
        for s in wall.seams.indices {
            guard let edges = facingEdges(wall.seams[s], in: wall) else { continue }
            let edge: WallEdge
            if wall.seams[s].a == new.id { edge = edges.a } else if wall.seams[s].b == new.id { edge = edges.b } else { continue }
            let before = old.blend[keyPath: edge.path], after = new.blend[keyPath: edge.path]
            if before.overlap != after.overlap { mark(edge.field) }
            if (before.power, before.gamma, before.gammaRGB) != (after.power, after.gamma, after.gammaRGB) {
                wall.seams[s].power = after.power
                wall.seams[s].gamma = after.gamma
                wall.seams[s].gammaRGB = after.gammaRGB
            }
        }
        applySeams(wall, to: &outputs)
        return marked
    }

    /// The edges a seam joins: a's right and b's left, or a's bottom and b's top; nil when they are not neighbours.
    static func facingEdges(_ seam: SeamConfig, in wall: WallConfig) -> (a: WallEdge, b: WallEdge)? {
        guard wall.cols > 0, let i = wall.outputs.firstIndex(of: seam.a), let j = wall.outputs.firstIndex(of: seam.b) else { return nil }
        if j == i + 1, i % wall.cols + 1 < wall.cols { return (.right, .left) }
        if j == i + wall.cols { return (.bottom, .top) }
        return nil
    }
}
