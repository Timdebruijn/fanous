// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import QuartzCore
import Synchronization
import Testing

@testable import FanousEngine

/// B286: a cue GO from OSC or MIDI does not wait behind work on the control queue that grows with the project.
struct ControlQueueTests {
    /// A client that takes everything and decodes nothing.
    final class SinkClient: StateClient, Sendable {
        let role: Role = .programmer
        let sent = Atomic<Int>(0)
        func send(text: String, droppable: Bool) -> Bool {
            sent.add(1, ordering: .relaxed)
            return true
        }
        func disconnect(reason: String) {}
    }

    /// A large show: 32 layers and 8 outputs patched, 500 cues of 50 values, and a live document whose DMX part is the
    /// engine's at the limits (every fixture of 32 layers and 8 outputs).
    static func bigStore(go: @escaping @Sendable () -> Void = {}) throws -> StateStore {
        var project = testProject(layers: 32, outputs: 8)
        let cues: [JSONValue] = (1...500).map { n in
            [
                "id": .string(UUID().uuidString), "number": .number(Double(n)), "name": .string("Cue \(n)"), "fade": 2,
                "values": .array((0..<50).map { v in ["fixture": .string("Layer \(v % 32 + 1)"), "parameter": "intensity", "raw": .number(Double(v))] }),
            ]
        }
        try project.set(.array(cues), at: "/cues")
        let (store, _) = testStore(project: project) { store, auth in
            ProjectDocument.registerCommands(on: store, auth: auth)
            ShowCommands.register(
                on: store, hooks: ShowCommands.Hooks(go: go, back: {}, goto: { _ in }, showMode: { _ in nil }, acknowledge: { _, _ in }, runReadiness: {}))
        }
        let dmx = DMXStore(
            patch: .standard(layers: 32, outputs: 8), fixtures: ProjectDocument.fixtures(layerCount: 32, outputs: Array(1...8)), logger: testLogger)
        store.updateLive(["dmx": try JSONValue(encoding: dmx.snapshot())])
        _ = store.live  // the update has landed
        return store
    }

    static func time(_ body: () -> Void) -> Double {
        let started = CACurrentMediaTime()
        body()
        return CACurrentMediaTime() - started
    }

    /// The GO latency while 20 clients join at once; `unqueued`: the OSC/MIDI path.
    static func goBehindWelcomes(_ store: StateStore, unqueued: Bool) -> Double {
        let joined = DispatchGroup()
        let started = DispatchSemaphore(value: 0)
        for i in 0..<20 {
            DispatchQueue.global(qos: .userInitiated).async(group: joined) {
                if i == 0 { started.signal() }
                store.admit(SinkClient(), role: .programmer, caps: [:]) {}
            }
        }
        started.wait()
        usleep(1000)  // the joins are under way
        let latency = time { _ = unqueued ? store.executeUnqueued("cue.go", role: .operator) : store.execute("cue.go", role: .operator) }
        joined.wait()
        return latency
    }

    /// Prints the costs the PR body quotes (numbers from an optimised build).
    @Test(.offPool) func printControlQueueCosts() throws {
        let store = try Self.bigStore()
        let bytes = store.welcome(role: .programmer, caps: [:]).utf8.count
        let welcome = Self.time { _ = store.welcome(role: .programmer, caps: [:]) }
        let commit = Self.time { _ = store.execute("project.set", args: ["path": "/name", "value": "Tour"], role: .programmer) }
        let queued = Self.goBehindWelcomes(store, unqueued: false)
        let unqueued = Self.goBehindWelcomes(store, unqueued: true)
        print(
            String(
                format: "Control queue costs, a %.1f MB welcome: welcome %.1f ms, commit %.1f ms; GO behind 20 joins: %.2f ms queued, %.3f ms unqueued",
                Double(bytes) / 1e6, welcome * 1e3, commit * 1e3, queued * 1e3, unqueued * 1e3))
    }

    /// A GO sent while 20 clients join takes less than one welcome: on main it waited for the welcomes built on the control
    /// queue ahead of it (1.4 s for 20 welcomes of 68 ms, measured). Both paths: OSC and MIDI's (unqueued) and a
    /// WebSocket's (queued, behind the welcomes' copies only).
    @Test(.offPool) func aGoDoesNotWaitForWelcomes() throws {
        let fired = Atomic<Int>(0)
        let store = try Self.bigStore { fired.add(1, ordering: .relaxed) }
        let welcome = Self.time { _ = store.welcome(role: .programmer, caps: [:]) }
        let unqueued = Self.goBehindWelcomes(store, unqueued: true)
        let queued = Self.goBehindWelcomes(store, unqueued: false)
        #expect(unqueued < welcome, "OSC/MIDI GO took \(unqueued * 1e3) ms, a welcome \(welcome * 1e3) ms")
        #expect(queued < welcome, "WebSocket GO took \(queued * 1e3) ms, a welcome \(welcome * 1e3) ms")
        #expect(fired.load(ordering: .relaxed) == 2)
    }

