// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging

/// The `project` document (DESIGN.md §11.2) until project bundles exist: what the engine persists in
/// `AppPaths.projectFile`, and the commands that change it.
public enum ProjectDocument {
    public static let schema = 1

    /// Canvas size and rate (B31).
    public typealias CanvasFormat = (width: Int, height: Int, fps: Double)
    public static let defaultCanvas: CanvasFormat = (1920, 1080, 60)
    /// Canvas rates `canvas.set` accepts.
    public static let frameRates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    /// Checks a canvas format and returns it with the rate snapped to the list entry (23.976 for 24000/1001).
    /// Even sizes only (the H.264 preview halves them); no multiple of 4 is needed: HAP's 4×4 blocks apply to media,
    /// the canvas is never block-compressed.
    public static func validated(_ format: CanvasFormat) throws -> CanvasFormat {
        guard (320...8192).contains(format.width), (320...8192).contains(format.height), format.width % 2 == 0, format.height % 2 == 0 else {
            throw CommandError.invalidArgs("width and height must be even and 320–8192")
        }
        guard let fps = frameRates.first(where: { abs($0 - format.fps) < 0.01 }) else {
            throw CommandError.invalidArgs("fps must be one of \(frameRates.map { String(format: "%g", $0) }.joined(separator: ", "))")
        }
        return (format.width, format.height, fps)
    }

    /// Canvases a project may have: each is a render pass per tick and three canvas-sized textures.
    public static let maxCanvases = 4

    /// What the compositor renders: every canvas's size, one shared rate (the compositor has one clock).
    /// Canvas 1 comes first; it cannot be removed (the clock, Syphon and CITP follow it).
    public struct CanvasLayout: Equatable, Sendable {
        public struct Size: Equatable, Sendable {
            public var id: Int
            public var width: Int
            public var height: Int
            public init(id: Int, width: Int, height: Int) {
                self.id = id
                self.width = width
                self.height = height
            }
        }
        public var fps: Double
        public var canvases: [Size]
        public init(fps: Double, canvases: [Size]) {
            self.fps = fps
            self.canvases = canvases
        }
        public init(_ format: CanvasFormat) { self.init(fps: format.fps, canvases: [Size(id: 1, width: format.width, height: format.height)]) }
        /// Canvas 1 (the first) as a format.
        public var first: CanvasFormat { (canvases.first?.width ?? defaultCanvas.width, canvases.first?.height ?? defaultCanvas.height, fps) }
    }

    /// The layout a project asks for: the first canvas as `start` says (else validated, else the default), the others
    /// validated at its rate; invalid or surplus ones are skipped (hand-edited files).
    public static func layout(from project: JSONValue, start: CanvasFormat? = nil) -> CanvasLayout {
        let list = canvases(from: project)
        let first = start ?? list.first.flatMap { try? validated(($0.width, $0.height, $0.fps)) } ?? defaultCanvas
        var sizes = [CanvasLayout.Size(id: list.first?.id ?? 1, width: first.width, height: first.height)]
        for c in list.dropFirst() where sizes.count < maxCanvases && !sizes.contains(where: { $0.id == c.id }) {
            guard let f = try? validated((c.width, c.height, first.fps)) else { continue }
            sizes.append(CanvasLayout.Size(id: c.id, width: f.width, height: f.height))
        }
        return CanvasLayout(fps: first.fps, canvases: sizes)
    }

    /// Writes a rendered layout back (a failed switch): sizes and rate of the canvases it has; canvases it lacks go,
    /// ones the project lacks come back as "Canvas n".
    public static func setCanvasLayout(_ layout: CanvasLayout, in project: inout JSONValue) throws {
        let current = canvases(from: project)
        let list = layout.canvases.map { size -> CanvasConfig in
            var c = current.first { $0.id == size.id } ?? CanvasConfig(id: size.id, name: "Canvas \(size.id)", width: size.width, height: size.height)
            c.width = size.width
            c.height = size.height
            c.fps = layout.fps
            return c
        }
        try project.set(try JSONValue(encoding: list), at: "/canvases")
    }

    /// Layer → canvas (layer numbers from 1); a layer not listed is on canvas 1. Stored sparse in `/layerCanvas`.
    public static func layerCanvases(from project: JSONValue) -> [Int: Int] {
        guard case .object(let map)? = project["layerCanvas"] else { return [:] }
        var result: [Int: Int] = [:]
        for (key, value) in map {
            if let layer = Int(key), let canvas = value.int { result[layer] = canvas }
        }
        return result
    }

