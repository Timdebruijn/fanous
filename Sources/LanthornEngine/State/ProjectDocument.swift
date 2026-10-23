// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import LanthornCore
import Logging

/// The `project` document (DESIGN.md §11.2) until project bundles exist: what the engine persists in
/// `AppPaths.projectFile`, and the commands that change it.
public enum ProjectDocument {
    public static let schema = 1

    public static func initial(patch: Patch, layerCount: Int, libraryRoot: String, policy: SourcePolicy, canvas: (width: Int, height: Int) = (1920, 1080)) -> JSONValue {
        [
            "schema": .number(Double(schema)),
            "name": "Untitled",
            "showLock": false,
            "layerCount": .number(Double(layerCount)),
            "patch": patchValue(patch),
            "policy": .string(policy.rawValue),
            "library": ["root": .string(libraryRoot)],
            "canvases": (try? JSONValue(encoding: [CanvasConfig(id: 1, name: "Canvas 1", width: canvas.width, height: canvas.height)])) ?? [],
            "outputs": [],
            "ui": [:],
        ]
    }

    // MARK: Outputs (DESIGN.md §9)

    public static func outputs(from project: JSONValue) -> [OutputConfig] {
        guard let value = project["outputs"], let data = try? JSONEncoder().encode(value) else { return [] }
        return (try? JSONDecoder().decode([OutputConfig].self, from: data)) ?? []
    }

    public static func canvases(from project: JSONValue) -> [CanvasConfig] {
        guard let value = project["canvases"], let data = try? JSONEncoder().encode(value) else { return [] }
        return (try? JSONDecoder().decode([CanvasConfig].self, from: data)) ?? []
    }

    static func validate(_ output: inout OutputConfig) throws {
        output.intensity = min(1, max(0, output.intensity))
        output.testPattern = min(7, max(0, output.testPattern))
        for edge in [\OutputConfig.blend.left, \.blend.right, \.blend.top, \.blend.bottom] {
            output[keyPath: edge].overlap = max(0, output[keyPath: edge].overlap)
            output[keyPath: edge].power = min(10, max(0.1, output[keyPath: edge].power))
            output[keyPath: edge].gamma = min(5, max(0.5, output[keyPath: edge].gamma))
        }
        output.blend.lift = min(0.5, max(0, output.blend.lift))
        output.blend.liftFeather = max(0, output.blend.liftFeather)
        guard output.warp.cornerPin.count == 4 else { throw CommandError.invalidArgs("cornerPin needs 4 points") }
        if let mesh = output.warp.mesh {
            guard (2...33).contains(mesh.cols), (2...33).contains(mesh.rows), mesh.points.count == mesh.cols * mesh.rows else {
                throw CommandError.invalidArgs("mesh must be 2–33 columns and rows with cols×rows points")
            }
        }
        guard !output.slices.isEmpty else { throw CommandError.invalidArgs("an output needs at least one slice") }
        for i in output.slices.indices {
            guard output.slices[i].dest.count == 4 else { throw CommandError.invalidArgs("slice dest needs 4 points") }
            output.slices[i].opacity = min(1, max(0, output.slices[i].opacity))
            if let mask = output.slices[i].mask, mask.path.count < 3 { output.slices[i].mask = nil }
        }
        if let region = output.region, region.w <= 0 || region.h <= 0 { throw CommandError.invalidArgs("region needs a positive size") }
    }

    static func setOutputs(_ outputs: [OutputConfig], in project: inout JSONValue) throws {
        try project.set(try JSONValue(encoding: outputs), at: "/outputs")
    }

    /// `[{"fixture":"Layer 3","universe":"artnet:0.0.1","address":17}, …]`, sorted by universe then address.
    public static func patchValue(_ patch: Patch) -> JSONValue {
        .array(
            patch.entries.sorted { ($0.universe, $0.address) < ($1.universe, $1.address) }.map {
                ["fixture": .string($0.fixture.description), "universe": .string($0.universe.description), "address": .number(Double($0.address))]
            })
    }

    /// The patch the DMX store runs: entries of layers beyond `layerCount` are ignored.
    public static func effectivePatch(from project: JSONValue) -> Patch? {
        guard var patch = patch(from: project) else { return nil }
        let count = project["layerCount"]?.int ?? Int.max
        patch.entries.removeAll {
            if case .layer(let n) = $0.fixture { return n > count }
            return false
        }
        return patch
    }

    public static func patch(from project: JSONValue) -> Patch? {
        guard let entries = project["patch"]?.array else { return nil }
        var result: [PatchEntry] = []
        for entry in entries {
            guard let fixture = entry["fixture"]?.string.flatMap(FixtureRef.init(parsing:)),
                let universe = entry["universe"]?.string.flatMap(UniverseID.init(parsing:)),
                let address = entry["address"]?.int
            else { return nil }
            result.append(PatchEntry(fixture: fixture, universe: universe, address: address))
        }
        return Patch(entries: result)
    }

