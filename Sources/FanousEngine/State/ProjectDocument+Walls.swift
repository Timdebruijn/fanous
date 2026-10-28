// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation

/// Projector walls (DESIGN.md §9.9): `/walls` in the project and the `wall.*` commands. `WallLayout` (Core) compiles a
/// wall into its outputs' slice 1 source and blend edges; `output.set` and `output.remove` follow a wall in
/// `ProjectDocument.registerCommands`.
extension ProjectDocument {
    /// The project's walls; a project saved before walls existed (or an unreadable list) has none.
    public static func walls(from project: JSONValue) -> [WallConfig] {
        guard let value = project["walls"], let data = try? JSONEncoder().encode(value) else { return [] }
        return (try? JSONDecoder().decode([WallConfig].self, from: data)) ?? []
    }

    static func setWalls(_ walls: [WallConfig], in project: inout JSONValue) throws {
        try project.set(try JSONValue(encoding: walls), at: "/walls")
    }

    static func registerWallCommands(
        on store: StateStore, showModeOn: @escaping @Sendable () -> Bool, displayModes: @escaping @Sendable () -> [String: DisplayModeConfig]
    ) {
        let geometry = "cols?: number; rows?: number; outputs?: number[]; overlap?: { x: number; y: number }; canvas?: number; name?: string"
        store.register(
            CommandSpec(
                name: "wall.add", role: .programmer,
                summary: "Make a projector wall of cols × rows outputs (row-major, 1–4 each, at least 2; an output in one wall at most) with an overlap fraction of one projector (0–0.5): computes slice 1's source and the inner blend overlaps, seams start at power 2, gamma 2.2. fit canvas uses the whole canvas; makeCanvas first sizes the canvas to the wall (as canvas.set, refused in show mode). Returns the new id.",
                argsType: "{ cols: number; rows: number; outputs: number[]; overlap: { x: number; y: number }; canvas?: number; fit: 'canvas' | 'makeCanvas'; name?: string }"
            ) { project, args in
                guard args["cols"] != nil, args["rows"] != nil, args["outputs"] != nil, args["overlap"] != nil, let fit = try fit(args) else {
                    throw CommandError.invalidArgs("args: { cols, rows, outputs, overlap: { x, y }, canvas?, fit: canvas | makeCanvas, name? }")
                }
                let id = (walls(from: project).map(\.id).max() ?? 0) + 1
                var wall = WallConfig(id: id, name: "Wall \(id)", cols: 0, rows: 0, outputs: [], overlap: WallOverlap(x: 0, y: 0))
                try applyGeometry(args, to: &wall)
                try storeWall(wall, fit: fit, in: &project, showModeOn: showModeOn(), displayModes: displayModes())
                return .number(Double(id))
            })
        store.register(
            CommandSpec(
                name: "wall.set", role: .programmer,
                summary: "Change a wall's geometry and compile it again; seams of pairs that stay keep their values. resetManual true gives every hand-edited field back to the wall, a list only those fields. fit as wall.add.",
                argsType: "{ id: number; \(geometry); fit?: 'canvas' | 'makeCanvas'; resetManual?: true | { output: number; field: 'source' | 'overlap.left' | 'overlap.right' | 'overlap.top' | 'overlap.bottom' }[] }"
            ) { project, args in
                guard let id = args["id"]?.int else { throw CommandError.invalidArgs("args: { id, cols?, rows?, outputs?, overlap?, canvas?, name?, fit?, resetManual? }") }
                guard var wall = walls(from: project).first(where: { $0.id == id }) else { throw CommandError.invalidArgs("no wall \(id)") }
                try applyGeometry(args, to: &wall)
                if let reset = args["resetManual"], reset != .bool(false) {
                    if reset == .bool(true) {
                        wall.manual = []
                    } else {
                        guard let list = reset.array else { throw CommandError.invalidArgs("resetManual must be true or a list of { output, field }") }
                        for entry in list {
                            guard let output = entry["output"]?.int, let field = entry["field"]?.string.flatMap(WallManualField.Field.init(rawValue:)) else {
                                throw CommandError.invalidArgs("resetManual entries are { output, field: source | overlap.left | overlap.right | overlap.top | overlap.bottom }")
                            }
                            wall.manual.removeAll { $0 == WallManualField(output: output, field: field) }
                        }
                    }
                }
                try storeWall(wall, fit: try fit(args), in: &project, showModeOn: showModeOn(), displayModes: displayModes())
                return nil
            })
        store.register(
            CommandSpec(
                name: "wall.seam", role: .programmer,
                summary: "Tune one seam of a wall (outputs a and b): power 0.1–10, gamma 0.5–5, gammaRGB [r, g, b] or null for gamma on all three; both facing edges follow.",
                argsType: "{ id: number; a: number; b: number; power?: number; gamma?: number; gammaRGB?: [number, number, number] | null }"
            ) { project, args in
                guard let id = args["id"]?.int, let a = args["a"]?.int, let b = args["b"]?.int else {
                    throw CommandError.invalidArgs("args: { id, a, b, power?, gamma?, gammaRGB? }")
                }
                guard var wall = walls(from: project).first(where: { $0.id == id }) else { throw CommandError.invalidArgs("no wall \(id)") }
                guard let s = wall.seams.firstIndex(where: { ($0.a, $0.b) == (a, b) || ($0.a, $0.b) == (b, a) }) else {
                    throw CommandError.invalidArgs("\(wall.name) has no seam between output \(a) and output \(b)")
                }
                try tune(&wall.seams[s], args)
                try storeSeams(wall, in: &project)
                return nil
            })
        store.register(
            CommandSpec(
                name: "wall.seams", role: .programmer,
                summary: "Tune every seam of a wall to the same values (as wall.seam).",
                argsType: "{ id: number; power?: number; gamma?: number; gammaRGB?: [number, number, number] | null }"
            ) { project, args in
                guard let id = args["id"]?.int else { throw CommandError.invalidArgs("args: { id, power?, gamma?, gammaRGB? }") }
                guard var wall = walls(from: project).first(where: { $0.id == id }) else { throw CommandError.invalidArgs("no wall \(id)") }
                for s in wall.seams.indices { try tune(&wall.seams[s], args) }
                try storeSeams(wall, in: &project)
                return nil
            })
        store.register(
            CommandSpec(name: "wall.remove", role: .programmer, summary: "Remove a wall; its outputs stay as they are.", argsType: "{ id: number }") { project, args in
                guard let id = args["id"]?.int else { throw CommandError.invalidArgs("args: { id }") }
                var walls = ProjectDocument.walls(from: project)
                guard walls.contains(where: { $0.id == id }) else { throw CommandError.invalidArgs("no wall \(id)") }
                walls.removeAll { $0.id == id }
                try setWalls(walls, in: &project)
                return nil
            })
    }

