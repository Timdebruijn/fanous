// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Metal
import Testing

@testable import FanousEngine

/// The decode thread sleeps on a full ring and is only woken by a changed request or a freed slot.
@Suite(.serialized) struct LayerDecoderTests {
    @Test func aFullRingSleepsUntilTheRequestChanges() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "clip.mov")
        try await IngestQueueTests.writeSource(to: url, seconds: 2, audio: false)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try await MovieSource.open(url: url, device: device, poolSize: 4)
        let ring = FrameRing(capacity: 4)
        let decoder = LayerDecoder(source: source, ring: ring, logger: Logger(label: "decoder-test"))
        decoder.start(name: "test.decode")
        defer { decoder.stop() }

        decoder.request(frame: 0, direction: 1)
        for _ in 0..<200 where ring.count < 4 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(ring.count == 4, "the ring fills")

        // a paused layer asks for the same frame every tick: one wake-up for the first request, none after
        let wakeups = decoder.wakeups.load(ordering: .relaxed)
        for _ in 0..<300 { decoder.request(frame: 0, direction: 1) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(decoder.wakeups.load(ordering: .relaxed) == wakeups, "identical requests wake nobody")
        let decodedWhileAsleep = decoder.decoded.load(ordering: .relaxed)
        try await Task.sleep(for: .milliseconds(200))
        #expect(decoder.decoded.load(ordering: .relaxed) == decodedWhileAsleep, "a full ring decodes nothing")

        // a new frame wakes it: the compositor popped a slot, the thread refills it
        ring.pop()
        decoder.request(frame: 1, direction: 1)
        for _ in 0..<200 where ring.count < 4 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(ring.count == 4, "refilled after the wake-up")
        #expect(decoder.wakeups.load(ordering: .relaxed) == wakeups + 1)

        // and a direction change is a request of its own
        decoder.request(frame: 1, direction: -1)
        #expect(decoder.wakeups.load(ordering: .relaxed) == wakeups + 2)
    }
}
