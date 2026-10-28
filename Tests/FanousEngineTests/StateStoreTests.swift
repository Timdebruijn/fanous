// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Synchronization
import Testing

@testable import FanousEngine

/// A client that records what the store sends; `accepting` false simulates a full send queue.
final class RecordingClient: StateClient, @unchecked Sendable {
    let role: Role
    let messages = Mutex<[JSONValue]>([])
    let accepting = Mutex<Bool>(true)
    let disconnected = Mutex<String?>(nil)

    init(role: Role) { self.role = role }

    func send(text: String, droppable: Bool) -> Bool {
        guard accepting.withLock({ $0 }) else { return false }
        let value = try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        messages.withLock { $0.append(value) }
        return true
    }

    func disconnect(reason: String) { disconnected.withLock { $0 = reason } }

    var patches: [JSONValue] { messages.withLock { $0.filter { $0["t"]?.string == "patch" } } }
}

struct StateStoreTests {
    static let logger = Logger(label: "test")

    static func makeStore() -> (StateStore, RoleAuth) {
        let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: logger)
        let project = ProjectDocument.initial(patch: .standard(layers: 2, outputs: 1), layerCount: 2, libraryRoot: "/tmp/lib", policy: .dmx)
        let store = StateStore(project: project, logger: logger)
        ProjectDocument.registerCommands(on: store, auth: auth)
        return (store, auth)
    }

    @Test func commandProducesPatchAndUndoRestores() throws {
        let (store, _) = Self.makeStore()
        let client = RecordingClient(role: .programmer)
        store.attach(client)
        let result = try store.execute("project.set", args: ["path": "/name", "value": "Tour 2026"], role: .programmer).get()
        #expect(result.rev == 1)
        #expect(store.project["name"]?.string == "Tour 2026")
        let patch = try #require(client.patches.last)
        #expect(patch["doc"]?.string == "project")
        #expect(patch["rev"]?.int == 1)
        #expect(patch["ops"]?.array?.first?["op"]?.string == "replace")
        #expect(patch["ops"]?.array?.first?["path"]?.string == "/name")

        _ = try store.execute("undo", role: .programmer).get()
        #expect(store.project["name"]?.string == "Untitled")
        #expect(store.rev == 2)
        #expect(store.historyDepth == (0, 1))
        _ = try store.execute("redo", role: .programmer).get()
        #expect(store.project["name"]?.string == "Tour 2026")
        #expect(store.historyDepth == (1, 0))
        #expect(client.patches.count == 3)
    }

    @Test func showLockRefusesConfigCommandsOnly() throws {
        let (store, _) = Self.makeStore()
        _ = try store.execute("show.lock", role: .programmer).get()
        #expect(store.isShowLocked)
        let refused = store.execute("project.set", args: ["path": "/name", "value": "x"], role: .programmer)
        #expect(refused == .failure(.showLocked))
        #expect(store.execute("undo", role: .programmer) == .failure(.showLocked))
        _ = try store.execute("show.unlock", role: .programmer).get()
        #expect(!store.isShowLocked)
        _ = try store.execute("project.set", args: ["path": "/name", "value": "x"], role: .programmer).get()
        // lock/unlock are not in the history
        #expect(store.historyDepth.undo == 1)
    }

    @Test func rolesAndValidation() {
        let (store, _) = Self.makeStore()
        #expect(store.execute("project.set", args: ["path": "/name", "value": "x"], role: .operator) == .failure(.forbidden))
        #expect(store.execute("nope", role: .programmer) == .failure(.unknownCommand))
        #expect(store.execute("project.set", args: ["path": "/showLock", "value": true], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("project.set", args: ["path": "/layerCount", "value": 99], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("patch.set", args: ["fixture": "Camera 1", "universe": "artnet:0.0.0", "address": 1], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("patch.set", args: ["fixture": "Layer 1", "universe": "artnet:0.0.0", "address": 500], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("undo", role: .programmer).failureCode == "nothingToUndo")
    }

    @Test func patchSetRewritesTheProjectPatch() throws {
        let (store, _) = Self.makeStore()
        _ = try store.execute("patch.set", args: ["fixture": "Layer 2", "universe": "sacn:3", "address": 129], role: .programmer).get()
        let patch = try #require(ProjectDocument.patch(from: store.project))
        #expect(patch.entry(for: .layer(2)) == PatchEntry(fixture: .layer(2), universe: UniverseID(.sacn, 3), address: 129))
        _ = try store.execute("patch.set", args: ["fixture": "Layer 2", "universe": "sacn:3", "address": 0], role: .programmer).get()
        #expect(ProjectDocument.patch(from: store.project)?.entry(for: .layer(2)) == nil)
        _ = try store.execute("undo", role: .programmer).get()
        #expect(ProjectDocument.patch(from: store.project)?.entry(for: .layer(2))?.address == 129)
    }

    @Test func liveUpdatesAreDiffedAndCoalesced() async throws {
        let (store, _) = Self.makeStore()
        let client = RecordingClient(role: .monitor)
        store.attach(client)
        store.updateLive(["metrics": ["fps": 60], "dmx": ["a": 1]])
        store.updateLive(["metrics": ["fps": 59], "dmx": ["a": 1]])
        store.setLive(.number(58), at: JSONPointer(tokens: ["metrics", "fps"]))
        #expect(await waitUntil { !client.patches.isEmpty })
        let patches = client.patches
        #expect(patches.count == 1)
        let ops = try #require(patches.first?["ops"]?.array)
        // first update adds /metrics and /dmx; the two later fps changes collapse into one op (latest wins)
        #expect(ops.count == 3)
        #expect(Set(ops.compactMap { $0["path"]?.string }) == ["/dmx", "/metrics", "/metrics/fps"])
        #expect(ops.last?["path"]?.string == "/metrics/fps")
        #expect(ops.last?["value"]?.int == 58)
        #expect(store.live["metrics"]?["fps"]?.int == 58)
        store.updateLive(store.live)
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.patches.count == 1)  // no change, no patch
    }

    @Test func laggingClientsDropLiveButNotProject() async throws {
        let (store, _) = Self.makeStore()
        let client = RecordingClient(role: .programmer)
        store.attach(client)
        client.accepting.withLock { $0 = false }
        store.updateLive(["x": 1])
        store.queue.sync {}
        #expect(await waitUntil { store.laggingClients == 1 })
        #expect(client.disconnected.withLock { $0 } == nil)
        _ = try store.execute("project.set", args: ["path": "/name", "value": "x"], role: .programmer).get()
        #expect(client.disconnected.withLock { $0 } != nil)
        #expect(store.clientCount == 0)
    }

    @Test func welcomeCarriesBothDocuments() throws {
        let (store, _) = Self.makeStore()
        let welcome = try JSONDecoder().decode(JSONValue.self, from: Data(store.welcome(role: .operator, caps: ["schema": 1]).utf8))
        #expect(welcome["t"]?.string == "welcome")
        #expect(welcome["role"]?.string == "operator")
        #expect(welcome["rev"]?.int == 0)
        #expect(welcome["project"]?["layerCount"]?.int == 2)
        #expect(welcome["live"] == [:])
        #expect(welcome["caps"]?["schema"]?.int == 1)
    }

    @Test func projectDocumentRoundTripsThePatch() throws {
        let patch = Patch.standard(layers: 16, outputs: 4)
        let document = ProjectDocument.initial(patch: patch, layerCount: 16, libraryRoot: "/x", policy: .ltp)
        #expect(ProjectDocument.patch(from: document) == patch)
        let url = FileManager.default.temporaryDirectory.appending(path: "project-\(UUID().uuidString).json")
        try ProjectDocument.save(document, to: url)
        #expect(ProjectDocument.load(from: url) == document)
        try? FileManager.default.removeItem(at: url)
        #expect(FixtureRef(parsing: "layer 7") == .layer(7))
        #expect(FixtureRef(parsing: "Output 0") == nil)
        #expect(UniverseID(parsing: "artnet:1.2.3") == .artnet(net: 1, subnet: 2, universe: 3))
        #expect(UniverseID(parsing: "sacn:0") == nil)
    }

    @Test func protocolTypesListEveryCommand() {
        let ts = ProtocolTypes.typescript(commands: Engine.commandSpecs())
        for name in ["show.lock", "show.unlock", "undo", "redo", "project.set", "patch.set", "roles.setPassword"] {
            #expect(ts.contains("'\(name)'"), "missing \(name)")
        }
        #expect(ts.contains("export type ClientMessage"))
        #expect(ts.contains("schema: 1"))
    }

    /// B62: the engine sees a change before any client gets its patch, so a client that reacts to the patch at once
    /// (asks for the preview of a new output) finds the engine already knows it. For commands, undo, corrections and redo.
    @Test func projectChangedRunsBeforeClientsGetThePatch() throws {
        let (store, _) = StateStoreTests.makeStore()
        let client = RecordingClient(role: .programmer)
        store.attach(client)
        let seen = Mutex<[(name: String?, patchesSent: Int)]>([])
        store.onProjectChanged = { document in seen.withLock { $0.append((document["name"]?.string, client.patches.count)) } }
        _ = try store.execute("project.set", args: ["path": "/name", "value": "Tour 2026"], role: .programmer).get()
        _ = try store.execute("undo", role: .programmer).get()
        store.correct("Fixed", at: "/name")
        _ = try store.execute("redo", role: .programmer).get()
        let calls = seen.withLock { $0 }
        #expect(calls.map(\.name) == ["Tour 2026", "Untitled", "Fixed", "Tour 2026"])
        #expect(calls.map(\.patchesSent) == [0, 1, 2, 3])
        #expect(client.patches.count == 4)
    }
}