    /// `fit` of wall.add / wall.set, when given.
    static func fit(_ args: JSONValue) throws -> String? {
        guard let value = args["fit"] else { return nil }
        guard let fit = value.string, fit == "canvas" || fit == "makeCanvas" else { throw CommandError.invalidArgs("fit must be canvas or makeCanvas") }
        return fit
    }

    /// The geometry arguments present in `args` (checked as a whole by `storeWall`).
    static func applyGeometry(_ args: JSONValue, to wall: inout WallConfig) throws {
        func int(_ key: String) throws -> Int? {
            guard let value = args[key] else { return nil }
            guard let n = value.int else { throw CommandError.invalidArgs("\(key) must be a whole number") }
            return n
        }
        if let value = args["name"] {
            guard let name = value.string, !name.isEmpty else { throw CommandError.invalidArgs("name must be a string") }
            wall.name = name
        }
        if let n = try int("cols") { wall.cols = n }
        if let n = try int("rows") { wall.rows = n }
        if let n = try int("canvas") { wall.canvas = n }
        if let value = args["outputs"] {
            guard let list = value.array, case let ids = list.compactMap(\.int), ids.count == list.count else {
                throw CommandError.invalidArgs("outputs must be a list of output ids, row by row from the top left")
            }
            wall.outputs = ids
        }
        if let value = args["overlap"] {
            guard let x = value["x"]?.double, let y = value["y"]?.double else { throw CommandError.invalidArgs("overlap must be { x, y }, fractions of one projector") }
            wall.overlap = WallOverlap(x: x, y: y)
        }
    }

