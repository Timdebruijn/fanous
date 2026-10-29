// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Synchronization
import Testing

@testable import FanousEngine

/// B23: project versions in `versions/` and the commands that make, list, restore and delete them.
struct ProjectVersionsTests {
    final class ShowModeFlag: Sendable {
        let on = Atomic<Bool>(false)
    }

    struct Fixture {
        var store: StateStore
        var versions: ProjectVersions
        var flag: ShowModeFlag
        /// The temporary folder holding `versions/` (and, for the traversal test, a `project.json` beside it).
        var base: URL
        var directory: URL { versions.directory }
    }

    static func make() -> Fixture {
        let base = FileManager.default.temporaryDirectory.appending(path: "fanous-versions-\(UUID().uuidString)")
        let (store, _) = StateStoreTests.makeStore()
        let versions = ProjectVersions(directory: base.appending(path: "versions"), logger: StateStoreTests.logger)
        let flag = ShowModeFlag()
        versions.registerCommands(on: store, showModeOn: { flag.on.load(ordering: .relaxed) })
        return Fixture(store: store, versions: versions, flag: flag, base: base)
    }

    static func failure(_ result: Result<CommandResult, CommandError>) -> CommandError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    @Test func snapshotListRevertAndUndo() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let store = f.store
        _ = try store.execute("project.set", args: ["path": "/name", "value": "Doors"], role: .programmer).get()
        let saved = try #require(try store.execute("project.snapshot", args: ["name": "Before doors"], role: .programmer).get().value)
        let id = try #require(saved["id"]?.string)
        #expect(id.hasSuffix("-before-doors"))
        #expect(saved["automatic"]?.bool == false)
        #expect(store.historyDepth.undo == 1)  // a snapshot is not a change of the project

        _ = try store.execute("project.set", args: ["path": "/name", "value": "Foolish"], role: .programmer).get()
        _ = try store.execute("project.revert", args: ["id": .string(id)], role: .programmer).get()
        #expect(store.project["name"]?.string == "Doors")
        #expect(store.project["snapshot"] == nil)

        let list = try #require(try store.execute("project.versions", role: .monitor).get().value?.array)
        #expect(list.count == 2)
        #expect(list[0]["automatic"]?.bool == true)
        #expect(list[0]["name"]?.string == "Before revert to Before doors")
        #expect(list[0]["layers"]?.int == 2)
        #expect(list[0]["outputs"]?.int == 0)
        #expect(list[1]["id"]?.string == id)

