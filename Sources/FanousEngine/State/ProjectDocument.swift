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
    /// Canvas width and height `canvas.set` accepts (even values only).
    public static let canvasSides = 320...8192

    /// Checks a canvas format and returns it with the rate snapped to the list entry (23.976 for 24000/1001).
    /// Even sizes only (the H.264 preview halves them); no multiple of 4 is needed: HAP's 4×4 blocks apply to media,
    /// the canvas is never block-compressed.
    public static func validated(_ format: CanvasFormat) throws -> CanvasFormat {
        guard canvasSides.contains(format.width), canvasSides.contains(format.height), format.width % 2 == 0, format.height % 2 == 0 else {
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

    /// A live input numbering (B69, B73): `/syphon` `{"151": {app, server}}` (folder 0 files 150–169) and the other
    /// kinds' keys (`LiveCatalog.Kind`), keyed by file like `/layerCanvas` so a forget and its undo touch one key;
    /// written by the engine as it numbers sources (no command, also under show lock), freed by `syphon.forget` and
    /// `capture.forget`. Gone until they are seen. `/capture` also keeps each device's `model` (the uid fallback).
    public static func liveNumbers(_ kind: LiveCatalog.Kind, from project: JSONValue) -> [LiveCatalog.Entry] {
        guard case .object(let map)? = project[kind.projectKey] else { return [] }
        return map.compactMap { key, entry in
            guard let file = Int(key), let source = entry[kind.fields.source]?.string else { return nil }
            let model = kind.fields.model.flatMap { entry[$0]?.string } ?? ""
            return LiveCatalog.Entry(kind: kind, file: file, source: source, name: entry[kind.fields.name]?.string ?? "", gone: true, model: model)
        }.sorted { $0.file < $1.file }
    }

    public static func liveValue(_ entries: [LiveCatalog.Entry]) -> JSONValue {
        .object(
            Dictionary(
                entries.map { e in
                    var value: [String: JSONValue] = [e.kind.fields.source: .string(e.source), e.kind.fields.name: .string(e.name)]
                    if let model = e.kind.fields.model { value[model] = .string(e.model) }
                    return (String(e.file), .object(value))
                },
                uniquingKeysWith: { a, _ in a }))
    }

    /// `patch` with every op below `/syphon/N` (or another live key's, a revert's diff of one field) folded into one
    /// `replace /syphon/N` of the whole entry from `document`, the side the patch leads to: the history holds whole
    /// entries, so the replay check compares `app` and `server` together (B104).
    static func wholeLiveEntries(_ patch: JSONPatch, in document: JSONValue) -> JSONPatch {
        var folded: Set<[String]> = []
        return JSONPatch(operations: patch.operations.compactMap { operation in
            let pointer: JSONPointer
            switch operation {
            case .add(let p, _), .replace(let p, _), .remove(let p): pointer = p
            }
            guard pointer.tokens.count > 2, LiveCatalog.Kind(rawValue: pointer.tokens[0]) != nil else { return operation }
            let entry = JSONPointer(tokens: Array(pointer.tokens.prefix(2)))
            guard folded.insert(entry.tokens).inserted, let value = document[entry] else { return nil }
            return .replace(entry, value)
        })
    }

    /// An undo or redo must not change a live number (`/syphon` or another kind's) that changed since the step it
    /// undoes (B90, B91): each op on a whole entry `/syphon/N` (`wholeLiveEntries`) needs the value that step left
    /// there (`done`, nil where it removed) or already the one it writes, so it neither overwrites, renames nor frees a
    /// server that took N meanwhile.
    /// Nor may it put a name on N that sits on another number by then (the server took another one meanwhile, B92),
    /// unless that number is `running`: the catalog
    /// drops such a twin only while that server runs. The `historyConflict` drops the entry.
    public static func checkLiveReplay(_ patch: JSONPatch, undoing done: JSONPatch, on project: JSONValue, running: Set<Int> = []) throws {
        // diff(a, b) and diff(b, a) have the same paths, so the ops line up by pointer
        var left: [[String]: JSONValue?] = [:]
        for operation in done.operations {
            switch operation {
            case .add(let p, let v), .replace(let p, let v): left[p.tokens] = v
            case .remove(let p): left[p.tokens] = .some(nil)
            }
        }
        var written: [LiveCatalog.Kind: Set<Int>] = [:]
        var liveOps: [JSONPatch.Operation] = []
        for operation in patch.operations {
            let pointer: JSONPointer, value: JSONValue?
            switch operation {
            case .add(let p, let v), .replace(let p, let v): (pointer, value) = (p, v)
            case .remove(let p): (pointer, value) = (p, nil)
            }
            guard let kind = pointer.tokens.first.flatMap(LiveCatalog.Kind.init(rawValue:)) else { continue }
            liveOps.append(operation)
            guard pointer.tokens.count == 2, let expected = left[pointer.tokens] else { continue }
            if value != nil, let file = Int(pointer.tokens[1]) { written[kind, default: []].insert(file) }
            let now = project[pointer]
            guard now != expected, now != value else { continue }
            let number = pointer.tokens[1]
            guard let held = project[JSONPointer(tokens: [kind.projectKey, number])] else {
                throw CommandError("historyConflict", "\(kind.title) number \(number) is now free; undo/redo refused")
            }
            let label = LiveCatalog.Entry(kind: kind, file: 0, source: held[kind.fields.source]?.string ?? "", name: held[kind.fields.name]?.string ?? "").label
            throw CommandError("historyConflict", "\(kind.title) number \(number) is now held by \(label); undo/redo refused")
        }
        guard !written.isEmpty else { return }
        // the numbers as the step would leave them (an op that does not apply is skipped by the step, or fails it)
        var after = project
        for operation in liveOps { try? JSONPatch(operations: [operation]).apply(to: &after) }
        for kind in LiveCatalog.Kind.allCases {
            guard let files = written[kind] else { continue }
            let numbers = liveNumbers(kind, from: after)
            for entry in numbers where files.contains(entry.file) {
                let twin = numbers.first { $0.file != entry.file && !running.contains($0.file) && $0.same(entry) }
                guard let twin else { continue }
                throw CommandError("historyConflict", "\(kind.noun) \(entry.label) is now on number \(twin.file); undo/redo refused")
            }
        }
    }

    /// Layers, slices and walls on a canvas outside `keeping` move to canvas 1 (canvas.remove, a failed canvas switch).
    /// Writes only what changes.
    public static func moveToCanvas1(keeping ids: Set<Int>, in project: inout JSONValue) throws {
        let assigned = layerCanvases(from: project)
        if assigned.values.contains(where: { !ids.contains($0) }) { try setLayerCanvases(assigned.mapValues { ids.contains($0) ? $0 : 1 }, in: &project) }
        var walls = ProjectDocument.walls(from: project)
        if walls.contains(where: { !ids.contains($0.canvas) }) {
            for w in walls.indices where !ids.contains(walls[w].canvas) { walls[w].canvas = 1 }
            try setWalls(walls, in: &project)
        }
        var outputs = ProjectDocument.outputs(from: project)
        let before = outputs
        func move(_ slices: inout [SliceConfig]) { for s in slices.indices where !ids.contains(slices[s].canvas) { slices[s].canvas = 1 } }
        for o in outputs.indices {
            move(&outputs[o].slices)
            // stored presets too: one shown or recalled later must not sample a canvas that is gone
            for p in outputs[o].presets.indices { move(&outputs[o].presets[p].slices) }
        }
        if outputs != before { try setOutputs(outputs, in: &project) }
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

    /// `canvas.set`'s size path, also taken by a wall's `fit: "makeCanvas"`: refused in show mode; canvas 1's rate is
    /// every canvas's rate (one compositor clock).
    static func resize(_ canvases: inout [CanvasConfig], at index: Int, to format: CanvasFormat, showModeOn: Bool) throws {
        guard !showModeOn else { throw CommandError("showMode", "the canvas format cannot change in show mode; leave show mode first") }
        let format = try validated(format)
        canvases[index].width = format.width
        canvases[index].height = format.height
        if index == 0 {
            for i in canvases.indices { canvases[i].fps = format.fps }
        } else if format.fps != canvases[0].fps {
            throw CommandError.invalidArgs(sharedRate(canvases[0].fps))
        }
        try checkTotalPixels(canvases)
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
            "walls": [],
            "syphon": [:],
            "capture": [:],
            "screens": [:],
            "ui": [:],
        ]
    }

    // MARK: Outputs (DESIGN.md §9)

    public static func outputs(from project: JSONValue) -> [OutputConfig] {
        (try? project["outputs"]?.decoded(as: [OutputConfig].self)) ?? []
    }

    public static func canvases(from project: JSONValue) -> [CanvasConfig] {
        (try? project["canvases"]?.decoded(as: [CanvasConfig].self)) ?? []
    }

    static func validate(_ output: inout OutputConfig) throws {
        output.intensity = min(1, max(0, output.intensity))
        output.testPattern = min(TestPattern.allCases.count - 1, max(0, output.testPattern))
        for edge in [\OutputConfig.blend.left, \.blend.right, \.blend.top, \.blend.bottom] {
            output[keyPath: edge].overlap = max(0, output[keyPath: edge].overlap)
            output[keyPath: edge].power = min(10, max(0.1, output[keyPath: edge].power))
            output[keyPath: edge].gamma = min(5, max(0.5, output[keyPath: edge].gamma))
            if let rgb = output[keyPath: edge].gammaRGB {
                guard rgb.count == 3 else { throw CommandError.invalidArgs("gammaRGB needs three values (r, g, b), or null") }
                output[keyPath: edge].gammaRGB = rgb.map { min(5, max(0.5, $0)) }
            }
        }
        output.blend.lift = min(0.5, max(0, output.blend.lift))
        output.blend.liftFeather = max(0, output.blend.liftFeather)
        guard output.color.gain.count == 3 else { throw CommandError.invalidArgs("color.gain needs three values (r, g, b)") }
        output.color.gain = output.color.gain.map { min(2, max(0, $0)) }
        output.color.black = min(0.2, max(0, output.color.black))
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
            // a negative feather (the number field before M2.7 kept one) is none; NaN stays and is refused below
            for m in output.slices[i].masks.indices where output.slices[i].masks[m].feather < 0 { output.slices[i].masks[m].feather = 0 }
            if let problem = output.slices[i].masks.lazy.compactMap(\.problem).first { throw CommandError.invalidArgs("slice \(output.slices[i].id): \(problem)") }
        }
        if let region = output.region, region.w <= 0 || region.h <= 0 { throw CommandError.invalidArgs("region needs a positive size") }
    }

    static func setOutputs(_ outputs: [OutputConfig], in project: inout JSONValue) throws {
        try project.set(try JSONValue(encoding: outputs), at: "/outputs")
    }

    /// Patches Output n's fixture where the standard patch puts it, after the Master on the Master's universe (the
    /// standard Master when it is unpatched), when that range fits and is free; otherwise the Patch screen shows it
    /// unpatched. Outputs above `maxOutputs` have no console control.
    static func patchOutputFixture(_ n: Int, in project: inout JSONValue) throws {
        guard n <= ParameterSnapshotSlot.maxOutputs, var patch = ProjectDocument.patch(from: project), patch.entry(for: .output(n)) == nil,
            let master = patch.entry(for: .master) ?? Patch.standard(layers: project["layerCount"]?.int ?? 1, outputs: 0).entry(for: .master)
        else { return }
        let entry = PatchEntry(fixture: .output(n), universe: master.universe, address: master.channels.upperBound + 1 + (n - 1) * FixtureMode.output.footprint)
        guard entry.fitsInUniverse, !patch.entries.contains(where: { $0.universe == entry.universe && $0.channels.overlaps(entry.channels) }) else { return }
        patch.entries.append(entry)
        try project.set(patchValue(patch), at: "/patch")
    }

    /// `patch.set`'s checks, also run on each entry of `patch.setMany`: the fixture and its new entry, nil for address 0
    /// (unpatch, accepted for any fixture so a stale entry can still go). An address needs a fixture that exists
    /// (DESIGN.md §6.6).
    static func checkedEntry(_ args: JSONValue, in project: JSONValue, fixtures: Set<FixtureRef>) throws -> (FixtureRef, PatchEntry?) {
        guard let fixtureName = args["fixture"]?.string, let fixture = FixtureRef(parsing: fixtureName) else {
            throw CommandError.invalidArgs("fixture must be \"Layer n\", \"Master\", \"Output n\" or \"Keystone n\"")
        }
        guard let universeName = args["universe"]?.string, let universe = UniverseID(parsing: universeName) else {
            throw CommandError.invalidArgs("universe must be artnet:net.subnet.universe or sacn:n")
        }
        guard let address = args["address"]?.int, (0...512).contains(address) else { throw CommandError.invalidArgs("address must be 0 (unpatch) or 1–512") }
        guard address > 0 else { return (fixture, nil) }
        if !fixtures.contains(fixture) {
            switch fixture {
            case .layer(let n) where n > ParameterSnapshotSlot.maxLayers:
                throw CommandError.invalidArgs("console control covers layers 1–\(ParameterSnapshotSlot.maxLayers)")
            case .layer(let n):
                throw CommandError.invalidArgs("there is no layer \(n): the project has \(project["layerCount"]?.int ?? defaultLayerCount) layers")
            case .output(let n), .keystone(let n):
                guard n <= ParameterSnapshotSlot.maxOutputs else { throw CommandError.invalidArgs("console control covers outputs 1–\(ParameterSnapshotSlot.maxOutputs)") }
                throw CommandError.invalidArgs("there is no output \(n): add the output first")
            case .master:
                break
            }
        }
        let entry = PatchEntry(fixture: fixture, universe: universe, address: address)
        guard entry.fitsInUniverse else { throw CommandError.invalidArgs("\(fixture) does not fit at \(address)") }
        return (fixture, entry)
    }

    /// Where `layers.setCount` puts a new Layer n (DESIGN.md §6.6 item 2): on its slot while the Layers group (the
    /// patched layers up to `existing`) is a Block; else right after Layer n − 1 when that one is patched, else at its
    /// standard address. Nil when that range is taken or past the last universe: Layer n stays unpatched.
    static func newLayerEntry(_ n: Int, in patch: Patch, existing: Int) -> PatchEntry? {
        let footprint = FixtureMode.layer.footprint
        var placed: [Int: Patch.Slot] = [:]
        for e in patch.entries {
            if case .layer(let k) = e.fixture, k <= existing { placed[k] = Patch.Slot(e.universe, e.address) }
        }
        let slot =
            if let start = Patch.blockStart(of: placed, footprint: footprint) {
                Patch.slot(of: n, from: start, footprint: footprint)
            } else if let before = placed[n - 1] {
                Patch.slot(of: 2, from: before, footprint: footprint)
            } else {
                Patch.slot(of: n, from: Patch.Slot(UniverseID(.artnet, 0), 1), footprint: footprint)
            }
        guard let slot else { return nil }
        let entry = PatchEntry(fixture: .layer(n), universe: slot.universe, address: slot.address)
        return patch.entries.contains { $0.universe == entry.universe && $0.channels.overlaps(entry.channels) } ? nil : entry
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

    /// The fixtures that exist (DESIGN.md §6.6), patched or not: Layer 1…min(`layerCount`, 32), the Master, and Output n
    /// and Keystone n of every output n ≤ `ParameterSnapshotSlot.maxOutputs`. Each has a resolver.
    public static func fixtures(layerCount: Int, outputs: [Int]) -> Set<FixtureRef> {
        var fixtures: Set<FixtureRef> = [.master]
        for n in 1...ParameterSnapshotSlot.maxLayers where n <= layerCount { fixtures.insert(.layer(n)) }
        for n in outputs where (1...ParameterSnapshotSlot.maxOutputs).contains(n) { fixtures.formUnion([.output(n), .keystone(n)]) }
        return fixtures
    }

    /// `outputs`: the project's, when the caller has decoded them already. Without `layerCount`, the layers the engine
    /// starts with.
    public static func fixtures(from project: JSONValue, outputs: [OutputConfig]? = nil) -> Set<FixtureRef> {
        fixtures(layerCount: project["layerCount"]?.int ?? defaultLayerCount, outputs: (outputs ?? self.outputs(from: project)).map(\.id))
    }

    /// The layer count of a project that has none (a hand-written file), and of a fresh install.
    public static let defaultLayerCount = 8

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
        if document["walls"] == nil { try? document.set([], at: "/walls") }
        if document["canvases"] == nil {
            try? document.set(canvasValue(canvas), at: "/canvases")
        }
        if document["ui"] == nil { try? document.set([:], at: "/ui") }
        if document["layerCanvas"] == nil { try? document.set([:], at: "/layerCanvas") }
        if document["syphon"] == nil { try? document.set([:], at: "/syphon") }
        if document["capture"] == nil { try? document.set([:], at: "/capture") }
        if document["screens"] == nil { try? document.set([:], at: "/screens") }
        // mapping presets of a hand-edited or foreign file: numbers 1–255 and the first of each number, the list the engine
        // draws from (§9.10 item 3), so the UI offers the same; a preset that does not validate stays and is skipped there.
        // Masks v2 (§9.10 item 5): a slice's `mask` becomes `masks`, in the edited slices and in every stored preset's
        if var list = document["outputs"]?.array {
            var changed = false
            for o in list.indices {
                if let slices = list[o]["slices"]?.array, let converted = convertMasks(slices) {
                    try? list[o].set(.array(converted), at: "/slices")
                    changed = true
                }
                guard let presets = list[o]["presets"]?.array else { continue }
                var seen = Set<Int>(), kept: [JSONValue] = []
                for var preset in presets {
                    if let slices = preset["slices"]?.array, let converted = convertMasks(slices) { try? preset.set(.array(converted), at: "/slices") }
                    if let n = preset["number"]?.int, MappingPreset.numbers.contains(n), seen.insert(n).inserted { kept.append(preset) }
                }
                if kept != presets {
                    try? list[o].set(.array(kept), at: "/presets")
                    changed = true
                }
            }
            if changed { try? document.set(.array(list), at: "/outputs") }
        }
        // an Output or Keystone fixture without its output, or above the console's outputs, controls nothing (until
        // 2026-10-30 every project had Output 1–4 patched)
        if var patch = patch(from: document) {
            let ids = Set(outputs(from: document).map(\.id))
            let count = patch.entries.count
            patch.entries.removeAll {
                guard let n = $0.fixture.outputNumber else { return false }
                return !ids.contains(n) || n > ParameterSnapshotSlot.maxOutputs
            }
            if patch.entries.count != count { try? document.set(patchValue(patch), at: "/patch") }
        }
        return document
    }

    /// Masks v2 (DESIGN.md §9.10 item 5): each slice's `mask` (a polygon with its feather, before M2.7) becomes `masks`, one
    /// add mask with the same points and feather; none for a null or a path of fewer than 3 points, which never drew. Nil
    /// when no slice had one.
    static func convertMasks(_ slices: [JSONValue]) -> [JSONValue]? {
        var changed = false
        let converted = slices.map { slice -> JSONValue in
            guard case .object(var fields) = slice, let old = fields.removeValue(forKey: "mask") else { return slice }
            changed = true
            if fields["masks"] == nil, let path = old["path"]?.array, path.count >= 3 {
                // a negative feather (which the old raster drew as a hard edge) is none, as `validate` makes it
                fields["masks"] = [["mode": .string("add"), "feather": .number(max(0, old["feather"]?.double ?? 0)), "path": .array(path)]]
            }
            return .object(fields)
        }
        return changed ? converted : nil
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
    /// `liveRunning`: the numbers of the live inputs running now, of every catalog (B69: only the others can be
    /// forgotten). `authorizeCamera`, `authorizeScreen`: ask for the camera permission or screen recording (`capture.authorize`).
    /// `displayModes`: the current mode of each connected display by UUID (a wall output's pixel size, §9.9).
    /// `showPreset`: the Compare lease of `output.show` (output ids, preset number; 0 ends it), kept on the DMX queue.
    /// `showOverlay`: the edit overlay lease of `output.overlay` (output id, on, selection), kept by the output coordinator.
    public static func registerCommands(
        on store: StateStore, auth: RoleAuth, showModeOn: @escaping @Sendable () -> Bool = { false },
        checkLibraryRoot: @escaping @Sendable (String) throws -> Void = { _ in },
        applySync: @escaping @Sendable (SyncSettings) throws -> Void = { _ in },
        liveRunning: @escaping @Sendable () -> Set<Int> = { [] },
        authorizeCamera: @escaping @Sendable () -> Void = {},
        authorizeScreen: @escaping @Sendable () -> Void = {},
        displayModes: @escaping @Sendable () -> [String: DisplayModeConfig] = { [:] },
        showPreset: @escaping @Sendable ([Int], Int) -> Void = { _, _ in },
        showOverlay: @escaping @Sendable (Int, Bool, OverlaySelection?) -> Void = { _, _, _ in }
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
                name: "patch.set", role: .programmer,
                summary: "Patch a fixture (layer, master, output, keystone) to a universe and address, or unpatch it with address 0 (any fixture); an address only for a fixture that exists: a layer up to the layer count (1–32), an Output or Keystone fixture of an output that exists (1–8).",
                argsType: "{ fixture: string; universe: string; address: number }"
            ) { project, args in
                let (fixture, entry) = try checkedEntry(args, in: project, fixtures: fixtures(from: project))
                guard var patch = ProjectDocument.patch(from: project) else { throw CommandError.invalidArgs("project has no patch") }
                patch.entries.removeAll { $0.fixture == fixture }
                if let entry { patch.entries.append(entry) }
                try project.set(patchValue(patch), at: "/patch")
                return nil
            })
        store.register(
            CommandSpec(
                name: "patch.setMany", role: .programmer,
                summary: "Patch or unpatch several fixtures in one step (one undo): each entry is checked as patch.set checks it; one bad entry, or a fixture listed twice, refuses all.",
                argsType: "{ entries: { fixture: string; universe: string; address: number }[] }"
            ) { project, args in
                guard let list = args["entries"]?.array else { throw CommandError.invalidArgs("args: { entries: [{ fixture, universe, address }] }") }
                guard var patch = ProjectDocument.patch(from: project) else { throw CommandError.invalidArgs("project has no patch") }
                let existing = fixtures(from: project)
                var seen: Set<FixtureRef> = []
                for (i, item) in list.enumerated() {
                    let fixture: FixtureRef, entry: PatchEntry?
                    do {
                        (fixture, entry) = try checkedEntry(item, in: project, fixtures: existing)
                    } catch let error as CommandError {
                        throw CommandError(error.code, "entry \(i + 1): \(error.message); nothing was patched")
                    }
                    guard seen.insert(fixture).inserted else { throw CommandError.invalidArgs("\(fixture) is listed twice; nothing was patched") }
                    patch.entries.removeAll { $0.fixture == fixture }
                    if let entry { patch.entries.append(entry) }
                }
                try project.set(patchValue(patch), at: "/patch")
                return nil
            })
        store.register(
            CommandSpec(
                name: "layers.setCount", role: .programmer,
                summary: "Set the number of layers (1–64): a new layer goes on its slot of the Layers block, or right after the layer before it when the layers are no block (else at its standard address), and stays unpatched when that range is taken; layers above 32 get no address; dropped layers are unpatched.",
                argsType: "{ count: number }"
            ) { project, args in
                guard let count = args["count"]?.int, (1...64).contains(count) else { throw CommandError.invalidArgs("count must be 1–64") }
                guard var patch = ProjectDocument.patch(from: project) else { throw CommandError.invalidArgs("project has no patch") }
                let previous = project["layerCount"]?.int ?? 0
                patch.entries.removeAll {
                    if case .layer(let n) = $0.fixture { return n > count }
                    return false
                }
                // only layers that exist get an address (layers above 32 never render)
                let existing = min(count, ParameterSnapshotSlot.maxLayers)
                if existing > previous {
                    for n in (previous + 1)...existing where patch.entry(for: .layer(n)) == nil {
                        if let entry = newLayerEntry(n, in: patch, existing: existing) { patch.entries.append(entry) }
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
        // `capture.forget` covers the capture devices (1–20) and the displays (21–28): a file picks its kind by range
        let forgets: [(name: String, kinds: [LiveCatalog.Kind], summary: String)] = [
            ("syphon.forget", [.syphon], "Forget a numbered Syphon server that is not running (folder 0, 150–169), or without file every one not running: the number is free again."),
            (
                "capture.forget", [.capture, .screens],
                "Forget a numbered capture device (folder 0, 1–20) or display (21–28) that is not running, or without file every one not running (1–28): the number is free again."
            ),
        ]
        let nouns: [LiveCatalog.Kind: String] = [.syphon: "Syphon server", .capture: "capture device", .screens: "display"]
        for (name, kinds, summary) in forgets {
            store.register(
                CommandSpec(
                    name: name, role: .programmer, summary: summary, argsType: "{ file?: number }",
                    // an undo puts the number back with `add /syphon/N`, which would overwrite a source numbered N meanwhile (B90)
                    replayCheck: { patch, done, project in try checkLiveReplay(patch, undoing: done, on: project, running: liveRunning()) }
                ) { project, args in
                    let running = liveRunning()
                    if let raw = args["file"], raw != .null {
                        let kind = kinds.first { kind in raw.int.map(kind.files.contains) ?? false } ?? kinds[0]
                        let noun = nouns[kind] ?? kind.noun
                        var numbers = liveNumbers(kind, from: project)
                        guard let file = raw.int, numbers.contains(where: { $0.file == file }) else {
                            throw CommandError.invalidArgs("no \(noun) numbered \(raw.int.map(String.init) ?? "\(raw)")")
                        }
                        guard !running.contains(file) else {
                            throw CommandError.invalidArgs("\(noun.prefix(1).uppercased() + noun.dropFirst()) \(file) is running; only one that is not running can be forgotten")
                        }
                        numbers.removeAll { $0.file == file }
                        try project.set(liveValue(numbers), at: JSONPointer(tokens: [kind.projectKey]))
                    } else {
                        for kind in kinds {
                            let numbers = liveNumbers(kind, from: project)
                            let kept = numbers.filter { running.contains($0.file) }
                            if kept.count != numbers.count { try project.set(liveValue(kept), at: JSONPointer(tokens: [kind.projectKey])) }
                        }
                    }
                    return nil
                })
        }
        store.register(
            CommandSpec(
                name: "capture.authorize", role: .programmer, undoable: false,
                summary:
                    "Ask macOS for the camera permission, or for screen recording (allow Fanous in System Settings, then restart the engine); refused in show mode.",
                argsType: "{ kind: 'camera' | 'screen' }"
            ) { _, args in
                guard let kind = args["kind"]?.string, kind == "camera" || kind == "screen" else { throw CommandError.invalidArgs("kind must be camera or screen") }
                guard !showModeOn() else { throw CommandError("showMode", "permissions are not asked in show mode; leave show mode first") }
                if kind == "camera" { authorizeCamera() } else { authorizeScreen() }
                return nil
            })
        store.register(
            CommandSpec(
                name: "output.add", role: .programmer,
                summary: "Add an output (one full-canvas slice, no blend, identity warp), optionally bound to a display; its Output fixture is patched next to the Master when that range is free.",
                argsType: "{ display?: { uuid: string; name: string } }"
            ) { project, args in
                var outputs = ProjectDocument.outputs(from: project)
                let id = (outputs.map(\.id).max() ?? 0) + 1
                var output = OutputConfig(id: id)
                if let uuid = args["display"]?["uuid"]?.string { output.display = DisplayIdentity(uuid: uuid, name: args["display"]?["name"]?.string ?? uuid) }
                outputs.append(output)
                try setOutputs(outputs, in: &project)
                try patchOutputFixture(id, in: &project)
                return .number(Double(id))
            })
        store.register(
            CommandSpec(name: "output.remove", role: .programmer, summary: "Remove an output (not one in a projector wall) and unpatch its Output and Keystone fixtures.", argsType: "{ id: number }") { project, args in
                guard let id = args["id"]?.int else { throw CommandError.invalidArgs("args: { id }") }
                var outputs = ProjectDocument.outputs(from: project)
                guard outputs.contains(where: { $0.id == id }) else { throw CommandError.invalidArgs("no output \(id)") }
                if let wall = walls(from: project).first(where: { $0.outputs.contains(id) }) {
                    throw CommandError.invalidArgs("output \(id) is part of \(wall.name); remove the wall first (its outputs stay as they are)")
                }
                outputs.removeAll { $0.id == id }
                try setOutputs(outputs, in: &project)
                if var patch = ProjectDocument.patch(from: project), patch.entries.contains(where: { $0.fixture.outputNumber == id }) {
                    patch.entries.removeAll { $0.fixture.outputNumber == id }
                    try project.set(patchValue(patch), at: "/patch")
                }
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
                summary: "Set one value inside an output by JSON pointer (name, display, region, mode, intensity, blend/*, warp/*, slices/*, testPattern, color/* with gain [r, g, b] 0–2 and black 0–0.2); the result is validated as a whole. On a projector-wall output a changed slice 1 source or inner overlap becomes manual (result { wall, manual }), and an inner edge's power, gamma or gammaRGB goes to its seam, so both sides follow.",
                argsType: "{ id: number; path: string; value: JSONValue }"
            ) { project, args in
                guard let id = args["id"]?.int, let path = args["path"]?.string, let pointer = try? JSONPointer(path), let value = args["value"] else {
                    throw CommandError.invalidArgs("args: { id, path, value }")
                }
                guard !pointer.tokens.isEmpty, pointer.tokens.first != "id" else { throw CommandError.invalidArgs("path must name a field of the output") }
                guard pointer.tokens.first != "presets" else { throw CommandError.invalidArgs("presets change through output.preset.store, rename and remove") }
                var outputs = ProjectDocument.outputs(from: project)
                guard let index = outputs.firstIndex(where: { $0.id == id }) else { throw CommandError.invalidArgs("no output \(id)") }
                var document = try JSONValue(encoding: outputs[index])
                try document.set(value, at: pointer)
                // a page loaded before masks v2 (M2.7) still sends `mask`, which decoding would drop: refused, not converted
                if document["slices"]?.array?.contains(where: { $0["mask"] != nil }) == true {
                    throw CommandError.invalidArgs("a slice's mask is masks now (masks v2): reload the page")
                }
                guard var updated = try? document.decoded(as: OutputConfig.self) else {
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
                let old = outputs[index]
                outputs[index] = updated
                var reply: JSONValue? = nil
                var walls = ProjectDocument.walls(from: project)
                if let w = walls.firstIndex(where: { $0.outputs.contains(id) }) {
                    let marked = WallLayout.follow(edit: updated, was: old, wall: &walls[w], outputs: &outputs)
                    try setWalls(walls, in: &project)
                    if !marked.isEmpty { reply = ["wall": .number(Double(walls[w].id)), "manual": .array(marked.map { .string($0.rawValue) })] }
                }
                try setOutputs(outputs, in: &project)
                return reply
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
                    try resize(&canvases, at: index, to: (width, height, fps), showModeOn: showModeOn())
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
        registerWallCommands(on: store, showModeOn: showModeOn, displayModes: displayModes)
        registerPresetCommands(on: store, showModeOn: showModeOn, showPreset: showPreset, showOverlay: showOverlay)
    }
}

extension FixtureRef {
    /// Parses the `description` form: "Layer 3", "Master", "Output 1", "Keystone 1" (case-insensitive).
    public init?(parsing text: String) {
        let parts = text.split(separator: " ")
        switch (parts.first?.lowercased(), parts.count) {
        case ("master", 1): self = .master
        case ("layer", 2): guard let n = Int(parts[1]), n >= 1 else { return nil }; self = .layer(n)
        case ("output", 2): guard let n = Int(parts[1]), n >= 1 else { return nil }; self = .output(n)
        case ("keystone", 2): guard let n = Int(parts[1]), n >= 1 else { return nil }; self = .keystone(n)
        default: return nil
        }
    }

    /// The output an Output or Keystone fixture belongs to: it is patched only while that output exists.
    var outputNumber: Int? {
        switch self {
        case .output(let n), .keystone(let n): n
        case .layer, .master: nil
        }
    }
}