extension Result where Success == CommandResult, Failure == CommandError {
    var failureCode: String? {
        if case .failure(let error) = self { return error.code }
        return nil
    }
}

extension StateStoreTests {
    @Test func layerCountPatchesNewLayersAndDropsRemovedOnes() throws {
        let (store, _) = Self.makeStore()  // 2 layers patched at 1 and 65 on artnet:0.0.0
        _ = try store.execute("layers.setCount", args: ["count": 4], role: .programmer).get()
        var patch = try #require(ProjectDocument.patch(from: store.project))
        #expect(store.project["layerCount"]?.int == 4)
        #expect(patch.entry(for: .layer(3))?.address == 129)
        #expect(patch.entry(for: .layer(4))?.address == 193)
        // a layer whose standard range is taken stays unpatched
        _ = try store.execute("patch.set", args: ["fixture": "Layer 4", "universe": "artnet:0.0.0", "address": 300], role: .programmer).get()
        _ = try store.execute("layers.setCount", args: ["count": 5], role: .programmer).get()
        patch = try #require(ProjectDocument.patch(from: store.project))
        #expect(patch.entry(for: .layer(5)) == nil, "257–320 overlaps Layer 4 at 300")
        _ = try store.execute("layers.setCount", args: ["count": 2], role: .programmer).get()
        patch = try #require(ProjectDocument.patch(from: store.project))
        #expect(patch.entry(for: .layer(3)) == nil && patch.entry(for: .layer(4)) == nil)
        #expect(ProjectDocument.effectivePatch(from: store.project)?.entries.count == patch.entries.count)
        #expect(store.execute("layers.setCount", args: ["count": 65], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("project.set", args: ["path": "/layerCount", "value": 3], role: .programmer).failureCode == "invalidArgs")
        _ = try store.execute("undo", role: .programmer).get()
        #expect(store.project["layerCount"]?.int == 5)
    }
}

