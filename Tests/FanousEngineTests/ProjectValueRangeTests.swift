// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Darwin
import FanousCore
import Foundation
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

    /// The check a version passes before it is restored now holds what its message says: the patch fits. Failed (the
    /// version was restorable), did not trap, on the old code.
    @Test func aVersionWithAnAddressOutsideTheUniverseIsNotRestored() throws {
        var project = testProject(layers: 2, outputs: 0)
        try project.set(.array([["fixture": "Layer 1", "universe": "artnet:0.0.0", "address": .number(Double(Self.lowest))]]), at: "/patch")
        #expect(throws: CommandError.invalidArgs("this version cannot be restored: the patch has an unknown fixture, universe or address")) {
            try ProjectVersions.checkRestorable(project)
        }
    }
}

/// B266 end to end: the built `fanousd` started on a temporary home with a project that holds every value above at once.
@Suite(.cleansTempFiles)
struct ProjectValueRangeEngineTests {
    private final class InThisBundle {}
    /// `fanousd` next to the test bundle (`swift build` makes it); nil when it is not there.
    static let fanousd: URL? = Optional(Bundle(for: InThisBundle.self).bundleURL.deletingLastPathComponent().appending(path: "fanousd"))
        .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }

    /// A TCP port on 127.0.0.1 that was free a moment ago.
    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        try #require(bound)
        return UInt16(bigEndian: address.sin_port)
    }

    @Test(.enabled(if: fanousd != nil, "fanousd is not built"))
    func theEngineRunsOnEveryBadValueAndKeepsTheFile() async throws {
        let home = try tempDir("b266-home")
        try #require(home.path.hasPrefix("/"), "FANOUS_HOME must be absolute, or the engine opens the real home")
        let support = home.appending(path: "Library/Application Support/Fanous")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        // never the installed engine's sync port (8002)
        try Data(#"{"sync":{"port":\#(try Self.freePort())}}"#.utf8).write(to: support.appending(path: "settings.json"))

        var project = testProject(layers: 2, outputs: 0, libraryRoot: home.appending(path: "library").path)
        try project.set([ProjectValueRangeTests.cue(trigger: "99999999999999:00:00:00@30")], at: "/cues")
        try project.set(
            .array([
                ["fixture": "Layer 1", "universe": "artnet:0.0.0", "address": .number(Double(ProjectValueRangeTests.lowest))],
                ["fixture": "Layer 2", "universe": "artnet:0.0.0", "address": .number(Double(ProjectValueRangeTests.highest))],
            ]), at: "/patch")
        try project.set(.number(0), at: "/layerCount")
        try ProjectValueRangeTests.hugeCanvas(&project)
        var output = OutputConfig(id: 1)
        output.warp.mesh = ProjectValueRangeTests.hugeMesh
        try project.set(try JSONValue(encoding: [output]), at: "/outputs")
        let file = support.appending(path: "project.json")
        try ProjectDocument.save(project, to: file)
        let before = try Data(contentsOf: file)

        let process = Process()
        process.executableURL = Self.fanousd
        process.arguments = ["--foreground", "--no-network", "--port", String(try Self.freePort()), "--web-root", home.path]
        process.environment = ["FANOUS_HOME": home.path, "PATH": "/usr/bin:/bin"]
        let log = home.appending(path: "engine.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        (process.standardOutput, process.standardError) = (handle, handle)
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        func logText() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
        #expect(await waitUntil(.seconds(60)) { logText().contains("HTTPS listening") || !process.isRunning }, "the engine starts")
        try await Task.sleep(for: .seconds(2))  // a negative check: nothing may kill it after the start
        #expect(process.isRunning, "the engine still runs: \(logText().suffix(2000))")
        process.terminate()
        #expect(await waitUntil(.seconds(20)) { !process.isRunning })

        let names = try FileManager.default.contentsOfDirectory(atPath: support.path)
        #expect(!names.contains { $0.contains("unreadable") }, "nothing set aside: \(names)")
        let after = try Data(contentsOf: file)
        if after != before {
            // the engine writes the live sources it numbers (Syphon servers, cameras, displays of this Mac) into the
            // project, which rewrites the file; everything else in it must be what the file held
            func withoutLive(_ data: Data) throws -> JSONValue {
                guard case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
                for kind in LiveCatalog.Kind.allCases { fields[kind.rawValue] = nil }
                return .object(fields)
            }
            #expect(try withoutLive(after) == withoutLive(before))
        }
    }
}