    /// A client that joins while a change commits gets the welcome first and the change's patch after it, with the next
    /// revision: the patch is held while the welcome is built off the queue.
    @Test func aPatchDuringAWelcomeFollowsIt() throws {
        let (store, _) = testStore()
        let client = RecordingClient(role: .programmer)
        store.whileWelcoming = { _ = store.execute("project.set", args: ["path": "/name", "value": "Tour"], role: .programmer) }
        store.admit(client, role: client.role, caps: [:]) {}
        let messages = client.messages.withLock { $0 }
        #expect(messages.map { $0["t"]?.string } == ["welcome", "patch"])
        #expect(messages.first?["project"]?["name"]?.string != "Tour", "the welcome is the document from before the change")
        #expect(messages.last?["rev"]?.int == (messages.first?["rev"]?.int).map { $0 + 1 })
        store.whileWelcoming = nil
        _ = try store.execute("project.set", args: ["path": "/name", "value": "Next"], role: .programmer).get()
        #expect(client.patches.count == 2, "patches after the welcome go out at once")
    }

    /// Records the type and revision of every message.
    final class RevisionClient: StateClient, Sendable {
        let role: Role = .programmer
        let seen = Mutex<[(type: String, rev: Int)]>([])
        func send(text: String, droppable: Bool) -> Bool {
            let message = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            seen.withLock { $0.append((message?["t"]?.string ?? "", message?["rev"]?.int ?? -1)) }
            return true
        }
        func disconnect(reason: String) {}
    }

    /// A member's `snapshot` request while live patches flow (a console running): no patch with a later revision goes out
    /// before the snapshot, and the first patch after it has the next revision. Otherwise the web client, which ignores
    /// patches until the snapshot, sees a gap and asks again, for good. On the previous head (copy, then encode while still
    /// a member) 5 of 5 snapshots were overtaken.
    @Test(.offPool) func aSnapshotIsNotOvertakenByPatches() throws {
        let store = try Self.bigStore()
        let client = RevisionClient()
        store.admit(client, role: .programmer, caps: [:]) {}
        let stop = Atomic<Bool>(false), stopped = DispatchSemaphore(value: 0)
        Thread {
            var n = 0.0
            while !stop.load(ordering: .relaxed) {
                store.setLive(.number(n), at: "/tick")
                n += 1
                usleep(5000)
            }
            stopped.signal()
        }.start()
        for _ in 0..<5 { store.resnapshot(client, role: .programmer) }
        stop.store(true, ordering: .relaxed)
        stopped.wait()
        let seen = client.seen.withLock { $0 }
        let snapshots = seen.indices.filter { seen[$0].type == "snapshot" }
        #expect(snapshots.count == 5)
        for i in snapshots {
            let rev = seen[i].rev
            #expect(seen[..<i].allSatisfy { $0.rev <= rev }, "a later revision went out before the snapshot at \(rev)")
            if i + 1 < seen.count, seen[i + 1].type == "patch" { #expect(seen[i + 1].rev == rev + 1) }
        }
    }

    /// A second `admit` of a member (a second hello) keeps one membership and sends a second welcome; later patches go
    /// out once.
    @Test func aSecondAdmitKeepsOneMembership() throws {
        let (store, _) = testStore()
        let client = RecordingClient(role: .programmer)
        store.admit(client, role: client.role, caps: [:]) {}
        store.admit(client, role: client.role, caps: [:]) {}
        #expect(store.clientCount == 1)
        _ = try store.execute("project.set", args: ["path": "/name", "value": "Tour"], role: .programmer).get()
        #expect(client.messages.withLock { $0 }.map { $0["t"]?.string } == ["welcome", "welcome", "patch"])
    }

    /// A client that leaves between the copy and the welcome's send is not made a member again, and hears nothing more.
    @Test func aClientThatLeavesDuringItsWelcomeStaysGone() throws {
        let (store, _) = testStore()
        let client = RecordingClient(role: .programmer)
        store.whileWelcoming = { store.detach(client) }
        store.admit(client, role: client.role, caps: [:]) {}
        store.whileWelcoming = nil
        #expect(store.clientCount == 0)
        _ = try store.execute("project.set", args: ["path": "/name", "value": "Tour"], role: .programmer).get()
        #expect(client.patches.isEmpty)
    }

    /// Only commands marked `unqueued` skip the queue; any other goes through `execute`, with its checks.
    @Test func onlyUnqueuedCommandsSkipTheQueue() throws {
        let store = try Self.bigStore()
        #expect(try store.executeUnqueued("project.set", args: ["path": "/name", "value": "X"], role: .programmer).get().rev == 1)
        #expect(throws: CommandError.forbidden) { try store.executeUnqueued("cue.go", role: .monitor).get() }
        #expect(throws: CommandError.unknownCommand) { try store.executeUnqueued("cue.nope", role: .operator).get() }
    }
}