extension StateStoreTests {
    @Test func outputCommandsAddSetValidateAndRemove() throws {
        let (store, _) = Self.makeStore()
        let id = try store.execute("output.add", args: ["display": ["uuid": "U1", "name": "Epson"]], role: .programmer).get().value?.int
        #expect(id == 1)
        var outputs = ProjectDocument.outputs(from: store.project)
        #expect(outputs.count == 1 && outputs[0].display?.uuid == "U1" && outputs[0].slices.count == 1)
        _ = try store.execute("output.set", args: ["id": 1, "path": "/blend/right/overlap", "value": 240], role: .programmer).get()
        _ = try store.execute("output.set", args: ["id": 1, "path": "/warp/mesh", "value": ["cols": 3, "rows": 3, "points": .array((0..<9).map { ["x": .number(Double($0 % 3) / 2), "y": .number(Double($0 / 3) / 2)] })]], role: .programmer).get()
        _ = try store.execute("output.set", args: ["id": 1, "path": "/intensity", "value": 7], role: .programmer).get()
        outputs = ProjectDocument.outputs(from: store.project)
        #expect(outputs[0].blend.right.overlap == 240)
        #expect(outputs[0].warp.mesh?.cols == 3)
        #expect(outputs[0].intensity == 1, "clamped")
        #expect(store.execute("output.set", args: ["id": 1, "path": "/warp/mesh/cols", "value": 40], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("output.set", args: ["id": 1, "path": "/slices", "value": []], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("output.set", args: ["id": 1, "path": "/id", "value": 9], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("output.set", args: ["id": 2, "path": "/name", "value": "x"], role: .programmer).failureCode == "invalidArgs")
        _ = try store.execute("output.add", role: .programmer).get()
        #expect(ProjectDocument.outputs(from: store.project).map(\.id) == [1, 2])
        _ = try store.execute("output.remove", args: ["id": 1], role: .programmer).get()
        #expect(ProjectDocument.outputs(from: store.project).map(\.id) == [2])
        _ = try store.execute("undo", role: .programmer).get()
        #expect(ProjectDocument.outputs(from: store.project).map(\.id) == [1, 2])
        _ = try store.execute("canvas.set", args: ["id": 1, "path": "/clockMaster", "value": 2], role: .programmer).get()
        #expect(ProjectDocument.canvases(from: store.project).first?.clockMaster == 2)
        #expect(store.execute("canvas.set", args: ["id": 1, "path": "/width", "value": 10], role: .programmer).failureCode == "invalidArgs")
    }

    /// B51: `project.set /library/root` expands `~`, normalises the path and asks the engine; refusals leave the project as it was.
    @Test func libraryRootIsNormalisedAndChecked() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "fanous-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: Self.logger)
        let store = StateStore(project: ProjectDocument.initial(patch: .standard(layers: 1, outputs: 1), layerCount: 1, libraryRoot: "/tmp/lib", policy: .dmx), logger: Self.logger)
        let state = Mutex((showMode: false, ingestBusy: false))
        ProjectDocument.registerCommands(
            on: store, auth: auth,
            checkLibraryRoot: { path in
                let s = state.withLock { $0 }
                if let refusal = Engine.libraryRootRefusal(path, showMode: s.showMode, ingestBusy: s.ingestBusy) { throw refusal }
            })
        func set(_ value: JSONValue) -> Result<CommandResult, CommandError> { store.execute("project.set", args: ["path": "/library/root", "value": value], role: .programmer) }

