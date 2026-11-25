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

    /// A GO from OSC or MIDI after a `cue.add` was acknowledged sees the cue: the add hands the new list to the cue runner's
    /// queue while it commits (Engine.projectChanged → CueRunner.replace), before the ack; the unqueued GO goes onto the same
    /// queue after it. Modelled here with one serial queue for the runner.
    @Test func aGoAfterACueAddSeesTheCue() throws {
        let runner = DispatchQueue(label: "test.cues")
        let order = Mutex<[String]>([])
        let store = try Self.bigStore { runner.async { order.withLock { $0.append("go") } } }
        store.onProjectChanged = { document in
            let count = document["cues"]?.array?.count ?? 0
            runner.async { order.withLock { $0.append("list \(count)") } }
        }
        _ = try store.execute("cue.add", args: ["number": 501, "name": "Last"], role: .programmer).get()
        _ = try store.executeUnqueued("cue.go", role: .operator).get()
        runner.sync {}
        #expect(order.withLock { $0 } == ["list 501", "go"])
    }

    /// Only commands marked `unqueued` skip the queue; any other goes through `execute`, with its checks.
    @Test func onlyUnqueuedCommandsSkipTheQueue() throws {
        let store = try Self.bigStore()
        #expect(try store.executeUnqueued("project.set", args: ["path": "/name", "value": "X"], role: .programmer).get().rev == 1)
        #expect(throws: CommandError.forbidden) { try store.executeUnqueued("cue.go", role: .monitor).get() }
        #expect(throws: CommandError.unknownCommand) { try store.executeUnqueued("cue.nope", role: .operator).get() }
    }
}
