// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Synchronization
import Testing

@testable import FanousEngine

/// B266: integers only a hand-edited, foreign or restored `project.json` can hold (commands refuse them) have no effect,
/// or are refused by the command that meets them, instead of trapping the engine in integer arithmetic. Every test
/// below trapped (killed the test process) on the code before B266, except where it says otherwise.
@Suite(.cleansTempFiles)
struct ProjectValueRangeTests {
    /// The lowest address JSON can carry exactly; `JSONValue.int` takes it.
    static let lowest = Int.min
    /// The highest whole number a JSON number converts to exactly (2^63 − 1024): `Int(exactly:)` of 2^63 is nil.
    static let highest = Int(exactly: Double(Int.max).nextDown)!

    static func cue(trigger: String) -> JSONValue {
        ["id": .string(UUID().uuidString), "number": 1, "name": "a", "fade": 0, "values": [], "trigger": .string(trigger), "follow": .null]
    }

    /// A trigger hour beyond Int32 overflowed `Timecode.frameCount` on the cue queue at the first crossing check (the
    /// second incoming frame). 99999999999999 hours still fit at 25 fps (8.99 × 10^18 frames), not at 30.
    @Test func aTriggerBeyondInt32IsNoTrigger() throws {
        var project = testProject(layers: 1, outputs: 0)
        try project.set([Self.cue(trigger: "99999999999999:00:00:00@30")], at: "/cues")
        let list = ShowCommands.cueList(from: project)
        #expect(list.cues.count == 1 && list.cues[0].timecodeTrigger == nil, "the cue stays, without a trigger")
        var engine = CueEngine(list: list)
        engine.timecode(Timecode(hours: 0, minutes: 0, seconds: 1, frames: 0, rate: .fps25), at: 0)
        engine.timecode(Timecode(hours: 0, minutes: 0, seconds: 1, frames: 1, rate: .fps25), at: 0.04)
        #expect(engine.current == nil, "it never fires")
        // the edge: Int32 still reads, as before (a stored out-of-range trigger stays armed), one more does not
        #expect(ShowCommands.parseTimecode("2147483647:00:00:00")?.hours == 2_147_483_647)
        #expect(ShowCommands.parseTimecode("2147483648:00:00:00") == nil)
        #expect(ShowCommands.parseTimecode("-2147483648:00:00:00")?.hours == -2_147_483_648)
    }