    static func setLayerCanvases(_ map: [Int: Int], in project: inout JSONValue) throws {
        var object: [String: JSONValue] = [:]
        for (layer, canvas) in map where canvas != 1 { object[String(layer)] = .number(Double(canvas)) }
        try project.set(.object(object), at: "/layerCanvas")
    }

    /// The Syphon numbering (B69): `/syphon` `{"151": {app, server}}`, folder 0 files 150–169, keyed by file like
    /// `/layerCanvas` so a forget and its undo touch one key; written by the engine as it numbers servers (no command,
    /// also under show lock), freed by `syphon.forget`. Gone until they announce.
    public static func syphonNumbers(from project: JSONValue) -> [SyphonCatalog.Server] {
        guard case .object(let map)? = project["syphon"] else { return [] }
        return map.compactMap { key, entry in
            guard let file = Int(key), let app = entry["app"]?.string else { return nil }
            return SyphonCatalog.Server(file: file, app: app, server: entry["server"]?.string ?? "", gone: true)
        }.sorted { $0.file < $1.file }
    }

    public static func syphonValue(_ servers: [SyphonCatalog.Server]) -> JSONValue {
        .object(Dictionary(servers.map { (String($0.file), ["app": .string($0.app), "server": .string($0.server)]) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Layers and slices on a canvas outside `keeping` move to canvas 1 (canvas.remove, a failed canvas switch).
    /// Writes only what changes.
    public static func moveToCanvas1(keeping ids: Set<Int>, in project: inout JSONValue) throws {
        let assigned = layerCanvases(from: project)
        if assigned.values.contains(where: { !ids.contains($0) }) { try setLayerCanvases(assigned.mapValues { ids.contains($0) ? $0 : 1 }, in: &project) }
        var outputs = ProjectDocument.outputs(from: project)
        guard outputs.contains(where: { $0.slices.contains { !ids.contains($0.canvas) } }) else { return }
        for o in outputs.indices {
            for s in outputs[o].slices.indices where !ids.contains(outputs[o].slices[s].canvas) { outputs[o].slices[s].canvas = 1 }
        }
        try setOutputs(outputs, in: &project)
    }

    /// GPU memory cap over all canvases: their pixels together at most four UHD canvases (each canvas pixel costs
    /// 8 bytes × 3 textures, so ≈ 800 MB at the cap).
    public static let maxCanvasPixels = 4 * 3840 * 2160

    static func checkTotalPixels(_ canvases: [CanvasConfig]) throws {
        guard canvases.reduce(0, { $0 + $1.width * $1.height }) <= maxCanvasPixels else {
            throw CommandError.invalidArgs("all canvases together may have at most 4 × 3840 × 2160 pixels (33.2 megapixels)")
        }
    }

    static func sharedRate(_ fps: Double) -> String {
        "all canvases share one frame rate (\(String(format: "%g", fps)) fps); change it on canvas 1"
    }

    static func canvasValue(_ format: CanvasFormat) -> JSONValue {
        (try? JSONValue(encoding: [CanvasConfig(id: 1, name: "Canvas 1", width: format.width, height: format.height, fps: format.fps)])) ?? []
    }

    /// Writes a format into the first canvas (name and clock master stay); the rate goes to every canvas (one clock).
    public static func setCanvasFormat(_ format: CanvasFormat, in project: inout JSONValue) throws {
        var list = canvases(from: project)
        guard !list.isEmpty else { return try project.set(canvasValue(format), at: "/canvases") }
        list[0].width = format.width
        list[0].height = format.height
        for i in list.indices { list[i].fps = format.fps }
        try project.set(try JSONValue(encoding: list), at: "/canvases")
    }

    public static func initial(patch: Patch, layerCount: Int, libraryRoot: String, policy: SourcePolicy, canvas: CanvasFormat = defaultCanvas) -> JSONValue {
        [
            "schema": .number(Double(schema)),
            "name": "Untitled",
            "showLock": false,
            "layerCount": .number(Double(layerCount)),
            "patch": patchValue(patch),
            "policy": .string(policy.rawValue),
            "library": ["root": .string(libraryRoot)],
            "canvases": canvasValue(canvas),
            "layerCanvas": [:],
            "outputs": [],
            "syphon": [:],
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
        output.testPattern = min(TestPattern.allCases.count - 1, max(0, output.testPattern))
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

    public static func load(from url: URL, canvas: CanvasFormat = defaultCanvas) -> JSONValue? {
        guard let data = try? Data(contentsOf: url), var document = try? JSONDecoder().decode(JSONValue.self, from: data),
            document["schema"]?.int == schema, document["patch"]?.array != nil
        else { return nil }
        // keys added within schema 1 (Phase 6): give older files their defaults
        if document["outputs"] == nil { try? document.set([], at: "/outputs") }
        if document["canvases"] == nil {
            try? document.set(canvasValue(canvas), at: "/canvases")
        }
        if document["ui"] == nil { try? document.set([:], at: "/ui") }
        if document["layerCanvas"] == nil { try? document.set([:], at: "/layerCanvas") }
        if document["syphon"] == nil { try? document.set([:], at: "/syphon") }
        return document
    }

    public static func save(_ document: JSONValue, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    /// Paths `project.set` may touch; everything else has a command of its own or is engine-owned.
    static let settablePrefixes = ["/name", "/policy", "/library/root", "/ui"]

    /// `showModeOn`: canvas format changes are refused while show mode is on (they re-initialise the canvas).
    /// `checkLibraryRoot`: throws when the engine cannot switch to that root now (B51); gets the expanded absolute path.
    /// `applySync`: restarts the sync sender and receiver with saved settings; throws when the port cannot be bound.
    /// `syphonRunning`: the numbers of the Syphon servers running now (B69: only the others can be forgotten).
    public static func registerCommands(
        on store: StateStore, auth: RoleAuth, showModeOn: @escaping @Sendable () -> Bool = { false },
        checkLibraryRoot: @escaping @Sendable (String) throws -> Void = { _ in },
        applySync: @escaping @Sendable (SyncSettings) throws -> Void = { _ in },
        syphonRunning: @escaping @Sendable () -> Set<Int> = { [] }
    ) {
        store.register(
            CommandSpec(
                name: "project.set", role: .programmer, summary: "Set one project value (name, policy, library.root, ui.*); layers.setCount changes the layer count.",
                argsType: "{ path: string; value: JSONValue }"
            ) { project, args in
                guard let path = args["path"]?.string, let pointer = try? JSONPointer(path), var value = args["value"] else {
                    throw CommandError.invalidArgs("args: { path, value }")
                }
                guard settablePrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                    throw CommandError.invalidArgs("path \(path) is not settable")
                }
                if path == "/policy" {
                    guard let raw = value.string, SourcePolicy(rawValue: raw) != nil else { throw CommandError.invalidArgs("policy must be dmx, internal, ltp or htp") }
                }
                if path == "/library/root" {
                    guard let raw = value.string else { throw CommandError.invalidArgs("the library root must be a path") }
                    let expanded = (raw.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
                    guard expanded.hasPrefix("/") else { throw CommandError.invalidArgs("the library root must be an absolute path") }
                    let root = URL(fileURLWithPath: expanded).standardizedFileURL.path
                    try checkLibraryRoot(root)
                    value = .string(root)
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
                let assigned = layerCanvases(from: project)
                if assigned.keys.contains(where: { $0 > count }) { try setLayerCanvases(assigned.filter { $0.key <= count }, in: &project) }
                return nil
            })
        store.register(
            CommandSpec(
                name: "layer.set", role: .programmer,
                summary: "Set a layer's project setting: the canvas it renders into (a project setting, not a DMX channel).",
                argsType: "{ layer: number; canvas: number }"
            ) { project, args in
                guard let layer = args["layer"]?.int, let canvas = args["canvas"]?.int else { throw CommandError.invalidArgs("args: { layer, canvas }") }
                guard (1...(project["layerCount"]?.int ?? 0)).contains(layer) else { throw CommandError.invalidArgs("no layer \(layer)") }
                guard ProjectDocument.canvases(from: project).contains(where: { $0.id == canvas }) else { throw CommandError.invalidArgs("no canvas \(canvas)") }
                var assigned = layerCanvases(from: project)
                assigned[layer] = canvas
                try setLayerCanvases(assigned, in: &project)
                return nil
            })
        store.register(
            CommandSpec(
                name: "syphon.forget", role: .programmer,
                summary: "Forget a numbered Syphon server that is not running (folder 0, 150–169), or without file every one not running: the number is free again.",
                argsType: "{ file?: number }",
                // an undo puts the number back with `add /syphon/N`, which would overwrite a server numbered N meanwhile (B90)
                replayCheck: { patch, project in
                    for case .add(let pointer, let entry) in patch.operations where pointer.tokens.count == 2 && pointer.tokens[0] == "syphon" {
                        guard let held = project[pointer], held["app"] != entry["app"] || held["server"] != entry["server"] else { continue }
                        let name = "\(held["app"]?.string ?? "")/\(held["server"]?.string ?? "")"
                        throw CommandError("historyConflict", "Syphon number \(pointer.tokens[1]) is now held by \(name); undo refused")
                    }
                }
            ) { project, args in
                let running = syphonRunning()
                var numbers = syphonNumbers(from: project)
                if let raw = args["file"], raw != .null {
                    guard let file = raw.int, numbers.contains(where: { $0.file == file }) else { throw CommandError.invalidArgs("no Syphon server numbered \(raw)") }
                    guard !running.contains(file) else { throw CommandError.invalidArgs("Syphon server \(file) is running; only one that is not running can be forgotten") }
                    numbers.removeAll { $0.file == file }
                } else {
                    numbers.removeAll { !running.contains($0.file) }
                }
                try project.set(syphonValue(numbers), at: "/syphon")
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
                var canvases = ProjectDocument.canvases(from: project)
                if canvases.contains(where: { $0.clockMaster == id }) {
                    for i in canvases.indices where canvases[i].clockMaster == id { canvases[i].clockMaster = nil }
                    try project.set(try JSONValue(encoding: canvases), at: "/canvases")
                }
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
                // a slice takes its picture from an existing canvas (one it already used is left alone: hand-edited files)
                let canvasIDs = Set(ProjectDocument.canvases(from: project).map(\.id))
                for slice in updated.slices where !canvasIDs.contains(slice.canvas) {
                    guard outputs[index].slices.first(where: { $0.id == slice.id })?.canvas == slice.canvas else {
                        throw CommandError.invalidArgs("no canvas \(slice.canvas)")
                    }
                }
                outputs[index] = updated
                try setOutputs(outputs, in: &project)
                return nil
            })
        store.register(
            CommandSpec(
                name: "canvas.set", role: .programmer,
                summary: "Set the canvas name or clock-master output, or its size and rate (even 320–8192 px; 23.976, 24, 25, 29.97, 30, 50, 59.94 or 60 fps, set on canvas 1 for every canvas; re-initialises the canvas so outputs blank briefly; refused in show mode).",
                argsType: "{ id: number; path: '/name' | '/clockMaster'; value: JSONValue } | { id: number; width: number; height: number; fps: number }"
            ) { project, args in
                guard let id = args["id"]?.int else { throw CommandError.invalidArgs("args: { id, path, value } or { id, width, height, fps }") }
                var canvases = ProjectDocument.canvases(from: project)
                guard let index = canvases.firstIndex(where: { $0.id == id }) else { throw CommandError.invalidArgs("no canvas \(id)") }
                if let width = args["width"]?.int, let height = args["height"]?.int, let fps = args["fps"]?.double {
                    guard !showModeOn() else { throw CommandError("showMode", "the canvas format cannot change in show mode; leave show mode first") }
                    let format = try validated((width, height, fps))
                    canvases[index].width = format.width
                    canvases[index].height = format.height
                    // one compositor clock: canvas 1's rate is every canvas's rate
                    if index == 0 {
                        for i in canvases.indices { canvases[i].fps = format.fps }
                    } else if format.fps != canvases[0].fps {
                        throw CommandError.invalidArgs(sharedRate(canvases[0].fps))
                    }
                    try checkTotalPixels(canvases)
                } else {
                    guard let path = args["path"]?.string, ["/name", "/clockMaster"].contains(path), let value = args["value"] else {
                        throw CommandError.invalidArgs("args: { id, path: /name | /clockMaster, value } or { id, width, height, fps }")
                    }
                    if path == "/name" {
                        guard let name = value.string, !name.isEmpty else { throw CommandError.invalidArgs("name must be a string") }
                        canvases[index].name = name
                    } else {
                        canvases[index].clockMaster = value.int
                    }
                }
                try project.set(try JSONValue(encoding: canvases), at: "/canvases")
                return nil
            })
        store.register(
            CommandSpec(
                name: "canvas.add", role: .programmer,
                summary: "Add a canvas (up to 4, at most 4 × 3840 × 2160 pixels together; even 320–8192 px) at the shared frame rate of canvas 1; outputs blank briefly; refused in show mode. Returns the new id.",
                argsType: "{ width: number; height: number; fps?: number; name?: string }"
            ) { project, args in
                guard let width = args["width"]?.int, let height = args["height"]?.int else { throw CommandError.invalidArgs("args: { width, height, fps?, name? }") }
                guard !showModeOn() else { throw CommandError("showMode", "canvases cannot be added in show mode; leave show mode first") }
                var canvases = ProjectDocument.canvases(from: project)
                guard canvases.count < maxCanvases else { throw CommandError.invalidArgs("at most \(maxCanvases) canvases") }
                let rate = canvases.first?.fps ?? defaultCanvas.fps
                let format = try validated((width, height, args["fps"]?.double ?? rate))
                guard format.fps == rate else { throw CommandError.invalidArgs(sharedRate(rate)) }
                let id = (canvases.map(\.id).max() ?? 0) + 1
                var name = "Canvas \(id)"
                if let given = args["name"] {
                    guard let text = given.string, !text.isEmpty else { throw CommandError.invalidArgs("name must be a string") }
                    name = text
                }
                canvases.append(CanvasConfig(id: id, name: name, width: format.width, height: format.height, fps: rate))
                try checkTotalPixels(canvases)
                try project.set(try JSONValue(encoding: canvases), at: "/canvases")
                return .number(Double(id))
            })
        store.register(
            CommandSpec(
                name: "canvas.remove", role: .programmer,
                summary: "Remove a canvas (not canvas 1): its layers and slices move to canvas 1; outputs blank briefly; refused in show mode.",
                argsType: "{ id: number }"
            ) { project, args in
                guard let id = args["id"]?.int else { throw CommandError.invalidArgs("args: { id }") }
                var canvases = ProjectDocument.canvases(from: project)
                guard canvases.contains(where: { $0.id == id }) else { throw CommandError.invalidArgs("no canvas \(id)") }
                guard id != 1 else { throw CommandError.invalidArgs("canvas 1 cannot be removed") }
                guard canvases.count > 1 else { throw CommandError.invalidArgs("the last canvas cannot be removed") }
                guard !showModeOn() else { throw CommandError("showMode", "canvases cannot be removed in show mode; leave show mode first") }
                canvases.removeAll { $0.id == id }
                try project.set(try JSONValue(encoding: canvases), at: "/canvases")
                // what used it moves to canvas 1, in the same undo step
                try moveToCanvas1(keeping: Set(canvases.map(\.id)), in: &project)
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
        store.register(
            CommandSpec(
                name: "sync.set", role: .programmer, undoable: false,
                summary: "Multi-server sync settings: interface (any, en0, an IPv4 address), port (1–65535, default 8002), target (broadcast, or IPv4[:port]); machine setting, not part of the project; applies live; refused in show mode.",
                argsType: "{ interface?: string; port?: number; target?: string }"
            ) { _, args in
                var members: [String: JSONValue] = [:]  // only these are written; the others keep the file's values (B79)
                guard args["interface"] != nil || args["port"] != nil || args["target"] != nil else { throw CommandError.invalidArgs("args: { interface?, port?, target? }") }
                if let value = args["interface"] {
                    guard let interface = value.string, !interface.isEmpty else { throw CommandError.invalidArgs("interface must be any, an interface name or an address") }
                    members["interface"] = .string(interface)
                }
                if let value = args["port"] {
                    guard let port = value.int, (1...65535).contains(port) else { throw CommandError.invalidArgs("port must be 1–65535") }
                    // sACN shares its port with SO_REUSEPORT: a sync receiver there would take sACN datagrams
                    let taken = [ArtNet.port, SACN.port, OSCReceiver.defaultPort, OSCReceiver.defaultPort + 1]
                    guard !taken.contains(UInt16(port)) else { throw CommandError.invalidArgs("port \(port) is used by Art-Net, sACN or OSC") }
                    members["port"] = .number(Double(port))
                }
                if let value = args["target"] {
                    guard let target = value.string, SyncSettings.isValidTarget(target) else { throw CommandError.invalidArgs("target must be broadcast or an IPv4 address with an optional :port") }
                    members["target"] = .string(target)
                }
                guard !showModeOn() else { throw CommandError("showMode", "sync settings cannot change in show mode; leave show mode first") }
                let sync: SyncSettings
                do {
                    sync = try auth.setSync(members)
                } catch {
                    throw CommandError("failed", "cannot save settings: \(error)")
                }
                try applySync(sync)
                return nil
            })
        registerUniverseCommands(on: store)
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