        _ = try set(.string(root.path + "/")).get()
        let canonical = URL(fileURLWithPath: root.path).standardizedFileURL.path
        #expect(store.project["library"]?["root"]?.string == canonical)
        #expect(set("relative/path").failureCode == "invalidArgs")
        #expect(set(.string(root.appending(path: "missing").path)).failureCode == "invalidArgs")
        #expect(set(1).failureCode == "invalidArgs")
        #expect(set("~").failureCode == nil && store.project["library"]?["root"]?.string == NSHomeDirectory())
        state.withLock { $0.showMode = true }
        #expect(set(.string(root.path)).failureCode == "showMode")
        state.withLock { $0 = (false, true) }
        #expect(set(.string(root.path)).failureCode == "ingestBusy")
        #expect(store.project["library"]?["root"]?.string == NSHomeDirectory())
        state.withLock { $0.ingestBusy = false }
        _ = try store.execute("show.lock", role: .programmer).get()
        #expect(set(.string(root.path)) == .failure(.showLocked))
    }

    @Test func canvasSetChangesSizeAndRateWithinLimits() throws {
        let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: Self.logger)
        let store = StateStore(project: ProjectDocument.initial(patch: .standard(layers: 2, outputs: 1), layerCount: 2, libraryRoot: "/tmp/lib", policy: .dmx), logger: Self.logger)
        let showMode = Mutex(false)
        ProjectDocument.registerCommands(on: store, auth: auth, showModeOn: { showMode.withLock { $0 } })
        func format(_ w: Int, _ h: Int, _ fps: Double) -> JSONValue { ["id": 1, "width": .number(Double(w)), "height": .number(Double(h)), "fps": .number(fps)] }
        #expect(ProjectDocument.canvases(from: store.project).first?.fps == 60)

        _ = try store.execute("canvas.set", args: format(3840, 2160, 50), role: .programmer).get()
        var canvas = try #require(ProjectDocument.canvases(from: store.project).first)
        #expect((canvas.width, canvas.height, canvas.fps) == (3840, 2160, 50))
        _ = try store.execute("canvas.set", args: format(1280, 720, 24000.0 / 1001), role: .programmer).get()
        #expect(ProjectDocument.canvases(from: store.project).first?.fps == 23.976, "snapped to the list entry")

        for bad in [format(1921, 1080, 60), format(200, 200, 60), format(8194, 1080, 60), format(1920, 1080, 48), format(1920, 1080, 0)] {
            #expect(store.execute("canvas.set", args: bad, role: .programmer).failureCode == "invalidArgs")
        }
        #expect(store.execute("canvas.set", args: format(1920, 1080, 60), role: .operator).failureCode == "forbidden")
        showMode.withLock { $0 = true }
        #expect(store.execute("canvas.set", args: format(1920, 1080, 60), role: .programmer).failureCode == "showMode")
        _ = try store.execute("canvas.set", args: ["id": 1, "path": "/name", "value": "Main"], role: .programmer).get()
        showMode.withLock { $0 = false }
        _ = try store.execute("show.lock", role: .programmer).get()
        #expect(store.execute("canvas.set", args: format(1920, 1080, 60), role: .programmer) == .failure(.showLocked))
        _ = try store.execute("show.unlock", role: .programmer).get()

        _ = try store.execute("undo", role: .programmer).get()  // the name
        _ = try store.execute("undo", role: .programmer).get()  // 1280×720
        canvas = try #require(ProjectDocument.canvases(from: store.project).first)
        #expect((canvas.width, canvas.height, canvas.fps, canvas.name) == (3840, 2160, 50, "Canvas 1"))
    }

    /// B60: `sync.set` validates, writes `settings.json` › `sync` next to the passwords, applies, and is refused in show mode.
    @Test func syncSetValidatesSavesAndApplies() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "settings.json")
        let auth = RoleAuth(settingsURL: file, shellTokenURL: nil, iterations: 1000, logger: Self.logger)
        try auth.setPassword("pw", for: .programmer)
        let store = StateStore(project: ProjectDocument.initial(patch: .standard(layers: 1, outputs: 1), layerCount: 1, libraryRoot: "/x", policy: .dmx), logger: Self.logger)
        let showMode = Mutex(false), applied = Mutex<[SyncSettings]>([])
        ProjectDocument.registerCommands(
            on: store, auth: auth, showModeOn: { showMode.withLock { $0 } }, applySync: { s in applied.withLock { $0.append(s) } })
        func stored() throws -> JSONValue? { try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))["sync"] }

        _ = try store.execute("sync.set", args: ["port": 48812, "target": "127.0.0.1:48813"], role: .programmer).get()
        #expect(try stored() == ["port": 48812, "target": "127.0.0.1:48813"], "only the members given are written")
        _ = try store.execute("sync.set", args: ["interface": "en0", "target": "broadcast"], role: .programmer).get()
        #expect(try stored() == ["interface": "en0", "port": 48812, "target": "broadcast"], "fields left out keep their value")
        #expect(applied.withLock { $0.map(\.port) } == [48812, 48812])
        #expect(auth.verify("pw", for: .programmer), "the passwords stay in the file")
        #expect(MachineSettings.load(from: file).sync?.interface == "en0")
        #expect(store.rev == 0, "a machine setting, not a project change")

        for bad: JSONValue in [
            [:], ["port": 0], ["port": 65536], ["port": 8002.5], ["port": "8002"], ["port": 6454], ["port": 5568], ["port": 8000], ["port": 8001],
            ["interface": ""], ["interface": 1],
            ["target": "nope"], ["target": "10.0.0.256"], ["target": "10.0.0.2:0"], ["target": "10.0.0.2:x"], ["target": "10.0.0.2:1:2"],
        ] {
            #expect(store.execute("sync.set", args: bad, role: .programmer).failureCode == "invalidArgs", "\(bad)")
        }
        #expect(store.execute("sync.set", args: ["port": 9000], role: .operator).failureCode == "forbidden")
        showMode.withLock { $0 = true }
        #expect(store.execute("sync.set", args: ["port": 9000], role: .programmer).failureCode == "showMode")
        #expect(try stored()?["port"]?.int == 48812)
        #expect(applied.withLock { $0.count } == 2)
    }

    /// B31: undo in show mode changes the project but not the render until show mode ends; a failed switch puts the
    /// rendered canvas back into the project and reports the error.
    @MainActor @Test func canvasSwitchDefersInShowModeAndRevertsOnFailure() async throws {
        let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: Self.logger)
        let store = StateStore(project: ProjectDocument.initial(patch: .standard(layers: 1, outputs: 1), layerCount: 1, libraryRoot: "/x", policy: .dmx), logger: Self.logger)
        let showMode = Mutex(false), fail = Mutex(false), applied = Mutex<[Int]>([])
        ProjectDocument.registerCommands(on: store, auth: auth, showModeOn: { showMode.withLock { $0 } })
        let switcher = CanvasSwitch(
            rendered: ProjectDocument.CanvasLayout(ProjectDocument.defaultCanvas), isDeferred: { showMode.withLock { $0 } },
            apply: { layout in
                if fail.withLock({ $0 }) { throw RenderError.pipeline("no memory") }
                applied.withLock { $0.append(layout.first.width) }
            },
            revert: { rendered, _ in
                var project = store.project
                try? ProjectDocument.setCanvasLayout(rendered, in: &project)
                store.correct(project["canvases"]!, at: "/canvases")
            })
        store.onProjectChanged = { document in switcher.request(ProjectDocument.layout(from: document)) }
        func settle() async throws { for _ in 0..<50 { try await Task.sleep(for: .milliseconds(5)) } }

        _ = try store.execute("canvas.set", args: ["id": 1, "width": 3840, "height": 2160, "fps": 50], role: .programmer).get()
        try await settle()
        #expect(applied.withLock { $0 } == [3840])
        showMode.withLock { $0 = true }
        _ = try store.execute("undo", role: .programmer).get()
        try await settle()
        #expect(ProjectDocument.canvases(from: store.project).first?.width == 1920)
        #expect(applied.withLock { $0 } == [3840], "not applied in show mode")
        #expect(switcher.live["pending"]?.bool == true && switcher.live["width"]?.int == 3840)
        showMode.withLock { $0 = false }
        switcher.run()  // the engine calls this when show mode ends
        try await settle()
        #expect(applied.withLock { $0 } == [3840, 1920])
        #expect(switcher.live["pending"]?.bool == false)

        fail.withLock { $0 = true }
        _ = try store.execute("canvas.set", args: ["id": 1, "width": 1280, "height": 720, "fps": 25], role: .programmer).get()
        try await settle()
        let canvas = try #require(ProjectDocument.canvases(from: store.project).first)
        #expect((canvas.width, canvas.fps) == (1920, 60), "the rendered canvas is back in the project")
        #expect(switcher.live["error"]?.string?.contains("no memory") == true && switcher.live["pending"]?.bool == false)
    }

    /// Multiple canvases: add (shared rate, cap), per-layer assignment, slices on a canvas, remove moves both to canvas 1.
    @Test func canvasAddRemoveAndLayerAssignment() throws {
        let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: Self.logger)
        let store = StateStore(project: ProjectDocument.initial(patch: .standard(layers: 8, outputs: 1), layerCount: 8, libraryRoot: "/x", policy: .dmx), logger: Self.logger)
        let showMode = Mutex(false)
        ProjectDocument.registerCommands(on: store, auth: auth, showModeOn: { showMode.withLock { $0 } })
        func ids() -> [Int] { ProjectDocument.canvases(from: store.project).map(\.id) }

        #expect(try store.execute("canvas.add", args: ["width": 1280, "height": 720], role: .programmer).get().value == 2)
        let wall = try #require(ProjectDocument.canvases(from: store.project).last)
        #expect((wall.name, wall.width, wall.height, wall.fps) == ("Canvas 2", 1280, 720, 60))
        #expect(store.execute("canvas.add", args: ["width": 1280, "height": 720, "fps": 50], role: .programmer).failureCode == "invalidArgs", "one shared rate")
        #expect(store.execute("canvas.add", args: ["width": 1281, "height": 720], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("canvas.add", args: ["width": 1280, "height": 720], role: .operator).failureCode == "forbidden")
        showMode.withLock { $0 = true }
        #expect(store.execute("canvas.add", args: ["width": 1280, "height": 720], role: .programmer).failureCode == "showMode")
        #expect(store.execute("canvas.remove", args: ["id": 2], role: .programmer).failureCode == "showMode")
        showMode.withLock { $0 = false }
        _ = try store.execute("canvas.add", args: ["width": 640, "height": 480, "fps": 60, "name": "Side"], role: .programmer).get()
        _ = try store.execute("canvas.add", args: ["width": 640, "height": 480], role: .programmer).get()
        #expect(ids() == [1, 2, 3, 4])
        #expect(store.execute("canvas.add", args: ["width": 640, "height": 480], role: .programmer).failureCode == "invalidArgs", "at most 4")
        _ = try store.execute("canvas.remove", args: ["id": 4], role: .programmer).get()

        // the rate: canvas 1 changes it for all, another canvas may not differ
        _ = try store.execute("canvas.set", args: ["id": 1, "width": 1920, "height": 1080, "fps": 50], role: .programmer).get()
        #expect(ProjectDocument.canvases(from: store.project).allSatisfy { $0.fps == 50 })
        #expect(store.execute("canvas.set", args: ["id": 2, "width": 1280, "height": 720, "fps": 60], role: .programmer).failureCode == "invalidArgs")
        _ = try store.execute("canvas.set", args: ["id": 2, "width": 1920, "height": 1080, "fps": 50], role: .programmer).get()
        #expect(ProjectDocument.layout(from: store.project).canvases.map(\.width) == [1920, 1920, 640])

        // layers 5–8 on canvas 2
        for layer in 5...8 { _ = try store.execute("layer.set", args: ["layer": .number(Double(layer)), "canvas": 2], role: .programmer).get() }
        #expect(ProjectDocument.layerCanvases(from: store.project) == [5: 2, 6: 2, 7: 2, 8: 2])
        #expect(Engine.layerCanvas(project: store.project, layers: 8) == [1, 1, 1, 1, 2, 2, 2, 2])
        #expect(store.execute("layer.set", args: ["layer": 9, "canvas": 2], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("layer.set", args: ["layer": 1, "canvas": 7], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("layer.set", args: ["layer": 1, "canvas": 2], role: .operator).failureCode == "forbidden")
        _ = try store.execute("layer.set", args: ["layer": 8, "canvas": 1], role: .programmer).get()
        #expect(ProjectDocument.layerCanvases(from: store.project)[8] == nil, "canvas 1 is stored as the default")

        // a slice on canvas 2; a canvas that does not exist is refused
        _ = try store.execute("output.add", role: .programmer).get()
        _ = try store.execute("output.set", args: ["id": 1, "path": "/slices/0/canvas", "value": 2], role: .programmer).get()
        #expect(ProjectDocument.outputs(from: store.project)[0].slices[0].canvas == 2)
        #expect(store.execute("output.set", args: ["id": 1, "path": "/slices/0/canvas", "value": 9], role: .programmer).failureCode == "invalidArgs")

        // remove: canvas 1 never, the others move their layers and slices to canvas 1 in one undo step
        #expect(store.execute("canvas.remove", args: ["id": 1], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("canvas.remove", args: ["id": 9], role: .programmer).failureCode == "invalidArgs")
        _ = try store.execute("canvas.remove", args: ["id": 2], role: .programmer).get()
        #expect(ids() == [1, 3])
        #expect(ProjectDocument.layerCanvases(from: store.project).isEmpty)
        #expect(ProjectDocument.outputs(from: store.project)[0].slices[0].canvas == 1)
        _ = try store.execute("show.lock", role: .programmer).get()
        #expect(store.execute("layer.set", args: ["layer": 1, "canvas": 3], role: .programmer) == .failure(.showLocked))
        #expect(store.execute("canvas.add", args: ["width": 640, "height": 480], role: .programmer) == .failure(.showLocked))
        _ = try store.execute("show.unlock", role: .programmer).get()
        _ = try store.execute("undo", role: .programmer).get()
        #expect(ids() == [1, 2, 3])
        #expect(ProjectDocument.layerCanvases(from: store.project) == [5: 2, 6: 2, 7: 2])
        #expect(ProjectDocument.outputs(from: store.project)[0].slices[0].canvas == 2)

        // fewer layers drop their assignment
        _ = try store.execute("layers.setCount", args: ["count": 6], role: .programmer).get()
        #expect(ProjectDocument.layerCanvases(from: store.project) == [5: 2, 6: 2])

        // a failed switch writes the rendered layout back: canvas 3 goes, canvas 2 keeps its name
        var project = store.project
        try ProjectDocument.setCanvasLayout(.init(fps: 50, canvases: [.init(id: 1, width: 1920, height: 1080), .init(id: 2, width: 1280, height: 720)]), in: &project)
        #expect(ProjectDocument.canvases(from: project).map(\.id) == [1, 2] && ProjectDocument.canvases(from: project)[1].width == 1280)
        // …and what was put on canvas 3 meanwhile goes back to canvas 1
        _ = try store.execute("layer.set", args: ["layer": 6, "canvas": 3], role: .programmer).get()
        project = store.project
        try ProjectDocument.moveToCanvas1(keeping: [1, 2], in: &project)
        #expect(ProjectDocument.layerCanvases(from: project) == [5: 2])

        // GPU memory: all canvases together at most 4 × UHD
        _ = try store.execute("canvas.set", args: ["id": 2, "width": 7680, "height": 3840, "fps": 50], role: .programmer).get()
        let tooMuch = store.execute("canvas.set", args: ["id": 3, "width": 3840, "height": 2160, "fps": 50], role: .programmer)
        #expect(tooMuch.failureCode == "invalidArgs")
        #expect(store.execute("canvas.add", args: ["width": 3840, "height": 2160], role: .programmer).failureCode == "invalidArgs")
    }

    /// While a canvas does not render (switch deferred in show mode, or failed), its layers draw into canvas 1 and the
    /// slices that show it show canvas 1; a slice on a canvas the project does not have stays black.
    @Test func layersAndSlicesWaitingForACanvasUseCanvas1() {
        var output = OutputConfig(id: 1)
        output.slices = [SliceConfig(id: 1), SliceConfig(id: 2), SliceConfig(id: 3)]
        output.slices[1].canvas = 2
        output.slices[2].canvas = 9
        let use = Engine.effectiveCanvasUse(layers: [1, 2, 3], outputs: [output], rendering: [1, 3], project: [1, 2, 3])
        #expect(use.layers == [1, 1, 3])
        #expect(use.outputs[0].slices.map(\.canvas) == [1, 1, 9])
        let rendering = Engine.effectiveCanvasUse(layers: [1, 2, 3], outputs: [output], rendering: [1, 2, 3], project: [1, 2, 3])
        #expect(rendering.layers == [1, 2, 3] && rendering.outputs == [output])
    }

    @Test func projectCanvasWinsOverSceneDefaultsAndASceneFileWinsOverTheProject() throws {
        var project = ProjectDocument.initial(patch: .standard(layers: 1, outputs: 1), layerCount: 1, libraryRoot: "/x", policy: .dmx)
        #expect(Engine.startCanvas(project: nil, scene: nil) == (1920, 1080, 60))
        try ProjectDocument.setCanvasFormat((3840, 2160, 50), in: &project)
        #expect(Engine.startCanvas(project: project, scene: nil) == (3840, 2160, 50))
        var scene = SceneConfig()
        scene.canvasWidth = 1280
        scene.canvasHeight = 720
        scene.fps = 30
        #expect(Engine.startCanvas(project: project, scene: scene) == (1280, 720, 30))
        try ProjectDocument.setCanvasFormat((7, 7, 13), in: &project)  // hand-edited
        #expect(Engine.startCanvas(project: project, scene: nil) == (1920, 1080, 60))

        // a project saved before canvases had a rate reads as 60
        let old = try JSONDecoder().decode(CanvasConfig.self, from: Data(#"{"id":1,"name":"Canvas 1","width":1920,"height":1080}"#.utf8))
        #expect(old.fps == 60)
    }

    @Test func removingTheClockMasterOutputClearsIt() throws {
        let (store, _) = Self.makeStore()
        _ = try store.execute("output.add", role: .programmer).get()
        _ = try store.execute("output.add", role: .programmer).get()
        _ = try store.execute("canvas.set", args: ["id": 1, "path": "/clockMaster", "value": 2], role: .programmer).get()
        _ = try store.execute("output.remove", args: ["id": 1], role: .programmer).get()
        #expect(ProjectDocument.canvases(from: store.project).first?.clockMaster == 2)
        _ = try store.execute("output.remove", args: ["id": 2], role: .programmer).get()
        #expect(ProjectDocument.canvases(from: store.project).first?.clockMaster == nil)
        _ = try store.execute("undo", role: .programmer).get()
        #expect(ProjectDocument.canvases(from: store.project).first?.clockMaster == 2, "one undo restores both")
    }

    @Test func dragEditsFromOneClientCoalesceIntoOneUndoStep() throws {
        let (store, _) = Self.makeStore()
        _ = try store.execute("output.add", role: .programmer).get()
        let a = RecordingClient(role: .programmer), b = RecordingClient(role: .programmer)
        let before = store.historyDepth.undo
        for v in [10, 20, 30] { _ = try store.execute("output.set", args: ["id": 1, "path": "/blend/right/overlap", "value": .number(Double(v))], role: .programmer, from: a).get() }
        #expect(store.historyDepth.undo == before + 1)
        _ = try store.execute("output.set", args: ["id": 1, "path": "/blend/right/overlap", "value": 40], role: .programmer, from: b).get()
        _ = try store.execute("output.set", args: ["id": 1, "path": "/blend/left/overlap", "value": 5], role: .programmer, from: b).get()
        #expect(store.historyDepth.undo == before + 3, "another client or another path starts a new entry")
        _ = try store.execute("undo", role: .programmer).get()
        _ = try store.execute("undo", role: .programmer).get()
        #expect(ProjectDocument.outputs(from: store.project)[0].blend.right.overlap == 30)
        _ = try store.execute("undo", role: .programmer).get()
        #expect(ProjectDocument.outputs(from: store.project)[0].blend.right.overlap == 0, "the whole drag undoes at once")
        _ = try store.execute("redo", role: .programmer).get()
        #expect(ProjectDocument.outputs(from: store.project)[0].blend.right.overlap == 30)
    }

    @Test func outputBindingResolvesByIdentityAndElectsTheMaster() {
        let displays = [
            DisplayInfo(id: 7, uuid: "A", name: "LG", pixelWidth: 3840, pixelHeight: 2160, scale: 2, hz: 60, isMain: true, isBuiltin: false, modes: []),
            DisplayInfo(id: 9, uuid: "B", name: "Epson", pixelWidth: 1920, pixelHeight: 1200, scale: 1, hz: 60, isMain: false, isBuiltin: false, modes: []),
        ]
        var left = OutputConfig(id: 1), right = OutputConfig(id: 2), gone = OutputConfig(id: 3), free = OutputConfig(id: 4)
        left.display = DisplayIdentity(uuid: "B", name: "Epson")
        right.display = DisplayIdentity(uuid: "B", name: "Epson")
        gone.display = DisplayIdentity(uuid: "Z", name: "Unplugged")
        let binding = OutputBinding.resolve(outputs: [left, right, gone, free], displays: displays)
        #expect(binding.byDisplay == [9: [1, 2]])
        #expect(binding.lost == [3] && binding.unassigned == [4])
        #expect(OutputBinding.master(outputs: [left, right, gone, free], binding: binding, clockMaster: nil) == 9)
        #expect(OutputBinding.master(outputs: [left, right, gone, free], binding: binding, clockMaster: 3) == 9, "a lost clock master falls back to the first bound output")
        // unplug B: everything on it is lost, the master is gone
        let after = OutputBinding.resolve(outputs: [left, right, gone, free], displays: [displays[0]])
        #expect(after.byDisplay.isEmpty && after.lost == [1, 2, 3])
        #expect(OutputBinding.master(outputs: [left, right, gone, free], binding: after, clockMaster: nil) == nil)
    }
}

struct StateStoreRedactionTests {
    @Test func rolesGetRedactedDocumentsAndPatches() throws {
        let (store, _) = StateStoreTests.makeStore()
        store.setLive("/Users/x/lib", at: JSONPointer(tokens: ["library", "root"]))
        store.queue.sync {}
        let monitor = RecordingClient(role: .monitor)
        let programmer = RecordingClient(role: .programmer)
        store.attach(monitor)
        store.attach(programmer)

        let welcome = try JSONDecoder().decode(JSONValue.self, from: Data(store.welcome(role: .monitor, caps: [:]).utf8))
        #expect(welcome["project"]?["library"]?["root"]?.string == "")
        #expect(welcome["live"]?["library"]?["root"]?.string == "")
        let full = try JSONDecoder().decode(JSONValue.self, from: Data(store.welcome(role: .programmer, caps: [:]).utf8))
        #expect(full["project"]?["library"]?["root"]?.string == "/tmp/lib")

        _ = try store.execute("project.set", args: ["path": "/library/root", "value": "/elsewhere"], role: .programmer).get()
        #expect(monitor.patches.last?["ops"]?.array?.first?["value"]?.string == "")
        #expect(monitor.patches.last?["rev"] == programmer.patches.last?["rev"])
        #expect(programmer.patches.last?["ops"]?.array?.first?["value"]?.string == "/elsewhere")
        #expect(store.snapshot(role: .monitor).contains("/elsewhere") == false)
    }
}

extension StateStoreTests {
    /// B69: forget one number or every one not running; never a running one; programmer, undoable, refused under show lock.
    @Test func syphonForgetFreesNumbersThatAreNotRunning() throws {
        let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: Self.logger)
        var project = ProjectDocument.initial(patch: .standard(layers: 2, outputs: 1), layerCount: 2, libraryRoot: "/tmp/lib", policy: .dmx)
        let numbers = [(150, "Resolume"), (151, "Simple Server"), (152, "MadMapper")].map { SyphonCatalog.Server(file: $0.0, app: $0.1, server: "") }
        try project.set(ProjectDocument.syphonValue(numbers), at: "/syphon")
        let store = StateStore(project: project, logger: Self.logger)
        ProjectDocument.registerCommands(on: store, auth: auth, syphonRunning: { [150] })
        func files() -> [Int] { ProjectDocument.syphonNumbers(from: store.project).map(\.file) }

        #expect(store.execute("syphon.forget", args: ["file": 151], role: .operator).failureCode == "forbidden")
        #expect(store.execute("syphon.forget", args: ["file": 150], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("syphon.forget", args: ["file": 160], role: .programmer).failureCode == "invalidArgs")
        _ = try store.execute("syphon.forget", args: ["file": 151], role: .programmer).get()
        #expect(files() == [150, 152])
        _ = try store.execute("undo", role: .programmer).get()
        #expect(files() == [150, 151, 152])
        _ = try store.execute("syphon.forget", role: .programmer).get()
        #expect(files() == [150])

        _ = try store.execute("show.lock", role: .programmer).get()
        #expect(store.execute("undo", role: .programmer) == .failure(.showLocked))
        #expect(store.execute("syphon.forget", role: .programmer) == .failure(.showLocked))
        // the engine's own numbering still lands under show lock (a new server numbered mid-show)
        store.correct(at: "/syphon") { ProjectDocument.syphonValue(numbers) }
        #expect(files() == [150, 151, 152])
    }

    /// Keyed by file, a forget and its undo touch one key: numbers recorded in between stay (B69).
    @Test func syphonForgetUndoKeepsNumbersRecordedMeanwhile() throws {
        let (store, _) = Self.makeStore()
        func server(_ file: Int, _ app: String) -> SyphonCatalog.Server { SyphonCatalog.Server(file: file, app: app, server: "") }
        func files() -> [Int] { ProjectDocument.syphonNumbers(from: store.project).map(\.file) }
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([server(150, "A"), server(153, "X")]) }
        _ = try store.execute("syphon.forget", args: ["file": 153], role: .programmer).get()
        // Y and Z get numbers (the engine records them); Z then stops, its entry stays
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([server(150, "A"), server(151, "Y"), server(152, "Z")]) }
        _ = try store.execute("undo", role: .programmer).get()
        #expect(files() == [150, 151, 152, 153])
        #expect(ProjectDocument.syphonNumbers(from: store.project).map(\.app) == ["A", "Y", "Z", "X"])
    }

    /// The engine records a new number with no client connected (a headless show driven by a console, B69).
    @Test func syphonNumbersAreRecordedWithoutClients() {
        let (store, _) = Self.makeStore()
        let catalog = SyphonCatalog()
        catalog.update(running: [SyphonInput.ServerInfo(appName: "Resolume", serverName: "Out", uuid: "a")])
        #expect(store.clientCount == 0)
        Engine.recordSyphonNumbers(catalog, into: store, applied: store.project["syphon"] ?? [:])
        #expect(store.project["syphon"]?["150"]?["app"]?.string == "Resolume")
    }
}