        // the revert is reversible twice over: undo, and the version of the state it left
        _ = try store.execute("undo", role: .programmer).get()
        #expect(store.project["name"]?.string == "Foolish")
        _ = try store.execute("project.revert", args: ["id": list[0]["id"]!], role: .programmer).get()
        #expect(store.project["name"]?.string == "Foolish")
    }

    @Test func revertingToTheCurrentProjectChangesAndSavesNothing() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let id = try #require(try f.store.execute("project.snapshot", args: ["name": "Doors"], role: .programmer).get().value?["id"]?.string)
        // an OSC console repeating /fanous/project/load: every repeat is a no-op, no version piles up
        for _ in 0..<5 {
            let result = try f.store.execute("project.revert", args: ["id": .string(id)], role: .programmer).get()
            #expect(result.value?["unchanged"]?.bool == true)
        }
        _ = try f.store.execute("project.set", args: ["path": "/name", "value": "Changed"], role: .programmer).get()
        for _ in 0..<5 { _ = try f.store.execute("project.revert", args: ["id": .string(id)], role: .programmer).get() }
        #expect(f.versions.list().count == 2)  // the named one and one "Before revert"
        #expect(f.store.historyDepth.undo == 2)  // project.set and one revert
        // the state being left equals the newest version: no second "Before revert"
        _ = try f.store.execute("undo", role: .programmer).get()
        _ = try f.store.execute("project.revert", args: ["id": .string(id)], role: .programmer).get()
        #expect(f.versions.list().count == 2)
    }

    @Test func revertRefusedUnderShowLockAndInShowMode() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let store = f.store
        _ = try store.execute("show.lock", role: .programmer).get()
        // saving a version is allowed under the lock (before doors); it records the lock but a revert never changes it
        let id = try #require(try store.execute("project.snapshot", args: ["name": "Locked"], role: .programmer).get().value?["id"]?.string)
        #expect(store.execute("project.revert", args: ["id": .string(id)], role: .programmer) == .failure(.showLocked))
        #expect(store.execute("project.deleteVersion", args: ["id": .string(id)], role: .programmer) == .failure(.showLocked))
        #expect(store.execute("project.revert", args: ["id": .string(id)], role: .operator) == .failure(.forbidden))
        _ = try store.execute("show.unlock", role: .programmer).get()
        _ = try store.execute("project.set", args: ["path": "/name", "value": "Changed"], role: .programmer).get()

        f.flag.on.store(true, ordering: .relaxed)
        #expect(Self.failure(store.execute("project.revert", args: ["id": .string(id)], role: .programmer))?.code == "showMode")
        #expect(f.versions.list().count == 1)  // a refused revert saves nothing

        f.flag.on.store(false, ordering: .relaxed)
        _ = try store.execute("project.revert", args: ["id": .string(id)], role: .programmer).get()
        #expect(store.project["showLock"]?.bool == false)
        #expect(store.project["name"]?.string == "Untitled")
    }

    @Test func undoAndRedoOfARevertAreRefusedInShowMode() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let store = f.store
        let id = try #require(try store.execute("project.snapshot", args: ["name": "Doors"], role: .programmer).get().value?["id"]?.string)
        _ = try store.execute("project.set", args: ["path": "/name", "value": "Changed"], role: .programmer).get()
        _ = try store.execute("project.revert", args: ["id": .string(id)], role: .programmer).get()

        f.flag.on.store(true, ordering: .relaxed)
        #expect(Self.failure(store.execute("undo", role: .programmer))?.code == "showMode")
        #expect(store.project["name"]?.string == "Untitled")
        #expect(store.historyDepth == (2, 0))  // the refused entry stays

        f.flag.on.store(false, ordering: .relaxed)
        _ = try store.execute("undo", role: .programmer).get()
        #expect(store.project["name"]?.string == "Changed")

        f.flag.on.store(true, ordering: .relaxed)
        #expect(Self.failure(store.execute("redo", role: .programmer))?.code == "showMode")
        #expect(store.historyDepth == (1, 1))
        // other history entries still step in show mode
        _ = try store.execute("undo", role: .programmer).get()
        #expect(store.project["name"]?.string == "Untitled")

        f.flag.on.store(false, ordering: .relaxed)
        _ = try store.execute("redo", role: .programmer).get()
        _ = try store.execute("redo", role: .programmer).get()
        #expect(store.project["name"]?.string == "Untitled")
        #expect(store.historyDepth == (2, 0))
    }

    /// The undo of a revert that dropped 151 would re-add the old entry over a server that took 151 meanwhile (B91). The
    /// refusal drops the history below the revert too: it was recorded against the project the revert replaced.
    @Test func revertUndoRefusedWhenAnotherServerTookADroppedNumber() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let store = f.store
        func server(_ file: Int, _ app: String) -> SyphonCatalog.Server { SyphonCatalog.Server(file: file, app: app, server: "Server") }
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([server(150, "A")]) }
        let id = try #require(try store.execute("project.snapshot", args: ["name": "Doors"], role: .programmer).get().value?["id"]?.string)
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([server(150, "A"), server(151, "X")]) }
        _ = try store.execute("project.set", args: ["path": "/name", "value": "Tour"], role: .programmer).get()
        _ = try store.execute("project.revert", args: ["id": .string(id)], role: .programmer).get()
        #expect(store.project["syphon"]?["151"] == nil)
        // Y takes 151 as the lowest free number, then stops: the engine leaves its entry
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([server(150, "A"), server(151, "Y")]) }
        #expect(store.historyDepth.undo == 2)
        #expect(store.execute("undo", role: .programmer) == .failure(CommandError("historyConflict", "Syphon number 151 is now held by Y/Server; undo/redo refused")))
        #expect(store.project["syphon"]?["151"]?["app"]?.string == "Y")
        #expect(store.historyDepth.undo == 0)
        #expect(Self.failure(store.execute("undo", role: .programmer))?.code == "nothingToUndo")
        #expect(store.project["name"]?.string == "Untitled")
    }

    /// The undo of a revert that added 151 is a `remove /syphon/151`, which would free the number of a server that took
    /// 151 meanwhile (B91).
    @Test func revertUndoRefusedWhenItWouldFreeAnotherServersNumber() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let store = f.store
        func server(_ file: Int, _ app: String) -> SyphonCatalog.Server { SyphonCatalog.Server(file: file, app: app, server: "Server") }
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([server(151, "X")]) }
        let id = try #require(try store.execute("project.snapshot", args: ["name": "Doors"], role: .programmer).get().value?["id"]?.string)
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([]) }
        _ = try store.execute("project.revert", args: ["id": .string(id)], role: .programmer).get()
        // X runs elsewhere: the catalog drops its twin on 151; Y takes 151, then stops
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([server(151, "Y")]) }
        #expect(store.execute("undo", role: .programmer) == .failure(CommandError("historyConflict", "Syphon number 151 is now held by Y/Server; undo/redo refused")))
        #expect(store.project["syphon"]?["151"]?["app"]?.string == "Y")
    }

    /// The undo of a revert that added 151 after the engine dropped the entry (a running server's twin) skips the remove
    /// of the missing key instead of failing and dropping the history; its redo is still checked (B91).
    @Test func revertUndoSkipsANumberTheEngineAlreadyDropped() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let store = f.store
        func server(_ file: Int, _ app: String) -> SyphonCatalog.Server { SyphonCatalog.Server(file: file, app: app, server: "Server") }
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([server(151, "X")]) }
        let id = try #require(try store.execute("project.snapshot", args: ["name": "Doors"], role: .programmer).get().value?["id"]?.string)
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([]) }
        _ = try store.execute("project.set", args: ["path": "/name", "value": "Tour"], role: .programmer).get()
        _ = try store.execute("project.revert", args: ["id": .string(id)], role: .programmer).get()
        // X runs elsewhere: the catalog drops its twin on 151 and writes /syphon back without it; nobody takes 151
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([]) }
        let depth = store.historyDepth.undo
        _ = try store.execute("undo", role: .programmer).get()
        #expect(store.project["name"]?.string == "Tour")
        #expect(store.project["syphon"] == [:])
        #expect(store.historyDepth.undo == depth - 1)
        // Y takes 151, then stops: the redo would put X back over it
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([server(151, "Y")]) }
        #expect(store.execute("redo", role: .programmer) == .failure(CommandError("historyConflict", "Syphon number 151 is now held by Y/Server; undo/redo refused")))
        #expect(store.project["syphon"]?["151"]?["app"]?.string == "Y")
    }

    /// The undo of a revert that renamed 151, with nothing changed since, puts the old name back (B91).
    @Test func revertUndoRestoresARenamedNumber() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let store = f.store
        func server(_ file: Int, _ app: String) -> SyphonCatalog.Server { SyphonCatalog.Server(file: file, app: app, server: "Server") }
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([server(151, "Z")]) }
        let id = try #require(try store.execute("project.snapshot", args: ["name": "Doors"], role: .programmer).get().value?["id"]?.string)
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([server(151, "X")]) }
        _ = try store.execute("project.revert", args: ["id": .string(id)], role: .programmer).get()
        #expect(store.project["syphon"]?["151"]?["app"]?.string == "Z")
        let depth = store.historyDepth.undo
        _ = try store.execute("undo", role: .programmer).get()
        #expect(store.project["syphon"]?["151"]?["app"]?.string == "X")
        #expect(store.historyDepth.undo == depth - 1)
    }

    /// The undo of a revert that renamed 151 is a `replace /syphon/151/app`, which would rename a server that took 151
    /// meanwhile (B91).
    @Test func revertUndoRefusedWhenItWouldRenameAnotherServersNumber() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let store = f.store
        func server(_ file: Int, _ app: String) -> SyphonCatalog.Server { SyphonCatalog.Server(file: file, app: app, server: "Server") }
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([server(151, "Z")]) }
        let id = try #require(try store.execute("project.snapshot", args: ["name": "Doors"], role: .programmer).get().value?["id"]?.string)
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([server(151, "X")]) }
        _ = try store.execute("project.revert", args: ["id": .string(id)], role: .programmer).get()
        #expect(store.project["syphon"]?["151"]?["app"]?.string == "Z")
        store.correct(at: "/syphon") { ProjectDocument.syphonValue([server(151, "Y")]) }
        #expect(store.execute("undo", role: .programmer) == .failure(CommandError("historyConflict", "Syphon number 151 is now held by Y/Server; undo/redo refused")))
        #expect(store.project["syphon"]?["151"]?["app"]?.string == "Y")
    }

    @Test func invalidVersionsAreNotRestored() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        var project = f.store.project
        try project.set(.number(0), at: "/layerCount")
        let noLayers = try f.versions.save(project, name: "No layers", automatic: false)
        project = f.store.project
        try project.set([["fixture": "Spotlight 1", "universe": "artnet:0.0.1", "address": 1]], at: "/patch")
        let badPatch = try f.versions.save(project, name: "Bad patch", automatic: false)
        project = f.store.project
        var canvas = try #require(project["canvases"]?[0])
        try canvas.set(7680, at: "/width")
        try canvas.set(4320, at: "/height")
        try project.set([canvas, canvas, canvas], at: "/canvases")
        let tooBig = try f.versions.save(project, name: "Too big", automatic: false)
        try project.set([canvas, canvas, canvas, canvas, canvas], at: "/canvases")
        let tooMany = try f.versions.save(project, name: "Too many", automatic: false)
        for (version, word) in [(noLayers, "layer count"), (badPatch, "patch"), (tooBig, "pixels"), (tooMany, "canvases")] {
            let error = Self.failure(f.store.execute("project.revert", args: ["id": .string(version.id)], role: .programmer))
            #expect(error?.code == "invalidArgs")
            #expect(error?.message.contains(word) == true, "\(version.name): \(error?.message ?? "accepted")")
        }
        #expect(f.store.project == StateStoreTests.makeStore().0.project)
    }

    @Test func deleteNamedOnly() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let store = f.store
        let named = try #require(try store.execute("project.snapshot", args: ["name": "Keep"], role: .programmer).get().value?["id"]?.string)
        let automatic = try #require(try store.execute("project.snapshot", role: .programmer).get().value)
        #expect(automatic["automatic"]?.bool == true)
        #expect(automatic["name"]?.string == "Manual")
        #expect(Self.failure(store.execute("project.deleteVersion", args: ["id": automatic["id"]!], role: .programmer))?.code == "invalidArgs")
        _ = try store.execute("project.deleteVersion", args: ["id": .string(named)], role: .programmer).get()
        #expect(f.versions.list().map(\.id) == [automatic["id"]?.string])
        #expect(Self.failure(store.execute("project.deleteVersion", args: ["id": .string(named)], role: .programmer))?.code == "notFound")
    }

    @Test func retentionKeepsNamedVersions() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        var project = f.store.project
        try f.versions.save(project, name: "Premiere", automatic: false)
        for i in 0..<(ProjectVersions.keepAutomatic + 5) {
            try project.set(.string("v\(i)"), at: "/name")
            #expect(f.versions.saveAutomatic(project, reason: .periodic) != nil)
        }
        let list = f.versions.list()
        #expect(list.filter(\.automatic).count == ProjectVersions.keepAutomatic)
        #expect(list.filter { !$0.automatic }.map(\.name) == ["Premiere"])
        let newest = try f.versions.document(id: list[0].id)
        #expect(newest["name"]?.string == "v\(ProjectVersions.keepAutomatic + 4)")
        #expect(f.versions.live["lastAutomatic"]?.double == list[0].at)
    }

    @Test func aClockSetBackNeitherReordersNorPrunesTheNewVersion() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        var project = f.store.project
        let future = Date(timeIntervalSince1970: 2_000_000_000)
        for i in 0..<ProjectVersions.keepAutomatic {
            try project.set(.string("future \(i)"), at: "/name")
            try f.versions.save(project, name: "Periodic", automatic: true, now: future)
        }
        // the engine restarts with the clock years behind the newest version
        let restarted = ProjectVersions(directory: f.directory, logger: StateStoreTests.logger)
        try project.set("after the restart", at: "/name")
        let saved = try #require(restarted.saveAutomatic(project, reason: .start, now: Date(timeIntervalSince1970: 1_000_000_000)))
        let list = restarted.list()
        #expect(list.count == ProjectVersions.keepAutomatic)
        #expect(list.first?.id == saved.id)
        #expect(saved.at > future.timeIntervalSince1970)
    }

    @Test func savesInOneMillisecondGetDistinctIDs() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let now = Date(timeIntervalSince1970: 1_792_938_612.345)
        let ids = try (0..<3).map { _ in try f.versions.save(f.store.project, name: "Same", automatic: false, now: now).id }
        #expect(Set(ids).count == 3)
        #expect(f.versions.list().count == 3)
    }

    @Test func automaticSnapshotSkipsAnUnchangedProject() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        var project = f.store.project
        #expect(f.versions.saveAutomatic(project, reason: .start) != nil)
        #expect(f.versions.saveAutomatic(project, reason: .periodic) == nil)
        try project.set(true, at: "/showLock")
        #expect(f.versions.saveAutomatic(project, reason: .showMode) == nil)  // the lock alone is no change
        try project.set("Changed", at: "/name")
        #expect(f.versions.saveAutomatic(project, reason: .periodic)?.name == "Periodic")
        #expect(f.versions.list().count == 2)
        // after a restart the newest version is read once and compared the same way
        let restarted = ProjectVersions(directory: f.directory, logger: StateStoreTests.logger)
        #expect(restarted.saveAutomatic(project, reason: .start) == nil)
    }

    @Test func filesAddedOrRemovedByHandAreSeen() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let a = try f.versions.save(f.store.project, name: "A", automatic: false)
        let b = try f.versions.save(f.store.project, name: "B", automatic: false)
        #expect(f.versions.list().count == 2)
        try FileManager.default.removeItem(at: f.directory.appending(path: a.id + ".json"))
        try FileManager.default.copyItem(at: f.directory.appending(path: b.id + ".json"), to: f.directory.appending(path: "copied-by-hand.json"))
        #expect(Set(f.versions.list().map(\.id)) == [b.id, "copied-by-hand"])
    }

    @Test func corruptAndForeignFilesAreSkipped() throws {
        let f = Self.make()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let good = try f.versions.save(f.store.project, name: "Good", automatic: false)
        let project = try JSONEncoder().encode(f.store.project)
        try Data("{ not json".utf8).write(to: f.directory.appending(path: "20260101T000000.000Z-broken.json"))
        // a valid project without snapshot info is not a version: listed nowhere, never restored
        try project.write(to: f.directory.appending(path: "no-snapshot-info.json"))
        try Data("x".utf8).write(to: f.directory.appending(path: "notes.txt"))
        #expect(f.versions.list().map(\.id) == [good.id])
        #expect(throws: CommandError.self) { try f.versions.document(id: "20260101T000000.000Z-broken") }
        #expect(throws: CommandError.self) { try f.versions.document(id: "no-snapshot-info") }
        // a readable version one level up must not be reachable through the id
        try FileManager.default.copyItem(at: f.directory.appending(path: good.id + ".json"), to: f.base.appending(path: "project.json"))
        #expect(ProjectDocument.load(from: f.directory.appending(path: "../project.json")) != nil)
        #expect(throws: CommandError.self) { try f.versions.document(id: "../project") }
        #expect(throws: CommandError.self) { try f.versions.document(id: "") }
        #expect(f.versions.resolve("good") == good.id)
        #expect(f.versions.resolve(good.id) == good.id)
        #expect(f.versions.resolve("missing") == nil)
    }

    @Test func fileNames() {
        #expect(ProjectVersions.slug("Before doors / Act 2!") == "before-doors-act-2")
        #expect(ProjectVersions.slug("///") == "version")
        #expect(ProjectVersions.stamp(1_792_938_612.345) == "20261025T143012.345Z")
        #expect(ProjectVersions.stamp(1) < ProjectVersions.stamp(2))
    }
}
