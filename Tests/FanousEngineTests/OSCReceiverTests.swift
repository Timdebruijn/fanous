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
    /// One UDP socket to loopback; datagrams go out back-to-back.
    static func send(_ messages: [OSCMessage], to port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        for message in messages {
            let bytes = message.encoded()
            _ = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
    }

    /// A console fires hundreds of datagrams back-to-back from one socket; none may be lost (B30).
    @Test func udpBurstFromOneSocketArrivesComplete() async throws {
        let logger = Logger(label: "test")
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: logger)
        let seen = Mutex<Set<Double>>([])
        store.onCommand = { if case .cueGoto(let n) = $0 { seen.withLock { _ = $0.insert(n) } } }
        let port = try freeUDPPort()
        let receiver = OSCReceiver(store: store, logger: logger, port: port)
        try receiver.start()
        defer { receiver.stop() }
        // listening once a goto 0 (no cue of the burst) arrives; a fixed 300 ms was too short on a loaded Mac (B67)
        #expect(await waitUntil(every: .milliseconds(50)) {
            Self.send([OSCMessage("/fanous/cue/goto", [.float32(0)])], to: port)
            return seen.withLock { $0.contains(0) }
        })

        // the engine's DMX queue is busy for a moment (Art-Net frames, snapshot publishing) while the console fires
        store.queue.async { Thread.sleep(forTimeInterval: 0.2) }
        // fresh socket per burst: the first datagram of a flow is the one that creates the connection
        let count = 5 * 200 + 1  // and the probe's 0
        for burst in 0..<5 {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            for i in 1...200 {
                let bytes = OSCMessage("/fanous/cue/goto", [.float32(Float(burst * 200 + i))]).encoded()
                let sent = withUnsafePointer(to: &address) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                #expect(sent == bytes.count)
            }
        }
        for _ in 0..<50 where seen.withLock({ $0.count }) < count { try await Task.sleep(for: .milliseconds(100)) }
        #expect(seen.withLock { $0.count } == count)
    }

    /// The Phase 5 demo burst: 4 layers x (media, intensity, scale, position) back-to-back must all land in the resolvers.
    @Test func layerParameterBurstResolvesEveryLayer() async throws {
        let logger = Logger(label: "test")
        let store = DMXStore(patch: .standard(layers: 4, outputs: 1), logger: logger)
        let listening = Mutex(false)
        store.onCommand = { _ in listening.withLock { $0 = true } }
        let port = try freeUDPPort()
        let receiver = OSCReceiver(store: store, logger: logger, port: port)
        try receiver.start()
        defer { receiver.stop() }
        // listening once a probe command arrives; a fixed 300 ms was too short on a loaded Mac (B67)
        #expect(await waitUntil(every: .milliseconds(50)) {
            Self.send([OSCMessage("/fanous/cue/goto", [.float32(0)])], to: port)
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
        Self.send(messages, to: port)

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
}