struct LibraryRedactionTests {
    @Test func monitorSnapshotHasNoAbsolutePaths() {
        let item = LibraryItem(folder: 1, file: 1, name: "a.mov", path: "/Users/x/lib/001_a/001_a.mov", kind: .movie, status: .playable, reason: nil, metadata: nil, thumbnail: nil, modified: 0, size: 1)
        let snapshot = LibrarySnapshot(root: "/Users/x/lib", rootExists: true, folders: [LibraryFolder(number: 1, name: "a", path: "/Users/x/lib/001_a", items: [item])], scannedAt: 0, fileCount: 1, invalidCount: 0)
        let redacted = snapshot.redacted()
        #expect(redacted.root == "")
        #expect(redacted.folders[0].path == "001_a")
        #expect(redacted.folders[0].items[0].path == "001_a/001_a.mov")
        #expect(redacted.fileCount == 1)
    }

    @Test func admitSendsRedactedWelcomeAndSetsRoleAtomically() throws {
        let (store, _) = StateStoreTests.makeStore()
        let client = RecordingClient(role: .monitor)
        var set = false
        store.admit(client, role: .monitor, caps: [:]) { set = true }
        #expect(set)
        #expect(client.messages.withLock { $0.first?["t"]?.string } == "welcome")
        #expect(client.messages.withLock { $0.first?["project"]?["library"]?["root"]?.string } == "")
        #expect(store.clientCount == 1)
    }
}
