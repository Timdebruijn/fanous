// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Synchronization
import Testing

@testable import FanousEngine

/// `output.preset.*` and the Compare lease `output.show` (DESIGN.md §9.10 item 3).
struct PresetCommandsTests {
    final class Machine: Sendable {
        let showMode = Mutex(false)
        let shown = Mutex<[([Int], Int)]>([])
    }

    /// A store with `outputs` outputs of 1920 × 1080 (a region each); `output.show` calls land in `Machine.shown`.
    static func makeStore(outputs: Int) throws -> (StateStore, Machine) {
        let logger = Logger(label: "test")
        let store = StateStore(project: ProjectDocument.initial(patch: .standard(layers: 2, outputs: 1), layerCount: 2, libraryRoot: "/tmp/lib", policy: .dmx), logger: logger)
        let machine = Machine()
        ProjectDocument.registerCommands(
            on: store, auth: RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: logger), showModeOn: { machine.showMode.withLock { $0 } },
            showPreset: { ids, preset in machine.shown.withLock { $0.append((ids, preset)) } })
        for id in 1...outputs {
            _ = try store.execute("output.add", role: .programmer).get()
            _ = try store.execute("output.set", args: ["id": .number(Double(id)), "path": "/region", "value": ["x": 0, "y": 0, "w": 1920, "h": 1080]], role: .programmer).get()
        }
        return (store, machine)
    }

    static func output(_ store: StateStore, _ id: Int) -> OutputConfig { WallCommandsTests.output(store, id) }
    static func run(_ store: StateStore, _ name: String, _ args: JSONValue, role: Role = .programmer) -> Result<CommandResult, CommandError> {
        store.execute(name, args: args, role: role)
    }
    static func corner(_ store: StateStore, _ x: Double) throws {
        _ = try run(store, "output.set", ["id": 1, "path": "/warp/cornerPin/0", "value": ["x": .number(x), "y": 0]]).get()
    }

    @Test func storeReplaceRecallRenameRemove() throws {
        let (store, _) = try Self.makeStore(outputs: 1)
        try Self.corner(store, 0.1)
        var depth = store.historyDepth.undo
        #expect(try Self.run(store, "output.preset.store", ["ids": [1], "number": 2]).get().value == nil)
        #expect(store.historyDepth.undo == depth + 1)
        #expect(Self.output(store, 1).presets.map(\.name) == ["Preset 2"])
        #expect(Self.output(store, 1).preset(2)?.warp.cornerPin[0] == MapPoint(0.1, 0))

        // the same number again replaces it, and says so
        try Self.corner(store, 0.2)
        #expect(try Self.run(store, "output.preset.store", ["ids": [1], "number": 2, "name": "Wide"]).get().value == ["replaced": [1]])
        #expect(Self.output(store, 1).presets.count == 1 && Self.output(store, 1).preset(2)?.name == "Wide")

        // recall is an edit of the mapping: one undo step, and Undo takes it back
        try Self.corner(store, 0.3)
        depth = store.historyDepth.undo
        #expect(try Self.run(store, "output.preset.recall", ["ids": [1], "number": 2]).get().value == nil)
        #expect(Self.output(store, 1).warp.cornerPin[0] == MapPoint(0.2, 0))
        #expect(store.historyDepth.undo == depth + 1)
        _ = try store.execute("undo", role: .programmer).get()
        #expect(Self.output(store, 1).warp.cornerPin[0] == MapPoint(0.3, 0) && Self.output(store, 1).presets.count == 1)

        _ = try Self.run(store, "output.preset.rename", ["ids": [1], "number": 2, "name": "  Stage left "]).get()
        #expect(Self.output(store, 1).preset(2)?.name == "Stage left")
        _ = try Self.run(store, "output.preset.remove", ["ids": [1], "number": 2]).get()
        #expect(Self.output(store, 1).presets.isEmpty)
        #expect(!(store.project["outputs"]?[0]?.object?.keys.contains("presets") ?? true), "no presets, no key: saved as before")
    }

    /// A wall stores and recalls all its outputs in one call: one undo step.
    @Test func severalIdsAreOneUndoStep() throws {
        let (store, _) = try Self.makeStore(outputs: 2)
        let depth = store.historyDepth.undo
        _ = try Self.run(store, "output.preset.store", ["ids": [1, 2], "number": 1]).get()
        #expect(store.historyDepth.undo == depth + 1)
        #expect(Self.output(store, 1).preset(1) != nil && Self.output(store, 2).preset(1) != nil)
        _ = try Self.run(store, "output.preset.store", ["ids": [2], "number": 9]).get()
        #expect(Self.run(store, "output.preset.recall", ["ids": [1, 2], "number": 9]) == .failure(.invalidArgs("Output 1 has no preset 9")), "all or nothing")
        _ = try store.execute("undo", role: .programmer).get()
        _ = try store.execute("undo", role: .programmer).get()
        #expect(Self.output(store, 1).presets.isEmpty && Self.output(store, 2).presets.isEmpty)
    }

    @Test func refusals() throws {
        let (store, machine) = try Self.makeStore(outputs: 1)
        _ = try Self.run(store, "output.preset.store", ["ids": [1], "number": 1]).get()
        func refused(_ name: String, _ args: JSONValue) -> Bool {
            if case .failure(let error) = Self.run(store, name, args) { return error.code == "invalidArgs" }
            return false
        }
        #expect(refused("output.set", ["id": 1, "path": "/presets", "value": []]))
        #expect(refused("output.set", ["id": 1, "path": "/presets/0/name", "value": "x"]))
        #expect(refused("output.preset.store", ["ids": [1], "number": 0]) && refused("output.preset.store", ["ids": [1], "number": 256]))
        #expect(refused("output.preset.store", ["ids": [1]]) && refused("output.preset.store", ["ids": [1], "number": 1.5]))
        #expect(refused("output.preset.store", ["ids": [], "number": 1]) && refused("output.preset.store", ["ids": [7], "number": 1]))
        #expect(refused("output.preset.store", ["ids": [1, 1], "number": 1]))
        #expect(refused("output.preset.store", ["ids": [1], "number": 1, "name": "   "]))
        #expect(refused("output.preset.rename", ["ids": [1], "number": 1, "name": .string(String(repeating: "x", count: 65))]))
        #expect(refused("output.preset.rename", ["ids": [1], "number": 1]))
        #expect(refused("output.preset.remove", ["ids": [1], "number": 4]) && refused("output.preset.recall", ["ids": [1], "number": 4]))
        #expect(refused("output.show", ["ids": [1], "preset": 256]))
        #expect(Self.run(store, "output.preset.store", ["ids": [1], "number": 2], role: .operator) == .failure(.forbidden))
        #expect(Self.run(store, "output.show", ["ids": [1], "preset": 1], role: .operator) == .failure(.forbidden))
        machine.showMode.withLock { $0 = true }
        #expect(Self.run(store, "output.show", ["ids": [1], "preset": 1]) == .failure(CommandError("showMode", "Compare is off in show mode")), "show mode ends Compare, so it cannot start")
        #expect((try? Self.run(store, "output.show", ["ids": [1], "preset": 0]).get()) != nil, "ending is fine")
        machine.showMode.withLock { $0 = false }
        _ = try store.execute("show.lock", role: .programmer).get()
        for (name, args) in [
            ("output.preset.store", ["ids": [1], "number": 3]), ("output.preset.recall", ["ids": [1], "number": 1]),
            ("output.preset.rename", ["ids": [1], "number": 1, "name": "x"]), ("output.preset.remove", ["ids": [1], "number": 1]),
            ("output.show", ["ids": [1], "preset": 1]),
        ] as [(String, JSONValue)] {
            #expect(Self.run(store, name, args) == .failure(.showLocked), "\(name)")
        }
    }

    /// Recall on a wall output: a slice 1 source that differs from the wall's becomes manual, as with output.set.
    @Test func aWallRecallMarksSliceOneManual() throws {
        let (store, _) = try Self.makeStore(outputs: 2)
        _ = try WallCommandsTests.add(store, [1, 2], cols: 2, rows: 1, overlap: 0.2).get()
        _ = try Self.run(store, "output.preset.store", ["ids": [1, 2], "number": 1]).get()
        _ = try Self.run(store, "wall.set", ["id": 1, "overlap": ["x": 0.1, "y": 0.1]]).get()
        let wallSource = Self.output(store, 2).slices[0].source
        #expect(wallSource != Self.output(store, 2).preset(1)?.slices[0].source, "the wall moved on; the preset did not")
        let reply = try Self.run(store, "output.preset.recall", ["ids": [1, 2], "number": 1]).get().value
        #expect(reply?["manual"]?.array?.count == 2 && reply?["manual"]?[0] == ["wall": 1, "output": 1, "field": "source"])
        let wall = try #require(ProjectDocument.walls(from: store.project).first)
        #expect(Set(wall.manual.map(\.output)) == [1, 2] && wall.manual.allSatisfy { $0.field == .source })
        #expect(Self.output(store, 2).slices[0].source == Self.output(store, 2).preset(1)?.slices[0].source)
    }

    /// Compare is a lease on the DMX side: no project change, no undo step.
    @Test func compareGoesToTheDMXSideOnly() throws {
        let (store, machine) = try Self.makeStore(outputs: 2)
        let (rev, depth) = (store.rev, store.historyDepth.undo)
        _ = try Self.run(store, "output.show", ["ids": [1, 2], "preset": 4]).get()
        _ = try Self.run(store, "output.show", ["ids": [2], "preset": 0]).get()
        #expect(machine.shown.withLock { $0.map(\.0) } == [[1, 2], [2]] && machine.shown.withLock { $0.map(\.1) } == [4, 0])
        #expect(store.rev == rev && store.historyDepth.undo == depth)
    }

    /// A removed canvas takes the preset slices on it to canvas 1 too, in the same step.
    @Test func canvasRemoveMovesPresetSlices() throws {
        let (store, _) = try Self.makeStore(outputs: 1)
        _ = try Self.run(store, "canvas.add", ["width": 1280, "height": 720]).get()
        _ = try Self.run(store, "output.set", ["id": 1, "path": "/slices/0/canvas", "value": 2]).get()
        _ = try Self.run(store, "output.preset.store", ["ids": [1], "number": 1]).get()
        _ = try Self.run(store, "canvas.remove", ["id": 2]).get()
        #expect(Self.output(store, 1).slices[0].canvas == 1 && Self.output(store, 1).preset(1)?.slices[0].canvas == 1)
    }

    /// A preset that does not validate (a hand-edited or foreign file) is refused at recall instead of landing in the
    /// edited mapping past `validate`.
    @Test func recallRefusesAPresetThatDoesNotValidate() throws {
        let (store, _) = try Self.makeStore(outputs: 1)
        var output = Self.output(store, 1)
        output.storePreset(4, name: nil)
        output.presets[0].slices[0].dest.removeLast()  // 3 points
        store.correct(try JSONValue(encoding: [output]), at: "/outputs")
        let depth = store.historyDepth.undo
        #expect(Self.run(store, "output.preset.recall", ["ids": [1], "number": 4]) == .failure(.invalidArgs("preset 4 of Output 1 cannot be recalled: slice dest needs 4 points")))
        #expect(Self.output(store, 1).slices[0].dest.count == 4 && store.historyDepth.undo == depth)
    }

    /// Loading a hand-edited or foreign file keeps the presets the engine draws: numbers 1–255, the first of a repeated
    /// number. The UI then offers the same list (`ProjectDocument.load`, also for a version revert).
    @Test func loadKeepsPresetNumbersOneTo255AndTheFirstOfEach() throws {
        var output = OutputConfig(id: 1)
        let preset = { (number: Int, name: String) in MappingPreset(number: number, name: name, warp: output.warp, slices: output.slices) }
        output.presets = [preset(3, "first"), preset(0, "zero"), preset(3, "second"), preset(300, "high"), preset(7, "seven")]
        var project = ProjectDocument.initial(patch: .standard(layers: 2, outputs: 1), layerCount: 2, libraryRoot: "/tmp/lib", policy: .dmx)
        try project.set(try JSONValue(encoding: [output]), at: "/outputs")
        let url = FileManager.default.temporaryDirectory.appending(path: "fanous-presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectDocument.save(project, to: url)
        let loaded = try #require(ProjectDocument.load(from: url))
        let presets = try #require(ProjectDocument.outputs(from: loaded).first).presets
        #expect(presets.map(\.number) == [3, 7] && presets[0].name == "first")
    }

    /// `live.outputs` says a running morph (Output ch 7) as `{ from, to, fade }` as drawn: 0 = the edited mapping, also
    /// for a number the output lacks or has broken; null once it ended, after a cut, and when both sides draw the edited
    /// mapping. The preset fields stay as they were.
    @Test func liveSaysTheMorphWhileItRuns() {
        var o = OutputConfig(id: 1)
        o.storePreset(2, name: nil)
        o.storePreset(5, name: nil)
        o.presets[1].slices[0].dest.removeLast()  // preset 5 does not validate: drawn as the edited mapping
        let morph = PresetMorph(from: 0, start: 10, fade: 2)
        func live(_ number: Int, from: UInt8, compare: Bool = false, fade: Double = 2, at now: Double = 11) -> [String: JSONValue] {
            Engine.presetLive((number, compare, PresetMorph(from: from, start: 10, fade: fade)), config: o, at: now)
        }
        let running = Engine.presetLive((2, false, morph), config: o, at: 11)
        #expect(running["morph"] == ["from": 0, "to": 2, "fade": 2] && running["preset"] == 2 && running["presetSource"] == "console")
        #expect(live(2, from: 0, at: 12)["morph"] == .null, "ended")
        #expect(live(0, from: 2)["morph"] == ["from": 2, "to": 0, "fade": 2], "into the edited mapping")
        #expect(live(2, from: 0, compare: true, fade: 0, at: 10)["morph"] == .null, "a cut")
        #expect(live(9, from: 2)["morph"] == ["from": 2, "to": 0, "fade": 2] && live(9, from: 2)["presetMissing"] == 9, "to a missing number: the edited mapping")
        #expect(live(2, from: 5)["morph"] == ["from": 0, "to": 2, "fade": 2], "from a broken one: the edited mapping")
        #expect(live(0, from: 9)["morph"] == .null && live(5, from: 0)["morph"] == .null, "both sides the edited mapping: nothing glides")
    }
}
