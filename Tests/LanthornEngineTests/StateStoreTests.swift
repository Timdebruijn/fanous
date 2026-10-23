// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import LanthornCore
import Logging
import Synchronization
import Testing

@testable import LanthornEngine

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
        try await Task.sleep(for: .milliseconds(150))
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

    @Test func laggingClientsDropLiveButNotProject() throws {
        let (store, _) = Self.makeStore()
        let client = RecordingClient(role: .programmer)
        store.attach(client)
        client.accepting.withLock { $0 = false }
        store.updateLive(["x": 1])
        store.queue.sync {}
        Thread.sleep(forTimeInterval: 0.1)
        #expect(store.laggingClients == 1)
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
}

extension Result where Success == CommandResult, Failure == CommandError {
    var failureCode: String? {
        if case .failure(let error) = self { return error.code }
        return nil
    }
}
