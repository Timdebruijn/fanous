// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Synchronization
import Testing

@testable import FanousEngine

struct OSCReceiverTests {
    /// A console fires hundreds of datagrams back-to-back from one socket; none may be lost (B30).
    @Test func udpBurstFromOneSocketArrivesComplete() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        let seen = Mutex<Set<Double>>([])
        store.onCommand = { if case .cueGoto(let n) = $0 { seen.withLock { _ = $0.insert(n) } } }
        let receiver = OSCReceiver(store: store, logger: testLogger, port: 0)
        try receiver.start()
        defer { receiver.stop() }
        let port = try await listeningPort { receiver.boundUDPPort }
        // listening once a goto 0 (no cue of the burst) arrives; a fixed 300 ms was too short on a loaded Mac (B67)
        #expect(await waitUntil(every: .milliseconds(50)) {
            sendUDP(OSCMessage("/fanous/cue/goto", [.float32(0)]).encoded(), to: port)
            return seen.withLock { $0.contains(0) }
        })

        // the engine's DMX queue is busy for a moment (Art-Net frames, snapshot publishing) while the console fires
        store.queue.async { Thread.sleep(forTimeInterval: 0.2) }
        // fresh socket per burst: the first datagram of a flow is the one that creates the connection
        let count = 5 * 200 + 1  // and the probe's 0
        for burst in 0..<5 {
            let datagrams = (1...200).map { i in OSCMessage("/fanous/cue/goto", [.float32(Float(burst * 200 + i))]).encoded() }
            #expect(sendUDP(datagrams, to: port).sent == datagrams.map(\.count))
        }
        await waitUntil { seen.withLock { $0.count } >= count }
        #expect(seen.withLock { $0.count } == count)
    }

    /// The Phase 5 demo burst: 4 layers x (media, intensity, scale, position) back-to-back must all land in the resolvers.
    @Test func layerParameterBurstResolvesEveryLayer() async throws {
        let store = DMXStore(patch: .standard(layers: 4, outputs: 1), logger: testLogger)
        let listening = Mutex(false)
        store.onCommand = { _ in listening.withLock { $0 = true } }
        let receiver = OSCReceiver(store: store, logger: testLogger, port: 0)
        try receiver.start()
        defer { receiver.stop() }
        let port = try await listeningPort { receiver.boundUDPPort }
        // listening once a probe command arrives; a fixed 300 ms was too short on a loaded Mac (B67)
        #expect(await waitUntil(every: .milliseconds(50)) {
            sendUDP(OSCMessage("/fanous/cue/goto", [.float32(0)]).encoded(), to: port)
            return listening.withLock { $0 }
        })

        var messages: [OSCMessage] = []
        for n in 1...4 {
            let f = Float(n) / 8
            messages += [
                OSCMessage("/fanous/layer/\(n)/media", [.int32(Int32(n)), .int32(Int32(10 + n))]),
                OSCMessage("/fanous/layer/\(n)/intensity", [.float32(f)]),
                OSCMessage("/fanous/layer/\(n)/scaleX", [.float32(f)]),
                OSCMessage("/fanous/layer/\(n)/positionX", [.float32(f)]),
                OSCMessage("/fanous/layer/\(n)/positionY", [.float32(1 - f)]),
            ]
        }
        sendUDP(messages.map { $0.encoded() }, to: port)

        var expected: [String: UInt16] = [:]
        for n in 1...4 {
            let f = Double(Float(n) / 8)
            let raw = { (max: Double, v: Double) in UInt16((v * max).rounded()) }
            for (key, value) in [("folder", UInt16(n)), ("file", UInt16(10 + n)), ("intensity", raw(65535, f)), ("scaleX", raw(65535, f)), ("positionX", raw(65535, f)), ("positionY", raw(65535, 1 - f))] {
                expected["\(n)/\(key)"] = value
            }
        }
        var actual: [String: UInt16] = [:]
        for _ in 0..<50 {
            actual = [:]
            for (fixture, values) in store.snapshot().internalValues {
                for v in values { actual["\(fixture.filter(\.isNumber))/\(v.key)"] = v.raw }
            }
            if actual == expected { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(actual == expected)
    }

    /// B176: every message the address map takes lands in `live.osc.recent` as it was sent, a command also when the
    /// engine then refuses it; unknown and malformed ones, a missing layer and the feedback requests do not, and a fader
    /// sweep on one address holds one row with its last value.
    /// Probe and burst go out from one socket, as a console sends: the rows keep the order of one established flow. A
    /// probe from a throwaway socket of its own was a second new flow, set up while the burst's flow was; then
    /// Network.framework hands a few datagrams of the burst to the other flow's connection and they run ahead of the
    /// rest (B230, B252): the order across two new flows is not kept.
    @Test func recentListsReceivedMessagesInTheirOSCSpelling() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        store.onCommand = { _ in }
        let receiver = OSCReceiver(store: store, logger: testLogger, port: 0)
        try receiver.start()
        defer { receiver.stop() }
        let port = try await listeningPort { receiver.boundUDPPort }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        func send(_ messages: [OSCMessage]) {
            for bytes in messages.map({ $0.encoded() }) { _ = withSockaddr(port: port, host: "127.0.0.1") { sendto(fd, bytes, bytes.count, 0, $0, $1) } }
        }
        #expect(await waitUntil(every: .milliseconds(50)) {
            send([OSCMessage("/fanous/cue/go")])
            return !store.recentOSC().isEmpty
        })

        let sweep = (0..<500).map { OSCMessage("/fanous/layer/1/intensity", [.float32(Float($0) / 499)]) }
        let messages =
            [
                OSCMessage("/fanous/cue/goto", [.int32(3)]),
                OSCMessage("/fanous/cue/goto", [.int32(99)]),  // handed over; whether a cue 99 exists is the engine's call
                OSCMessage("/fanous/nothing", [.int32(1)]),  // not an address
                OSCMessage("/fanous/layer/9/intensity", [.float32(1)]),  // no layer 9
                OSCMessage("/fanous/layer/1/intensity", [.string("x")]),  // no value
                OSCMessage("/fanous/get"),  // answered (with a feedback server), never listed
            ] + sweep + [OSCMessage("/fanous/layer/1/media", [.int32(2), .int32(7)]), OSCMessage("/fanous/project/load", [.string("Show A")])]
        send(messages)
        await waitUntil { store.recentOSC().last?.text == "/fanous/project/load \"Show A\"" }
        // the probe's cue/go rows (one per probe sent) come first
        #expect(
            Array(store.recentOSC().map(\.text).drop { $0 == "/fanous/cue/go" }) == [
                "/fanous/cue/goto 3", "/fanous/cue/goto 99", "/fanous/layer/1/intensity 1.0", "/fanous/layer/1/media 2 7", "/fanous/project/load \"Show A\"",
            ])
    }

    /// B176: the log costs the receive path no allocation. The same bursts through `apply`, with and without the message
    /// to log, allocate the same on the calling thread: one address (the newest row is replaced) and two alternating
    /// addresses (the ring wraps ten times and drops old messages). Runs in scripts/check-mallocs.sh (name prefix).
    @Test(.mallocCounter)
    func mallocCounterOSCRecentLogAllocatesNothing() throws {
        try requireMallocCounter()
        let store = DMXStore(patch: .standard(layers: 2, outputs: 1), logger: testLogger)
        for (name, layers) in [("one address", 1), ("two addresses", 2)] {
            let messages = (0..<500).map { i in OSCMessage("/fanous/layer/\(i % layers + 1)/intensity", [.float32(Float(i) / 499)]) }
            let commands = try messages.map { try #require(OSCAddressMap.command(for: $0)) }
            func burst(logged: Bool) -> Int {
                store.queue.sync {
                    MallocCounter.count {
                        var i = 0
                        while i < messages.count {
                            store.apply(commands[i], from: logged ? messages[i] : nil)
                            i += 1
                        }
                    }
                }
            }
            _ = burst(logged: true)  // warm-up: the ring holds messages, the snapshot slots are touched
            let without = burst(logged: false)
            let with = burst(logged: true)
            print("OSC receive path, 500 parameter messages on \(name): \(without) allocations without the log, \(with) with it")
            #expect(with == without, "\(name): \(with) allocations with the log, \(without) without")
        }
    }

    /// B198: a command message costs the DMX queue the hand-over to the engine's command queue and nothing more; the
    /// command itself (here a refused one: the store has none registered) runs on the command queue, not counted.
    /// Measured on an M1 Pro: 3 per command in release (the synchronous `store.execute` before: 4), 4 in debug against
    /// 1 with a no-op `onCommand`; 5 in debug on the CI VM. The absolute count moves with machine and toolchain, so the
    /// printed numbers are the measurement (`scripts/check-mallocs.sh` shows them) and the assertions guard only what
    /// holds everywhere: the hand-over adds at most 8 per command over a no-op `onCommand` in the same run, and in
    /// release `apply` with a no-op `onCommand` allocates nothing.
    @Test(.mallocCounter)
    func mallocCounterOSCCommandHandOver() throws {
        try requireMallocCounter()
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        let state = StateStore(project: [:], logger: testLogger)
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        let message = OSCMessage("/fanous/cue/go", [])
        let command = try #require(OSCAddressMap.command(for: message))
        func burst() -> Int {
            store.queue.sync {
                MallocCounter.count {
                    var i = 0
                    while i < 100 {
                        store.apply(command, from: message)
                        i += 1
                    }
                }
            }
        }
        store.onCommand = { _ in }
        _ = burst()  // warm-up: the ring holds messages
        let baseline = burst()
        store.onCommand = { [weak engine] in engine?.handOver($0, to: state) }
        _ = burst()
        let allocations = burst()
        print("OSC receive path, 100 cue go messages: \(allocations) allocations on the DMX queue with the hand-over, \(baseline) without")
        if MaskTests.release { #expect(baseline == 0, "apply with a no-op onCommand: \(baseline) allocations") }
        #expect(allocations - baseline <= 800, "\(allocations - baseline) allocations for 100 hand-overs, more than 8 per command")
    }

    /// Feeds a message the way `OSCReceiver.dispatch` does, on the store's queue.
    private func feed(_ store: DMXStore, _ messages: [OSCMessage]) throws {
        for message in messages {
            let command = try #require(OSCAddressMap.command(for: message))
            store.queue.sync { store.apply(command, from: message) }
        }
    }

    /// B176: only a parameter on the address of the newest row replaces it (a fader sweep); interleaved faders, and every
    /// cue, show, media and retrigger message, keep a row each, so a double Go or lock-then-unlock stays visible.
    @Test func recentCollapsesOnlyAParameterSweep() throws {
        let store = DMXStore(patch: .standard(layers: 2, outputs: 1), logger: testLogger)
        store.onCommand = { _ in }
        let a = { (v: Float) in OSCMessage("/fanous/layer/1/intensity", [.float32(v)]) }
        let b = { (v: Float) in OSCMessage("/fanous/layer/2/intensity", [.float32(v)]) }
        try feed(store, [a(0.25), b(0.25), a(0.5), b(0.5), b(0.75), b(1)])
        try feed(store, [OSCMessage("/fanous/cue/go"), OSCMessage("/fanous/cue/go")])
        try feed(store, [OSCMessage("/fanous/show/lock", [.int32(1)]), OSCMessage("/fanous/show/lock", [.int32(0)])])
        try feed(store, [OSCMessage("/fanous/cue/goto", [.int32(3)]), OSCMessage("/fanous/cue/goto", [.int32(5)])])
        try feed(store, [OSCMessage("/fanous/layer/1/media", [.int32(1), .int32(2)]), OSCMessage("/fanous/layer/1/media", [.int32(1), .int32(3)])])
        try feed(store, [OSCMessage("/fanous/layer/1/retrigger"), OSCMessage("/fanous/layer/1/retrigger")])
        #expect(
            store.recentOSC().map(\.text) == [
                "/fanous/layer/1/intensity 0.25", "/fanous/layer/2/intensity 0.25", "/fanous/layer/1/intensity 0.5", "/fanous/layer/2/intensity 1.0",
                "/fanous/cue/go", "/fanous/cue/go", "/fanous/show/lock 1", "/fanous/show/lock 0", "/fanous/cue/goto 3", "/fanous/cue/goto 5",
                "/fanous/layer/1/media 1 2", "/fanous/layer/1/media 1 3", "/fanous/layer/1/retrigger", "/fanous/layer/1/retrigger",
            ])
    }

    /// B176: the ring keeps the newest 50 rows, oldest first, after it has wrapped; times are Unix seconds of now.
    @Test func recentKeepsTheNewestFiftyInOrder() throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        store.onCommand = { _ in }
        let before = Date().timeIntervalSince1970
        try feed(store, (1...120).map { OSCMessage("/fanous/cue/goto", [.int32(Int32($0))]) })
        let recent = store.recentOSC()
        #expect(recent.map(\.text) == (71...120).map { "/fanous/cue/goto \($0)" })
        #expect(recent.allSatisfy { $0.at >= before - 0.1 && $0.at <= Date().timeIntervalSince1970 + 0.1 })
    }

    /// B176: a row has a small fixed upper bound however large the datagram: at most 8 arguments, strings and the
    /// address cut to 64 characters.
    @Test func recentRowTextIsBounded() throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        store.onCommand = { _ in }
        let long = String(repeating: "x", count: 60_000)
        try feed(store, [
            OSCMessage("/fanous/cue/go", (0..<13_000).map { .int32(Int32($0)) }),
            OSCMessage("/fanous/project/load", [.string(long)]),
        ])
        #expect(
            store.recentOSC().map(\.text) == [
                "/fanous/cue/go 0 1 2 3 4 5 6 7 … (+12992)", "/fanous/project/load \"" + String(repeating: "x", count: 64) + "…\"",
            ])
        #expect(DMXStore.text(OSCMessage("/" + long)).count == 65)
    }
}
