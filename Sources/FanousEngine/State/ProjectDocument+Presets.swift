// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation

/// Mapping presets (DESIGN.md §9.10 item 3): `output.preset.*` keep snapshots of an output's warp and slices in
/// `OutputConfig.presets`, one undo step per call, also for a whole wall (`ids`). `output.show` is Compare's lease: no
/// project change, held on the DMX queue (`DMXStore.show`).
extension ProjectDocument {
    /// The indices in `outputs` of `args.ids`: existing outputs, none twice.
    static func targets(_ args: JSONValue, in outputs: [OutputConfig]) throws -> [Int] {
        guard let list = args["ids"]?.array, !list.isEmpty else { throw CommandError.invalidArgs("ids must list one or more outputs") }
        var indices: [Int] = []
        for value in list {
            guard let id = value.int, let index = outputs.firstIndex(where: { $0.id == id }) else { throw CommandError.invalidArgs("no output \(value)") }
            guard !indices.contains(index) else { throw CommandError.invalidArgs("output \(id) is listed twice") }
            indices.append(index)
        }
        return indices
    }

    static func presetNumber(_ value: JSONValue?) throws -> Int {
        let number = value?.int
        if let problem = MappingPreset.numberProblem(number) { throw CommandError.invalidArgs(problem) }
        return number!
    }

    static func presetName(_ value: JSONValue) throws -> String {
        guard let raw = value.string else { throw CommandError.invalidArgs("name must be a string") }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = MappingPreset.nameProblem(name) { throw CommandError.invalidArgs(problem) }
        return name
    }

    /// A preset as the engine draws it: validated as an edited mapping would be (`validate`, values clamped). Throws for one
    /// a hand-edited or foreign file left broken: the output pass skips it and `live.outputs` calls it missing.
    static func validated(_ preset: MappingPreset) throws -> MappingPreset {
        var probe = OutputConfig(id: 0), checked = preset
        (probe.warp, probe.slices) = (preset.warp, preset.slices)
        try validate(&probe)
        (checked.warp, checked.slices) = (probe.warp, probe.slices)
        return checked
    }

    /// Every target must have preset `number`.
    static func requirePreset(_ number: Int, _ outputs: [OutputConfig], _ indices: [Int]) throws {
        if let i = indices.first(where: { outputs[$0].preset(number) == nil }) { throw CommandError.invalidArgs("\(outputs[i].name) has no preset \(number)") }
    }