    public static func load(from url: URL, canvas: (width: Int, height: Int) = (1920, 1080)) -> JSONValue? {
        guard let data = try? Data(contentsOf: url), var document = try? JSONDecoder().decode(JSONValue.self, from: data),
            document["schema"]?.int == schema, document["patch"]?.array != nil
        else { return nil }
        // keys added within schema 1 (Phase 6): give older files their defaults
        if document["outputs"] == nil { try? document.set([], at: "/outputs") }
        if document["canvases"] == nil {
            try? document.set((try? JSONValue(encoding: [CanvasConfig(id: 1, name: "Canvas 1", width: canvas.width, height: canvas.height)])) ?? [], at: "/canvases")
        }
        if document["ui"] == nil { try? document.set([:], at: "/ui") }
        return document
    }

    public static func save(_ document: JSONValue, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    /// Paths `project.set` may touch; everything else has a command of its own or is engine-owned.
    static let settablePrefixes = ["/name", "/policy", "/library/root", "/ui"]

    public static func registerCommands(on store: StateStore, auth: RoleAuth) {
        store.register(
            CommandSpec(
                name: "project.set", role: .programmer, summary: "Set one project value (name, policy, library.root, ui.*); layers.setCount changes the layer count.",
                argsType: "{ path: string; value: JSONValue }"
            ) { project, args in
                guard let path = args["path"]?.string, let pointer = try? JSONPointer(path), let value = args["value"] else {
                    throw CommandError.invalidArgs("args: { path, value }")
                }
                guard settablePrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                    throw CommandError.invalidArgs("path \(path) is not settable")
                }
                if path == "/policy" {
                    guard let raw = value.string, SourcePolicy(rawValue: raw) != nil else { throw CommandError.invalidArgs("policy must be dmx, internal, ltp or htp") }
                }
                try project.set(value, at: pointer)
                return nil
            })
        store.register(
            CommandSpec(
                name: "patch.set", role: .programmer, summary: "Patch a fixture (layer, master, output) to a universe and address, or unpatch it with address 0.",
                argsType: "{ fixture: string; universe: string; address: number }"
            ) { project, args in
                guard let fixtureName = args["fixture"]?.string, let fixture = FixtureRef(parsing: fixtureName) else {
                    throw CommandError.invalidArgs("fixture must be \"Layer n\", \"Master\" or \"Output n\"")
                }
                guard let universeName = args["universe"]?.string, let universe = UniverseID(parsing: universeName) else {
                    throw CommandError.invalidArgs("universe must be artnet:net.subnet.universe or sacn:n")
                }
                guard let address = args["address"]?.int, (0...512).contains(address) else { throw CommandError.invalidArgs("address must be 0 (unpatch) or 1–512") }
                guard var patch = ProjectDocument.patch(from: project) else { throw CommandError.invalidArgs("project has no patch") }
                patch.entries.removeAll { $0.fixture == fixture }
                if address > 0 {
                    guard address + fixture.mode.footprint - 1 <= 512 else { throw CommandError.invalidArgs("\(fixture) does not fit at \(address)") }
                    patch.entries.append(PatchEntry(fixture: fixture, universe: universe, address: address))
                }
                try project.set(patchValue(patch), at: "/patch")
                return nil
            })
        store.register(
            CommandSpec(
                name: "layers.setCount", role: .programmer,
                summary: "Set the number of layers (1–64): new layers are patched at their standard address when that range is free, dropped layers are unpatched.",
                argsType: "{ count: number }"
            ) { project, args in
                guard let count = args["count"]?.int, (1...64).contains(count) else { throw CommandError.invalidArgs("count must be 1–64") }
                guard var patch = ProjectDocument.patch(from: project) else { throw CommandError.invalidArgs("project has no patch") }
                let previous = project["layerCount"]?.int ?? 0
                patch.entries.removeAll {
                    if case .layer(let n) = $0.fixture { return n > count }
                    return false
                }
                if count > previous {
                    let standard = Patch.standard(layers: count, outputs: 4)
                    for n in (previous + 1)...count where patch.entry(for: .layer(n)) == nil {
                        guard let candidate = standard.entry(for: .layer(n)) else { continue }
                        let free = !patch.entries.contains { $0.universe == candidate.universe && $0.channels.overlaps(candidate.channels) }
                        if free { patch.entries.append(candidate) }
                    }
                }
                try project.set(.number(Double(count)), at: "/layerCount")
                try project.set(patchValue(patch), at: "/patch")
                return nil
            })
        store.register(
            CommandSpec(
                name: "output.add", role: .programmer, summary: "Add an output (one full-canvas slice, no blend, identity warp), optionally bound to a display.",
                argsType: "{ display?: { uuid: string; name: string } }"
            ) { project, args in
                var outputs = ProjectDocument.outputs(from: project)
                let id = (outputs.map(\.id).max() ?? 0) + 1
                var output = OutputConfig(id: id)
                if let uuid = args["display"]?["uuid"]?.string { output.display = DisplayIdentity(uuid: uuid, name: args["display"]?["name"]?.string ?? uuid) }
                outputs.append(output)
                try setOutputs(outputs, in: &project)
                return .number(Double(id))
            })
        store.register(
            CommandSpec(name: "output.remove", role: .programmer, summary: "Remove an output.", argsType: "{ id: number }") { project, args in
                guard let id = args["id"]?.int else { throw CommandError.invalidArgs("args: { id }") }
                var outputs = ProjectDocument.outputs(from: project)
                guard outputs.contains(where: { $0.id == id }) else { throw CommandError.invalidArgs("no output \(id)") }
                outputs.removeAll { $0.id == id }
                try setOutputs(outputs, in: &project)
                return nil
            })
        store.register(
            CommandSpec(
                name: "output.set", role: .programmer,
                summary: "Set one value inside an output by JSON pointer (name, display, region, mode, intensity, blend/*, warp/*, slices/*, testPattern); the result is validated as a whole.",
                argsType: "{ id: number; path: string; value: JSONValue }"
            ) { project, args in
                guard let id = args["id"]?.int, let path = args["path"]?.string, let pointer = try? JSONPointer(path), let value = args["value"] else {
                    throw CommandError.invalidArgs("args: { id, path, value }")
                }
                guard !pointer.tokens.isEmpty, pointer.tokens.first != "id" else { throw CommandError.invalidArgs("path must name a field of the output") }
                var outputs = ProjectDocument.outputs(from: project)
                guard let index = outputs.firstIndex(where: { $0.id == id }) else { throw CommandError.invalidArgs("no output \(id)") }
                var document = try JSONValue(encoding: outputs[index])
                try document.set(value, at: pointer)
                guard let data = try? JSONEncoder().encode(document), var updated = try? JSONDecoder().decode(OutputConfig.self, from: data) else {
                    throw CommandError.invalidArgs("\(path) does not fit the output model")
                }
                updated.id = id
                try validate(&updated)
                outputs[index] = updated
                try setOutputs(outputs, in: &project)
                return nil
            })
        store.register(
            CommandSpec(
                name: "canvas.set", role: .programmer, summary: "Set the canvas name or clock-master output (size changes need a restart, B31).",
                argsType: "{ id: number; path: '/name' | '/clockMaster'; value: JSONValue }"
            ) { project, args in
                guard let id = args["id"]?.int, let path = args["path"]?.string, ["/name", "/clockMaster"].contains(path), let value = args["value"] else {
                    throw CommandError.invalidArgs("args: { id, path: /name | /clockMaster, value }")
                }
                var canvases = ProjectDocument.canvases(from: project)
                guard let index = canvases.firstIndex(where: { $0.id == id }) else { throw CommandError.invalidArgs("no canvas \(id)") }
                if path == "/name" {
                    guard let name = value.string, !name.isEmpty else { throw CommandError.invalidArgs("name must be a string") }
                    canvases[index].name = name
                } else {
                    canvases[index].clockMaster = value.int
                }
                try project.set(try JSONValue(encoding: canvases), at: "/canvases")
                return nil
            })
        store.register(
            CommandSpec(
                name: "roles.setPassword", role: .programmer, undoable: false, summary: "Set or clear (null) the password of a role; machine setting, not part of the project.",
                argsType: "{ role: Role; password: string | null }"
            ) { _, args in
                guard let role = args["role"]?.string.flatMap(Role.init(rawValue:)) else { throw CommandError.invalidArgs("role must be monitor, operator or programmer") }
                let password = args["password"]?.string
                if let password, password.isEmpty { throw CommandError.invalidArgs("password must not be empty; use null to clear") }
                do {
                    try auth.setPassword(password, for: role)
                } catch {
                    throw CommandError("failed", "cannot save settings: \(error)")
                }
                return nil
            })
    }
}

