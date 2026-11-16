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
        store.onCommand = { if case .cueGoto(let n) = $0 { seen.withLock { _ = $0.insert(n) } }; return true }
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
        store.onCommand = { _ in listening.withLock { $0 = true }; return true }
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

    /// B176: every accepted message lands in `live.osc.recent` as it was sent; refused, unknown and malformed ones and
    /// the feedback requests do not, and a run on one address holds one row with its last value.
    @Test func recentListsAcceptedMessagesInTheirOSCSpelling() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        store.onCommand = { if case .cueGoto(99) = $0 { return false }; return true }  // the engine has no cue 99
        let receiver = OSCReceiver(store: store, logger: testLogger, port: 0)
        try receiver.start()
        defer { receiver.stop() }
        let port = try await listeningPort { receiver.boundUDPPort }
        #expect(await waitUntil(every: .milliseconds(50)) {
            sendUDP(OSCMessage("/fanous/cue/go").encoded(), to: port)
            return !store.recentOSC().isEmpty
        })

        let sweep = (0..<500).map { OSCMessage("/fanous/layer/1/intensity", [.float32(Float($0) / 499)]) }
        let messages =
            [
                OSCMessage("/fanous/cue/goto", [.int32(3)]),
                OSCMessage("/fanous/cue/goto", [.int32(99)]),  // refused by the engine
                OSCMessage("/fanous/nothing", [.int32(1)]),  // not an address
                OSCMessage("/fanous/layer/9/intensity", [.float32(1)]),  // no layer 9
                OSCMessage("/fanous/layer/1/intensity", [.string("x")]),  // no value
                OSCMessage("/fanous/get"),  // answered (with a feedback server), never listed
            ] + sweep + [OSCMessage("/fanous/layer/1/media", [.int32(2), .int32(7)]), OSCMessage("/fanous/project/load", [.string("Show A")])]
        sendUDP(messages.map { $0.encoded() }, to: port)
        await waitUntil { store.recentOSC().last?.text == "/fanous/project/load \"Show A\"" }
        #expect(
            store.recentOSC().map(\.text) == [
                "/fanous/cue/go", "/fanous/cue/goto 3", "/fanous/layer/1/intensity 1.0", "/fanous/layer/1/media 2 7", "/fanous/project/load \"Show A\"",
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
}