    static func registerPresetCommands(on store: StateStore, showModeOn: @escaping @Sendable () -> Bool, showPreset: @escaping @Sendable ([Int], Int) -> Void) {
        store.register(
            CommandSpec(
                name: "output.preset.store", role: .programmer,
                summary: "Store each output's warp and slices (masks included) as mapping preset number 1–255; blend, colour, intensity, region and display stay live. An existing number is replaced (result { replaced: ids }) and keeps its name unless name is given; a new one is called \"Preset N\" by default.",
                argsType: "{ ids: number[]; number: number; name?: string }"
            ) { project, args in
                var outputs = ProjectDocument.outputs(from: project)
                let indices = try targets(args, in: outputs), number = try presetNumber(args["number"])
                let name = try args["name"].flatMap { $0 == .null ? nil : try presetName($0) }
                var replaced: [JSONValue] = []
                for i in indices {
                    if outputs[i].storePreset(number, name: name) { replaced.append(.number(Double(outputs[i].id))) }
                }
                try setOutputs(outputs, in: &project)
                return replaced.isEmpty ? nil : ["replaced": .array(replaced)]
            })
        store.register(
            CommandSpec(
                name: "output.preset.recall", role: .programmer,
                summary: "Copy mapping preset number into each output's warp and slices (an edit: Undo takes it back). Every output must have it. On a projector-wall output a slice 1 source that differs from the wall's becomes manual, as with output.set (result { manual: [{ wall, output, field }] }).",
                argsType: "{ ids: number[]; number: number }"
            ) { project, args in
                var outputs = ProjectDocument.outputs(from: project)
                let indices = try targets(args, in: outputs), number = try presetNumber(args["number"])
                try requirePreset(number, outputs, indices)
                var walls = ProjectDocument.walls(from: project)
                var manual: [JSONValue] = [], wallTouched = false
                for i in indices {
                    let old = outputs[i]
                    _ = outputs[i].recallPreset(number)
                    // as output.set: a preset from a hand-edited or foreign file may not hold
                    do { try validate(&outputs[i]) } catch let error as CommandError {
                        throw CommandError.invalidArgs("preset \(number) of \(old.name) cannot be recalled: \(error.message)")
                    }
                    guard let w = walls.firstIndex(where: { $0.outputs.contains(old.id) }) else { continue }
                    wallTouched = true
                    for field in WallLayout.follow(edit: outputs[i], was: old, wall: &walls[w], outputs: &outputs) {
                        manual.append(["wall": .number(Double(walls[w].id)), "output": .number(Double(old.id)), "field": .string(field.rawValue)])
                    }
                }
                if wallTouched { try setWalls(walls, in: &project) }
                try setOutputs(outputs, in: &project)
                return manual.isEmpty ? nil : ["manual": .array(manual)]
            })
        store.register(
            CommandSpec(
                name: "output.preset.remove", role: .programmer, summary: "Remove mapping preset number from each output; every output must have it.",
                argsType: "{ ids: number[]; number: number }"
            ) { project, args in
                var outputs = ProjectDocument.outputs(from: project)
                let indices = try targets(args, in: outputs), number = try presetNumber(args["number"])
                try requirePreset(number, outputs, indices)
                for i in indices { outputs[i].presets.removeAll { $0.number == number } }
                try setOutputs(outputs, in: &project)
                return nil
            })
        store.register(
            CommandSpec(
                name: "output.preset.rename", role: .programmer, summary: "Rename mapping preset number on each output (1–64 characters); every output must have it.",
                argsType: "{ ids: number[]; number: number; name: string }"
            ) { project, args in
                var outputs = ProjectDocument.outputs(from: project)
                let indices = try targets(args, in: outputs), number = try presetNumber(args["number"])
                guard let value = args["name"] else { throw CommandError.invalidArgs("args: { ids, number, name }") }
                let name = try presetName(value)
                try requirePreset(number, outputs, indices)
                for i in indices {
                    for p in outputs[i].presets.indices where outputs[i].presets[p].number == number { outputs[i].presets[p].name = name }
                }
                try setOutputs(outputs, in: &project)
                return nil
            })
        store.register(
            CommandSpec(
                name: "output.show", role: .programmer, undoable: false,
                summary: "Compare, a lease (DESIGN.md §9.10 items 3 and 4): outputs 1–8 show mapping preset 1–255 for 5 s, over Output ch 6; the UI renews it every 2 s while Compare is held and the latest call wins; preset 0 ends it. Never saved or undone; refused in show mode.",
                argsType: "{ ids: number[]; preset: number }"
            ) { project, args in
                let outputs = ProjectDocument.outputs(from: project)
                let ids = try targets(args, in: outputs).map { outputs[$0].id }
                guard let preset = args["preset"]?.int, preset == 0 || MappingPreset.numbers.contains(preset) else {
                    throw CommandError.invalidArgs("preset must be 1–255, or 0 to end Compare")
                }
                // ponytail: the DMX snapshot has slots for outputs 1–8 only (as the Output fixture), so Compare does too; raise
                // `ParameterSnapshotSlot.maxOutputs` when outputs 9+ need it
                if let id = ids.first(where: { $0 > ParameterSnapshotSlot.maxOutputs }) { throw CommandError.invalidArgs("Compare reaches outputs 1–8, not \(id)") }
                // show mode ends a lease at once (Engine), so a renewal must not start it again
                guard preset == 0 || !showModeOn() else { throw CommandError("showMode", "Compare is off in show mode") }
                showPreset(ids, preset)
                return nil
            })
    }
}
