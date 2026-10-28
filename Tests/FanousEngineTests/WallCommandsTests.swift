// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Synchronization
import Testing

@testable import FanousEngine

/// The `wall.*` commands and what `output.set` / `output.remove` do to a wall's outputs (DESIGN.md §9.9).
struct WallCommandsTests {
    final class Machine: Sendable {
        let showMode = Mutex(false)
        let displays = Mutex<[String: DisplayModeConfig]>([:])
    }

    /// A store with `outputs` outputs of 1920 × 1080 (a region each).
    static func makeStore(outputs: Int) throws -> (StateStore, Machine) {
        let logger = Logger(label: "test")
        let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: logger)
        let store = StateStore(project: ProjectDocument.initial(patch: .standard(layers: 2, outputs: 1), layerCount: 2, libraryRoot: "/tmp/lib", policy: .dmx), logger: logger)
        let machine = Machine()
        ProjectDocument.registerCommands(
            on: store, auth: auth, showModeOn: { machine.showMode.withLock { $0 } }, displayModes: { machine.displays.withLock { $0 } })
        for id in 1...outputs {
            _ = try store.execute("output.add", role: .programmer).get()
            _ = try store.execute("output.set", args: ["id": .number(Double(id)), "path": "/region", "value": ["x": 0, "y": 0, "w": 1920, "h": 1080]], role: .programmer).get()
        }
        return (store, machine)
    }

    static func output(_ store: StateStore, _ id: Int) -> OutputConfig { ProjectDocument.outputs(from: store.project).first { $0.id == id }! }
    static func add(_ store: StateStore, _ outputs: [Int], cols: Int, rows: Int, overlap: Double = 0.2, fit: String = "canvas") -> Result<CommandResult, CommandError> {
        store.execute(
            "wall.add",
            args: ["cols": .number(Double(cols)), "rows": .number(Double(rows)), "outputs": .array(outputs.map { .number(Double($0)) }), "overlap": ["x": .number(overlap), "y": .number(overlap)], "fit": .string(fit)],
            role: .programmer)
    }

    @Test func wallAddCompilesTheOutputsInOneUndoStep() throws {
        let (store, _) = try Self.makeStore(outputs: 2)
        let before = ProjectDocument.outputs(from: store.project)
        let depth = store.historyDepth.undo
        #expect(try Self.add(store, [1, 2], cols: 2, rows: 1).get().value == 1)
        let wall = try #require(ProjectDocument.walls(from: store.project).first)
        #expect(wall.name == "Wall 1" && wall.canvas == 1 && wall.rect == .full && wall.manual.isEmpty)
        #expect(wall.seams == [SeamConfig(a: 1, b: 2)])
        #expect(abs(Self.output(store, 2).slices[0].source.x - 4.0 / 9) < 1e-9)
        #expect(Self.output(store, 1).blend.right.overlap == 384 && Self.output(store, 2).blend.left.overlap == 384)
        #expect(store.historyDepth.undo == depth + 1)
        _ = try store.execute("undo", role: .programmer).get()
        #expect(ProjectDocument.walls(from: store.project).isEmpty)
        #expect(ProjectDocument.outputs(from: store.project) == before)
    }

    @Test func makeCanvasSizesTheCanvasLikeCanvasSet() throws {
        let (store, machine) = try Self.makeStore(outputs: 2)
        machine.showMode.withLock { $0 = true }
        #expect(Self.add(store, [1, 2], cols: 2, rows: 1, fit: "makeCanvas").failureCode == "showMode")
        machine.showMode.withLock { $0 = false }
        _ = try Self.add(store, [1, 2], cols: 2, rows: 1, fit: "makeCanvas").get()
        var canvas = try #require(ProjectDocument.canvases(from: store.project).first)
        #expect((canvas.width, canvas.height, canvas.fps) == (3456, 1080, 60), "2 × 1920 − 0.2 × 1920")
        _ = try store.execute("undo", role: .programmer).get()
        canvas = try #require(ProjectDocument.canvases(from: store.project).first)
        #expect((canvas.width, canvas.height) == (1920, 1080), "the canvas comes back with the same undo step")
        machine.showMode.withLock { $0 = true }
        _ = try Self.add(store, [1, 2], cols: 2, rows: 1, fit: "canvas").get()  // only outputs change: fine in show mode
    }

    @Test func refusals() throws {
        let (store, machine) = try Self.makeStore(outputs: 4)
        #expect(Self.add(store, [1, 2], cols: 2, rows: 1).failureCode == nil)
        #expect(Self.add(store, [2, 3], cols: 2, rows: 1) == .failure(.invalidArgs("output 2 is already in Wall 1")))
        #expect(Self.add(store, [3, 9], cols: 2, rows: 1) == .failure(.invalidArgs("no output 9")))
        #expect(Self.add(store, [3, 4, 5], cols: 3, rows: 1) == .failure(.invalidArgs("no output 5")))
        #expect(Self.add(store, [3, 4], cols: 2, rows: 2) == .failure(.invalidArgs("a 2 × 2 wall needs 4 outputs, row by row from the top left")))
        #expect(Self.add(store, [3, 4], cols: 2, rows: 1, overlap: 15).failureCode == "invalidArgs")
        #expect(Self.add(store, [3, 4], cols: 2, rows: 1, fit: "stretch") == .failure(.invalidArgs("fit must be canvas or makeCanvas")))
        _ = try store.execute("output.set", args: ["id": 4, "path": "/region", "value": .null], role: .programmer).get()
        #expect(Self.add(store, [3, 4], cols: 2, rows: 1) == .failure(.invalidArgs("output 4 has no pixel size yet: bind it to a display, or set its region or display mode")))
        // bound to a display: its current mode, as the engine reports it
        _ = try store.execute("output.set", args: ["id": 4, "path": "/display", "value": ["uuid": "U4", "name": "Epson"]], role: .programmer).get()
        machine.displays.withLock { $0 = ["U4": DisplayModeConfig(width: 1920, height: 1200, hz: 60)] }
        #expect(Self.add(store, [3, 4], cols: 2, rows: 1).failureMessage?.hasPrefix("the outputs of a wall need one pixel size") == true)
        machine.displays.withLock { $0 = ["U4": DisplayModeConfig(width: 1920, height: 1080, hz: 60)] }
        #expect(Self.add(store, [3, 4], cols: 2, rows: 1).failureCode == nil)

        #expect(Self.add(store, [1, 2], cols: 2, rows: 1).failureCode == "invalidArgs")
        #expect(store.execute("wall.remove", args: ["id": 1], role: .operator) == .failure(.forbidden))
        _ = try store.execute("show.lock", role: .programmer).get()
        for name in ["wall.add", "wall.set", "wall.seam", "wall.seams", "wall.remove"] {
            #expect(store.execute(name, args: ["id": 1], role: .programmer) == .failure(.showLocked))
        }
    }

    @Test func wallSetRecompilesKeepsSeamsAndResetsManualFields() throws {
        let (store, _) = try Self.makeStore(outputs: 3)
        _ = try Self.add(store, [1, 2], cols: 2, rows: 1).get()
        _ = try store.execute("wall.seam", args: ["id": 1, "a": 1, "b": 2, "gamma": 1.8], role: .programmer).get()
        // hand edits: the reply names the field that became manual
        let reply = try store.execute("output.set", args: ["id": 1, "path": "/blend/right/overlap", "value": 300], role: .programmer).get().value
        #expect(reply == ["wall": 1, "manual": ["overlap.right"]])
        #expect(try store.execute("output.set", args: ["id": 2, "path": "/slices/0/source/x", "value": 0.5], role: .programmer).get().value == ["wall": 1, "manual": ["source"]])
        #expect(try store.execute("output.set", args: ["id": 1, "path": "/name", "value": "Left"], role: .programmer).get().value == nil)

        _ = try store.execute("wall.set", args: ["id": 1, "overlap": ["x": 0.1, "y": 0.1], "name": "Stage"], role: .programmer).get()
        #expect(Self.output(store, 1).blend.right.overlap == 300, "manual")
        #expect(Self.output(store, 2).blend.left.overlap == 192, "0.1 × 1920")
        #expect(Self.output(store, 2).slices[0].source.x == 0.5)
        _ = try store.execute("wall.set", args: ["id": 1, "resetManual": [["output": 2, "field": "source"]]], role: .programmer).get()
        #expect(abs(Self.output(store, 2).slices[0].source.x - (1 / 1.9) * 0.9) < 1e-9)
        #expect(ProjectDocument.walls(from: store.project)[0].manual == [WallManualField(output: 1, field: .overlapRight)])
        _ = try store.execute("wall.set", args: ["id": 1, "resetManual": true], role: .programmer).get()
        #expect(Self.output(store, 1).blend.right.overlap == 192)

        // a third projector: the old pair keeps its tuning, the new one starts at the defaults
        _ = try store.execute("wall.set", args: ["id": 1, "cols": 3, "outputs": [1, 2, 3]], role: .programmer).get()
        let wall = ProjectDocument.walls(from: store.project)[0]
        #expect(wall.name == "Stage" && wall.seams == [SeamConfig(a: 1, b: 2, gamma: 1.8), SeamConfig(a: 2, b: 3)])
        #expect(Self.output(store, 2).blend.right.overlap == 192 && Self.output(store, 3).blend.left.gamma == 2.2)
        #expect(store.execute("wall.set", args: ["id": 2], role: .programmer) == .failure(.invalidArgs("no wall 2")))
        #expect(store.execute("wall.set", args: ["id": 1, "resetManual": "all"], role: .programmer).failureCode == "invalidArgs")
    }

    @Test func seamsTuneBothSidesAndEditsOfOneSideFollow() throws {
        let (store, _) = try Self.makeStore(outputs: 4)
        _ = try Self.add(store, [1, 2, 3, 4], cols: 2, rows: 2).get()
        _ = try store.execute("wall.seam", args: ["id": 1, "a": 3, "b": 1, "power": 3, "gammaRGB": [2, 2.2, 9]], role: .programmer).get()
        #expect(Self.output(store, 1).blend.bottom.gammaRGB == [2, 2.2, 5], "clamped like output.set")
        #expect(Self.output(store, 3).blend.top.power == 3 && Self.output(store, 3).blend.top.gammaRGB == [2, 2.2, 5])
        #expect(Self.output(store, 1).blend.right.power == 2, "other seams untouched")
        #expect(store.execute("wall.seam", args: ["id": 1, "a": 1, "b": 4], role: .programmer) == .failure(.invalidArgs("Wall 1 has no seam between output 1 and output 4")))
        #expect(store.execute("wall.seam", args: ["id": 1, "a": 1, "b": 2, "gammaRGB": [2, 2]], role: .programmer).failureCode == "invalidArgs")

        _ = try store.execute("wall.seams", args: ["id": 1, "gamma": 2.4, "gammaRGB": .null], role: .programmer).get()
        let wall = ProjectDocument.walls(from: store.project)[0]
        #expect(wall.seams.allSatisfy { $0.gamma == 2.4 && $0.gammaRGB == nil })
        #expect(ProjectDocument.outputs(from: store.project).allSatisfy { o in
            let inner = [o.id == 2 || o.id == 4 ? o.blend.left : o.blend.right, o.id <= 2 ? o.blend.bottom : o.blend.top]
            return inner.allSatisfy { $0.gamma == 2.4 && $0.gammaRGB == nil }
        })

        // editing one side of a seam through output.set: the other side follows, one undo step for both
        #expect(try store.execute("output.set", args: ["id": 4, "path": "/blend/left/gamma", "value": 1.9], role: .programmer).get().value == nil)
        #expect(Self.output(store, 3).blend.right.gamma == 1.9)
        #expect(ProjectDocument.walls(from: store.project)[0].seams.first { $0.a == 3 && $0.b == 4 }?.gamma == 1.9)
        _ = try store.execute("undo", role: .programmer).get()
        #expect(Self.output(store, 3).blend.right.gamma == 2.4 && Self.output(store, 4).blend.left.gamma == 2.4)
        #expect(ProjectDocument.walls(from: store.project)[0].seams.allSatisfy { $0.gamma == 2.4 })
    }

    @Test func wallOutputsStayUntilTheWallIsRemoved() throws {
        let (store, _) = try Self.makeStore(outputs: 2)
        _ = try Self.add(store, [1, 2], cols: 2, rows: 1).get()
        #expect(store.execute("output.remove", args: ["id": 2], role: .programmer) == .failure(.invalidArgs("output 2 is part of Wall 1; remove the wall first (its outputs stay as they are)")))
        let compiled = ProjectDocument.outputs(from: store.project)
        _ = try store.execute("wall.remove", args: ["id": 1], role: .programmer).get()
        #expect(ProjectDocument.walls(from: store.project).isEmpty && ProjectDocument.outputs(from: store.project) == compiled)
        #expect(store.execute("wall.remove", args: ["id": 1], role: .programmer) == .failure(.invalidArgs("no wall 1")))
        _ = try store.execute("output.remove", args: ["id": 2], role: .programmer).get()
    }

    @Test func wallsLoadFromOldProjectsAndFollowARemovedCanvas() throws {
        let (store, _) = try Self.makeStore(outputs: 2)
        _ = try store.execute("canvas.add", args: ["width": 1920, "height": 1080], role: .programmer).get()
        _ = try store.execute("wall.add", args: ["cols": 2, "rows": 1, "outputs": [1, 2], "overlap": ["x": 0.15, "y": 0], "canvas": 2, "fit": "canvas"], role: .programmer).get()
        #expect(Self.output(store, 1).slices[0].canvas == 2)
        _ = try store.execute("canvas.remove", args: ["id": 2], role: .programmer).get()
        #expect(ProjectDocument.walls(from: store.project)[0].canvas == 1 && Self.output(store, 1).slices[0].canvas == 1)

        var old = store.project
        try old.remove(at: "/walls")
        let file = FileManager.default.temporaryDirectory.appending(path: "walls-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try ProjectDocument.save(old, to: file)
        let loaded = try #require(ProjectDocument.load(from: file))
        #expect(loaded["walls"] == [] && ProjectDocument.walls(from: loaded).isEmpty)
    }

    /// A stored wall without `manual` or `seams` (hand-edited) loads with the defaults; an unreadable one is skipped
    /// and reported while the others stay, so the next wall command does not wipe them.
    @Test func wallsAreReadOneByOne() throws {
        let (store, _) = try Self.makeStore(outputs: 4)
        var project = store.project
        try project.set(
            [
                ["id": 1, "name": "Left", "cols": 2, "rows": 1, "outputs": [1, 2], "overlap": ["x": 0.15, "y": 0]],
                ["id": 2, "cols": "two"],
            ], at: "/walls")
        let (walls, issues) = ProjectDocument.wallEntries(from: project)
        #expect(walls.map(\.id) == [1] && walls[0].name == "Left" && walls[0].seams == [SeamConfig(a: 1, b: 2)] && walls[0].manual.isEmpty)
        #expect(issues.count == 1 && issues[0].hasPrefix("walls[1] cannot be read"))
        store.replaceProject(project)
        _ = try Self.add(store, [3, 4], cols: 2, rows: 1).get()
        #expect(ProjectDocument.walls(from: store.project).map(\.name) == ["Left", "Wall 2"])
        _ = try store.execute("wall.seam", args: ["id": 1, "a": 1, "b": 2, "gamma": 2], role: .programmer).get()
        #expect(Self.output(store, 2).blend.left.gamma == 2)
    }

    /// `wall.set {id, name}` renames without compiling, so it works while a projector is unplugged; anything more compiles.
    @Test func renameNeedsNoPixelSize() throws {
        let (store, _) = try Self.makeStore(outputs: 2)
        _ = try Self.add(store, [1, 2], cols: 2, rows: 1).get()
        _ = try store.execute("output.set", args: ["id": 2, "path": "/region", "value": .null], role: .programmer).get()
        _ = try store.execute("wall.set", args: ["id": 1, "name": "Stage"], role: .programmer).get()
        #expect(ProjectDocument.walls(from: store.project)[0].name == "Stage")
        #expect(store.execute("wall.set", args: ["id": 1, "name": "Back"], role: .programmer).failureCode == nil)
        #expect(store.execute("wall.set", args: ["id": 1, "name": "X", "overlap": ["x": 0.1, "y": 0.1]], role: .programmer).failureMessage?.hasPrefix("output 2 has no pixel size") == true)
        #expect(store.execute("wall.set", args: ["id": 1, "name": ""], role: .programmer).failureCode == "invalidArgs")
    }

    /// 3 × 3 UHD at 15 % is 10368 × 5832; with canvas 2 (1920 × 1080) next to it the budget is 4 × UHD − 2 073 600 pixels,
    /// so makeCanvas scales canvas 1 to 7436 × 4182 instead of refusing.
    @Test func makeCanvasStaysWithinThePixelBudget() throws {
        let (store, _) = try Self.makeStore(outputs: 9)
        for id in 1...9 {
            _ = try store.execute("output.set", args: ["id": .number(Double(id)), "path": "/region", "value": ["x": 0, "y": 0, "w": 3840, "h": 2160]], role: .programmer).get()
        }
        _ = try store.execute("canvas.add", args: ["width": 1920, "height": 1080], role: .programmer).get()
        _ = try Self.add(store, Array(1...9), cols: 3, rows: 3, overlap: 0.15, fit: "makeCanvas").get()
        let canvases = ProjectDocument.canvases(from: store.project)
        #expect((canvases[0].width, canvases[0].height) == (7436, 4182))
        #expect(canvases.reduce(0) { $0 + $1.width * $1.height } <= ProjectDocument.maxCanvasPixels)
    }

    /// Seam sliders: calls from one client on the same seam and fields within 1 s are one undo step; another field is not.
    @Test func seamDragsUndoAsOneStep() throws {
        let (store, _) = try Self.makeStore(outputs: 2)
        _ = try Self.add(store, [1, 2], cols: 2, rows: 1).get()
        let client = RecordingClient(role: .programmer)
        let depth = store.historyDepth.undo
        _ = try store.execute("wall.seam", args: ["id": 1, "a": 1, "b": 2, "gamma": 2.0], role: .programmer, from: client).get()
        _ = try store.execute("wall.seam", args: ["id": 1, "a": 2, "b": 1, "gamma": 1.8], role: .programmer, from: client).get()
        _ = try store.execute("wall.seam", args: ["id": 1, "a": 1, "b": 2, "power": 3], role: .programmer, from: client).get()
        _ = try store.execute("wall.seams", args: ["id": 1, "power": 2.5], role: .programmer, from: client).get()
        _ = try store.execute("wall.seams", args: ["id": 1, "power": 2.6], role: .programmer, from: client).get()
        #expect(store.historyDepth.undo == depth + 3)
        _ = try store.execute("undo", role: .programmer).get()
        #expect(Self.output(store, 1).blend.right.power == 3, "both wall.seams steps undone at once")
        _ = try store.execute("undo", role: .programmer).get()
        #expect(Self.output(store, 1).blend.right.power == 2 && Self.output(store, 1).blend.right.gamma == 1.8, "power separate from gamma")
        _ = try store.execute("undo", role: .programmer).get()
        #expect(Self.output(store, 1).blend.right.gamma == 2.2 && Self.output(store, 2).blend.left.gamma == 2.2, "both gamma edits in one step")
    }
}

extension Result where Failure == CommandError {
    var failureMessage: String? {
        if case .failure(let error) = self { return error.message }
        return nil
    }
}