extension JSONValue {
    /// The project's outputs (empty when the document has none).
    var outputsConfig: [OutputConfig] { ProjectDocument.outputs(from: self) }
}

extension FixtureRef {
    /// Parses the `description` form: "Layer 3", "Master", "Output 1" (case-insensitive).
    public init?(parsing text: String) {
        let parts = text.split(separator: " ")
        switch (parts.first?.lowercased(), parts.count) {
        case ("master", 1): self = .master
        case ("layer", 2): guard let n = Int(parts[1]), n >= 1 else { return nil }; self = .layer(n)
        case ("output", 2): guard let n = Int(parts[1]), n >= 1 else { return nil }; self = .output(n)
        default: return nil
        }
    }
}

extension UniverseID {
    /// Parses the `description` form: "artnet:net.subnet.universe" or "sacn:n".
    public init?(parsing text: String) {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let transport = text[..<colon].lowercased()
        let rest = text[text.index(after: colon)...]
        switch transport {
        case "artnet":
            let parts = rest.split(separator: ".").map { Int($0) }
            guard parts.count == 3, let net = parts[0], let subnet = parts[1], let universe = parts[2],
                (0...127).contains(net), (0...15).contains(subnet), (0...15).contains(universe)
            else { return nil }
            self = .artnet(net: net, subnet: subnet, universe: universe)
        case "sacn":
            guard let n = Int(rest), (1...63999).contains(n) else { return nil }
            self = UniverseID(.sacn, n)
        default:
            return nil
        }
    }
}