    /// `address - 1` overflowed in `ChannelMap.rawValues` on the DMX queue at the first packet of the fixture's universe.
    @Test func aPatchAddressOutsideTheUniverseMapsNothing() throws {
        let zeros = [UInt8](repeating: 0, count: 512)
        for address in [Self.lowest, Int.min + 1, -1, 0, 450, 513, Self.highest, Int.max] {
            #expect(ChannelMap.rawValues(mode: .layer, slots: zeros, address: address) == nil, "\(address)")
        }
        #expect(ChannelMap.rawValues(mode: .layer, slots: zeros, address: 449) != nil)
        // the whole path: a project's patch into the DMX store, then a packet on that universe
        var project = testProject(layers: 2, outputs: 0)
        let patch = try #require(ProjectDocument.patch(from: project))
        try project.set(
            ProjectDocument.patchValue(Patch(entries: patch.entries.map { $0.fixture == .layer(1) ? PatchEntry(fixture: .layer(1), universe: $0.universe, address: Self.lowest) : $0 })),
            at: "/patch")
        let dmx = DMXStore(patch: try #require(ProjectDocument.effectivePatch(from: project)), logger: testLogger)
        var data = [UInt8](repeating: 0, count: 512)
        (data[64], data[65]) = (255, 255)  // Layer 2's 16-bit intensity (address 65)
        dmx.queue.sync { dmx.receive(artnet: ArtDmx(portAddress: 0, data: data), from: "desk", at: 1000) }
        #expect(dmx.resolvedRaw(.layer(2), .layer(.intensity)) == 65535, "the fixture next to it still maps")
    }

    @Test func fitsInUniverseAtTheEndsOfInt() {
        for address in [Int.min, 0, 450, Int.max] {
            #expect(!PatchEntry(fixture: .layer(1), universe: UniverseID(.artnet, 0), address: address).fitsInUniverse, "\(address)")
        }
        #expect(PatchEntry(fixture: .layer(1), universe: UniverseID(.artnet, 0), address: 449).fitsInUniverse)
    }

    /// `layers.setCount` computes a block start from the lowest patched layer: `address − (k − 1) × 64` overflowed.
    @Test func aLayerAddressOutsideTheUniverseStartsNoBlock() throws {
        #expect(Patch.blockStart(of: [2: Patch.Slot(UniverseID(.artnet, 0), Self.lowest)], footprint: 64) == nil)
        var project = testProject(layers: 2, outputs: 0)
        try project.set(.array([["fixture": "Layer 2", "universe": "artnet:0.0.0", "address": .number(Double(Self.lowest))]]), at: "/patch")
        let (store, _) = testStore(project: project)
        #expect(store.execute("layers.setCount", args: ["count": 3], role: .programmer).failureCode == nil)
        #expect(ProjectDocument.patch(from: store.project)?.entry(for: .layer(3)) == nil, "no slot after an address outside the universe")
    }

    /// `1...layerCount` traps for a count below 1.
    @Test func layerSetOnAProjectWithoutLayersIsRefused() throws {
        var project = testProject(layers: 2, outputs: 0)
        try project.set(.number(0), at: "/layerCount")
        let (store, _) = testStore(project: project)
        #expect(store.execute("layer.set", args: ["layer": 1, "canvas": 1], role: .programmer) == .failure(.invalidArgs("no layer 1")))
    }

    static func hugeCanvas(_ project: inout JSONValue) throws {
        let canvases = ProjectDocument.canvases(from: project) + [CanvasConfig(id: 2, name: "Canvas 2", width: 1 << 32, height: 1 << 32)]
        try project.set(try JSONValue(encoding: canvases), at: "/canvases")
    }

    /// `width × height` of another canvas overflowed in the pixel budget of canvas.add, canvas.set and makeCanvas.
    @Test func aCanvasBeyondTheBudgetRefusesTheOthers() throws {
        var project = testProject(layers: 2, outputs: 0)
        try Self.hugeCanvas(&project)
        let (store, _) = testStore(project: project)
        let budget = "all canvases together may have at most 4 × 3840 × 2160 pixels (33.2 megapixels)"
        #expect(store.execute("canvas.add", args: ["width": 640, "height": 480], role: .programmer) == .failure(.invalidArgs(budget)))
        #expect(store.execute("canvas.set", args: ["id": 1, "width": 1280, "height": 720, "fps": 60], role: .programmer) == .failure(.invalidArgs(budget)))
        // a wall that sizes canvas 1: the others' pixels leave it nothing, and the budget refuses
        let machine = WallCommandsTests.Machine()
        let walls = WallCommandsTests.store(project, machine: machine)
        try addOutputs(walls, 2)
        #expect(WallCommandsTests.add(walls, [1, 2], cols: 2, rows: 1, fit: "makeCanvas").failureMessage == budget)
    }

    static let hugeMesh = MeshWarp(cols: 1 << 32, rows: 1 << 32, points: [])

    /// `cols × rows` of the mesh overflowed when the output's warp field was compiled.
    @Test func aMeshBeyondItsGridIsIgnored() {
        var warp = WarpSettings()
        warp.mesh = Self.hugeMesh
        #expect(WarpMath.field(warp, cols: 4, rows: 4) == WarpMath.field(WarpSettings(), cols: 4, rows: 4))
    }

    /// New in B266 (no old code to fail against): `isIdentity` built `cols × rows` points to compare, which for this mesh
    /// never ends.
    @Test func aMeshBeyondItsGridIsNotWellFormed() {
        #expect(!Self.hugeMesh.isWellFormed && !Self.hugeMesh.isIdentity)
        #expect(MeshWarp.identity(cols: 3, rows: 2).isWellFormed && MeshWarp.identity(cols: 3, rows: 2).isIdentity)
        #expect(!MeshWarp(cols: 3, rows: 3, points: MeshWarp.identity(cols: 2, rows: 2).points).isWellFormed)
    }

    /// A layer count past 64 (a hand-edited file whose patch does not parse) made the start build a standard patch of that
    /// many layers: memory without end. Failed (65 layers), did not trap, on the old code.
    @Test func theStandardPatchHasAtMost64Layers() {
        let layers = Patch.standard(layers: 65, outputs: 0).entries.filter { if case .layer = $0.fixture { true } else { false } }
        #expect(layers.count == 64)
    }

    /// A version whose patch holds an address outside the universe is restored like any other (the engine ignores that
    /// entry), and the restored address maps nothing. Passed on main; refused (no trap) on the first commit of B266.
    @Test func aVersionWithAnAddressOutsideTheUniverseIsRestoredAndMapsNothing() throws {
        let base = tempFile("fanous-versions")
        let (store, _) = testStore(outputs: 0)
        let versions = ProjectVersions(directory: base.appending(path: "versions"), logger: testLogger)
        versions.registerCommands(on: store)
        let bad: JSONValue = .array([["fixture": "Layer 1", "universe": "artnet:0.0.0", "address": .number(Double(Self.lowest))]])
        store.correct(bad, at: "/patch")
        let saved = try #require(try store.execute("project.snapshot", args: ["name": "Odd patch"], role: .programmer).get().value)
        store.correct([], at: "/patch")
        _ = try store.execute("project.revert", args: ["id": saved["id"]!], role: .programmer).get()
        #expect(store.project["patch"] == bad)
        let dmx = DMXStore(patch: try #require(ProjectDocument.effectivePatch(from: store.project)), logger: testLogger)
        dmx.queue.sync { dmx.receive(artnet: ArtDmx(portAddress: 0, data: [UInt8](repeating: 255, count: 512)), from: "desk", at: 1000) }
        #expect(dmx.resolvedRaw(.layer(1), .layer(.intensity)) == 0, "Layer 1 maps nothing")
    }

    /// A wall without `seams` gets its grid's seams at decode, at every start: `i + cols` overflowed for a `cols` near
    /// Int.max before the `j < outputs.count` check. Trapped on the first commit of B266.
    @Test func aWallWithAColumnCountNearIntMaxDecodes() throws {
        let outputs = Array(repeating: "1", count: 1100).joined(separator: ",")
        let text = #"{"walls":[{"id":1,"cols":9223372036854775000,"rows":2,"outputs":[\#(outputs)],"overlap":{"x":0,"y":0}}]}"#
        let project = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let (walls, issues) = ProjectDocument.wallEntries(from: project)
        #expect(issues.isEmpty && walls.count == 1)
        #expect(walls.first?.seams.count == 1099, "right neighbours only: no output sits below another")
    }

    /// A negative canvas side made the others' pixels negative, and `Int(budget − others)` in makeCanvas trapped; it also
    /// offset the budget. Trapped on the first commit of B266.
    @Test func aNegativeCanvasSideCountsNothing() throws {
        var project = testProject(layers: 2, outputs: 0)
        let canvases = ProjectDocument.canvases(from: project) + [CanvasConfig(id: 2, name: "C2", width: -(1 << 32), height: 1 << 32)]
        try project.set(try JSONValue(encoding: canvases), at: "/canvases")
        #expect(ProjectDocument.pixels(canvases) == 1920 * 1080)
        let walls = WallCommandsTests.store(project, machine: WallCommandsTests.Machine())
        try addOutputs(walls, 2)
        _ = try WallCommandsTests.add(walls, [1, 2], cols: 2, rows: 1, fit: "makeCanvas").get()
        let first = try #require(ProjectDocument.canvases(from: walls.project).first)
        #expect((first.width, first.height) == (3456, 1080))
    }

    /// `layers.setCount` looped from a hand-edited previous count: −10^15 is 10^15 rounds on the store queue (a hang, no
    /// trap). Run on a thread of its own with a deadline, so the old code fails after 10 s instead of hanging the run.
    /// Failed (timed out) on the first commit of B266.
    @Test func layersSetCountFromAFarNegativeCountEnds() async throws {
        var project = testProject(layers: 2, outputs: 0)
        try project.set(.number(-1e15), at: "/layerCount")
        let (store, _) = testStore(project: project)
        let done = Atomic<Bool>(false)
        Thread.detachNewThread {
            _ = store.execute("layers.setCount", args: ["count": 1], role: .programmer)
            done.store(true, ordering: .relaxed)
        }
        let ended = await waitUntil(.seconds(10)) { done.load(ordering: .relaxed) }
        #expect(ended)
        guard ended else { return }  // the store's queue is still busy: reading the project would wait on it
        #expect(store.project["layerCount"]?.int == 1)
    }

    /// B339: `output.set` refused only a region side <= 0, so a height of 2^59 was accepted and the engine trapped in the
    /// preview's size arithmetic when a client opened that output's preview. Accepted on the old code (no trap here: this
    /// test never opens a preview).
    @Test func aRegionSideBeyondTheLargestTextureIsRefused() throws {
        let (store, _) = testStore(outputs: 0)
        try addOutputs(store, 1)
        let message = "region width and height must be at most 16384 px"
        for (w, h) in [(1920, 1 << 59), (1 << 59, 1080), (16385, 1080)] {
            let result = store.execute("output.set", args: ["id": 1, "path": "/region", "value": ["x": 0, "y": 0, "w": .number(Double(w)), "h": .number(Double(h))]], role: .programmer)
            #expect(result == .failure(.invalidArgs(message)), "\(w)×\(h)")
        }
        _ = try store.execute("output.set", args: ["id": 1, "path": "/region", "value": ["x": 0, "y": 0, "w": 16384, "h": 16384]], role: .programmer).get()
        #expect(store.execute("output.set", args: ["id": 1, "path": "/region", "value": ["x": 0, "y": 0, "w": 0, "h": 1080]], role: .programmer)
            == .failure(.invalidArgs("region needs a positive size")))
    }

    /// Every value above in one project file: it loads, and the loaded document is the file's as a JSON tree (what the
    /// engine writes at start, the live catalogs, is an edit of that tree, so the values stay); what the engine derives
    /// from it is computed without a trap.
    @Test func aProjectWithEveryValueLoadsUnchanged() throws {
        var project = testProject(layers: 2, outputs: 0)
        try project.set([Self.cue(trigger: "99999999999999:00:00:00@30")], at: "/cues")
        try project.set(
            .array([
                ["fixture": "Layer 1", "universe": "artnet:0.0.0", "address": .number(Double(Self.lowest))],
                ["fixture": "Layer 2", "universe": "artnet:0.0.0", "address": .number(Double(Self.highest))],
            ]), at: "/patch")
        try project.set(.number(0), at: "/layerCount")
        try Self.hugeCanvas(&project)
        var output = OutputConfig(id: 1)
        output.warp.mesh = Self.hugeMesh
        try project.set(try JSONValue(encoding: [output]), at: "/outputs")
        let wall: JSONValue = [
            "id": 1, "cols": .number(Double(Self.highest)), "rows": 2, "outputs": .array(Array(repeating: 1, count: 1100)), "overlap": ["x": 0, "y": 0],
        ]
        try project.set([wall], at: "/walls")
        let file = tempFile("fanous-project", ext: "json")
        try ProjectDocument.save(project, to: file)
        let loaded = try #require(ProjectDocument.load(from: file))
        let onDisk = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(loaded)) == onDisk)
        #expect(ShowCommands.cueList(from: loaded).cues.first?.timecodeTrigger == nil)
        #expect(ProjectDocument.effectivePatch(from: loaded)?.entries.contains { $0.fitsInUniverse } == false)
        #expect(ProjectDocument.layout(from: loaded).canvases.count == 1)
        #expect(ProjectDocument.wallEntries(from: loaded).walls.count == 1)
        let warp = try #require(ProjectDocument.outputs(from: loaded).first?.warp)
        #expect(WarpMath.field(warp, cols: 4, rows: 4) == WarpMath.field(WarpSettings(), cols: 4, rows: 4))
    }
}
