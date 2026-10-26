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

    static func make() -> (StateStore, ProjectVersions, ShowModeFlag, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "fanous-versions-\(UUID().uuidString)")
        let (store, _) = StateStoreTests.makeStore()
        let versions = ProjectVersions(directory: directory, logger: StateStoreTests.logger)
        let flag = ShowModeFlag()
        versions.registerCommands(on: store, showModeOn: { flag.on.load(ordering: .relaxed) })
        return (store, versions, flag, directory)
    }

    @Test func snapshotListRevertAndUndo() throws {
        let (store, _, _, directory) = Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
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

    @Test func revertRefusedUnderShowLockAndInShowMode() throws {
        let (store, versions, flag, directory) = Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try store.execute("show.lock", role: .programmer).get()
        // saving a version is allowed under the lock (before doors); it records the lock but a revert never changes it
        let id = try #require(try store.execute("project.snapshot", args: ["name": "Locked"], role: .programmer).get().value?["id"]?.string)
        #expect(store.execute("project.revert", args: ["id": .string(id)], role: .programmer) == .failure(.showLocked))
        #expect(store.execute("project.deleteVersion", args: ["id": .string(id)], role: .programmer) == .failure(.showLocked))
        #expect(store.execute("project.revert", args: ["id": .string(id)], role: .operator) == .failure(.forbidden))
        _ = try store.execute("show.unlock", role: .programmer).get()

        flag.on.store(true, ordering: .relaxed)
        guard case .failure(let error) = store.execute("project.revert", args: ["id": .string(id)], role: .programmer) else {
            Issue.record("revert in show mode must be refused")
            return
        }
        #expect(error.code == "showMode")
        #expect(versions.list().count == 1)  // a refused revert saves nothing

        flag.on.store(false, ordering: .relaxed)
        _ = try store.execute("project.revert", args: ["id": .string(id)], role: .programmer).get()
        #expect(store.project["showLock"]?.bool == false)
    }

    @Test func deleteNamedOnly() throws {
        let (store, versions, _, directory) = Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let named = try #require(try store.execute("project.snapshot", args: ["name": "Keep"], role: .programmer).get().value?["id"]?.string)
        let automatic = try #require(try store.execute("project.snapshot", role: .programmer).get().value)
        #expect(automatic["automatic"]?.bool == true)
        #expect(automatic["name"]?.string == "Manual")
        guard case .failure(let refused) = store.execute("project.deleteVersion", args: ["id": automatic["id"]!], role: .programmer) else {
            Issue.record("automatic versions are not deleted by hand")
            return
        }
        #expect(refused.code == "invalidArgs")
        _ = try store.execute("project.deleteVersion", args: ["id": .string(named)], role: .programmer).get()
        #expect(versions.list().map(\.id) == [automatic["id"]?.string])
        guard case .failure(let missing) = store.execute("project.deleteVersion", args: ["id": .string(named)], role: .programmer) else {
            Issue.record("deleting twice must fail")
            return
        }
        #expect(missing.code == "notFound")
    }

    @Test func retentionKeepsNamedVersions() throws {
        let (store, versions, _, directory) = Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = store.project
        try versions.save(project, name: "Premiere", automatic: false)
        for i in 0..<(ProjectVersions.keepAutomatic + 5) {
            try project.set(.string("v\(i)"), at: "/name")
            #expect(versions.saveAutomatic(project, reason: .periodic) != nil)
        }
        let list = versions.list()
        #expect(list.filter(\.automatic).count == ProjectVersions.keepAutomatic)
        #expect(list.filter { !$0.automatic }.map(\.name) == ["Premiere"])
        let newest = try versions.document(id: list[0].id)
        #expect(newest["name"]?.string == "v\(ProjectVersions.keepAutomatic + 4)")
        #expect(versions.live["lastAutomatic"]?.double == list[0].at)
    }

    @Test func automaticSnapshotSkipsAnUnchangedProject() throws {
        let (store, versions, _, directory) = Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = store.project
        #expect(versions.saveAutomatic(project, reason: .start) != nil)
        #expect(versions.saveAutomatic(project, reason: .periodic) == nil)
        try project.set(true, at: "/showLock")
        #expect(versions.saveAutomatic(project, reason: .showMode) == nil)  // the lock alone is no change
        try project.set("Changed", at: "/name")
        #expect(versions.saveAutomatic(project, reason: .periodic)?.name == "Periodic")
        #expect(versions.list().count == 2)
    }

    @Test func corruptAndForeignFilesAreSkipped() throws {
        let (store, versions, _, directory) = Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = try versions.save(store.project, name: "Good", automatic: false)
        try Data("{ not json".utf8).write(to: directory.appending(path: "20260101T000000.000-broken.json"))
        try Data("{\"schema\":1,\"patch\":[]}".utf8).write(to: directory.appending(path: "no-snapshot-info.json"))
        try Data("x".utf8).write(to: directory.appending(path: "notes.txt"))
        #expect(versions.list().map(\.id) == [good.id])
        #expect(throws: CommandError.self) { try versions.document(id: "20260101T000000.000-broken") }
        #expect((try? versions.document(id: "../project")) == nil)
        #expect((try? versions.document(id: "")) == nil)
        #expect(versions.resolve("good") == good.id)
        #expect(versions.resolve(good.id) == good.id)
        #expect(versions.resolve("missing") == nil)
    }

    @Test func fileNames() {
        #expect(ProjectVersions.slug("Before doors / Act 2!") == "before-doors-act-2")
        #expect(ProjectVersions.slug("///") == "version")
        let stamp = ProjectVersions.stamp(1_792_938_612.345)
        #expect(stamp == "20261025T143012.345Z")
        #expect(ProjectVersions.stamp(1) < ProjectVersions.stamp(2))
    }
}