    /// power, gamma and gammaRGB of wall.seam / wall.seams, clamped as `output.set` clamps a blend edge.
    static func tune(_ seam: inout SeamConfig, _ args: JSONValue) throws {
        if let value = args["power"] {
            guard let power = value.double else { throw CommandError.invalidArgs("power must be a number") }
            seam.power = power
        }
        if let value = args["gamma"] {
            guard let gamma = value.double else { throw CommandError.invalidArgs("gamma must be a number") }
            seam.gamma = gamma
        }
        if let value = args["gammaRGB"] {
            if value == .null {
                seam.gammaRGB = nil
            } else {
                guard let list = value.array, case let rgb = list.compactMap(\.double), rgb.count == 3, list.count == 3 else {
                    throw CommandError.invalidArgs("gammaRGB must be [r, g, b] or null")
                }
                seam.gammaRGB = rgb
            }
        }
        seam.clamp()
    }

    /// Checks `wall`, sizes its canvas for `fit` "makeCanvas" (canvas.set's path), compiles it into the outputs and stores
    /// it in place of the wall with its id, or as a new one. Seams are rebuilt for the grid, keeping the values of pairs
    /// that stay; manual entries of outputs that left the wall go.
    static func storeWall(_ wall: WallConfig, fit: String?, in project: inout JSONValue, showModeOn: Bool, displayModes: [String: DisplayModeConfig]) throws {
        var wall = wall
        var outputs = ProjectDocument.outputs(from: project)
        var walls = ProjectDocument.walls(from: project)
        do {
            try WallLayout.check(wall)
            for id in wall.outputs {
                guard outputs.contains(where: { $0.id == id }) else { throw CommandError.invalidArgs("no output \(id)") }
                if let other = walls.first(where: { $0.id != wall.id && $0.outputs.contains(id) }) {
                    throw CommandError.invalidArgs("output \(id) is already in \(other.name)")
                }
            }
            var canvases = ProjectDocument.canvases(from: project)
            guard let c = canvases.firstIndex(where: { $0.id == wall.canvas }) else { throw CommandError.invalidArgs("no canvas \(wall.canvas)") }
            wall.seams = WallLayout.seams(cols: wall.cols, rows: wall.rows, outputs: wall.outputs, keeping: wall.seams)
            wall.manual.removeAll { !wall.outputs.contains($0.output) }
            if fit != nil { wall.rect = .full }
            if fit == "makeCanvas" {
                let output = try WallLayout.outputSize(of: wall, outputs: outputs, displayModes: displayModes)
                let size = WallLayout.canvasSize(wall, output: output, sides: canvasSides)
                try resize(&canvases, at: c, to: (size.width, size.height, canvases[0].fps), showModeOn: showModeOn)
                try project.set(try JSONValue(encoding: canvases), at: "/canvases")
            }
            try WallLayout.apply(wall, to: &outputs, displayModes: displayModes)
        } catch let refusal as WallLayout.Refusal {
            throw CommandError.invalidArgs(refusal.message)
        }
        for o in outputs.indices where wall.outputs.contains(outputs[o].id) { try validate(&outputs[o]) }
        try setOutputs(outputs, in: &project)
        if let w = walls.firstIndex(where: { $0.id == wall.id }) { walls[w] = wall } else { walls.append(wall) }
        try setWalls(walls, in: &project)
    }

    /// Writes the wall's seams into its outputs and stores the wall (tuning only: no pixel size needed).
    static func storeSeams(_ wall: WallConfig, in project: inout JSONValue) throws {
        var outputs = ProjectDocument.outputs(from: project)
        WallLayout.applySeams(wall, to: &outputs)
        try setOutputs(outputs, in: &project)
        var walls = ProjectDocument.walls(from: project)
        if let w = walls.firstIndex(where: { $0.id == wall.id }) { walls[w] = wall }
        try setWalls(walls, in: &project)
    }
}
