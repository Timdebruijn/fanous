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
        let logger = Logger(label: "test")
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: logger)
        let seen = Mutex<Set<Double>>([])
        store.onCommand = { if case .cueGoto(let n) = $0 { seen.withLock { _ = $0.insert(n) } } }
        let port = UInt16.random(in: 40_000..<60_000)
        let receiver = OSCReceiver(store: store, logger: logger, port: port)
        try receiver.start()
        defer { receiver.stop() }
        try await Task.sleep(for: .milliseconds(300))

        // the engine's DMX queue is busy for a moment (Art-Net frames, snapshot publishing) while the console fires
        store.queue.async { Thread.sleep(forTimeInterval: 0.2) }
        // fresh socket per burst: the first datagram of a flow is the one that creates the connection
        let count = 5 * 200
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
}
