// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Metal
import Testing

@testable import FanousEngine

/// B386: after a seek drains the ring, the frame the layer keeps showing is a copy owned by the playback, not the freed
/// ring slot. The decode thread refills that slot with the frame after the seek: before, the held frame's label and
/// textures changed under the GPU while `prepare` and `encode` read them in the same tick.
@Suite(.cleansTempFiles) struct HeldFrameTests {
    @Test func theFrameHeldAcrossADrainSurvivesTheSlotsRefill() async throws {
        let directory = try tempDir("fanous-held-frame-tests")
        let url = directory.appending(path: "clip.mov")
        try await IngestQueueTests.writeSource(to: url, seconds: 2, audio: false)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try await MovieSource.open(url: url, device: device, poolSize: 4)
        let ring = FrameRing(capacity: 4)
        // the decoder is never started: the test writes the ring as the decode thread would
        let playback = LayerPlayback(key: MediaKey(folder: 1, file: 1), movie: source, decoder: LayerDecoder(source: source, ring: ring, logger: testLogger), ring: ring)
        func texture() throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
            return try #require(device.makeTexture(descriptor: d))
        }
        // the decode thread filled frames 0...3
        for i in 0..<4 {
            let slot = try #require(ring.slotForWriting())
            slot.clear()
            slot.frameIndex = i
            slot.texture0 = try texture()
            ring.commit()
        }
        let shown = try #require(playback.frame(at: 0, direction: 1))
        let shownTexture = try #require(shown.texture0)
        #expect(shown.frameIndex == 0)
        // a seek far away: everything in the ring is on the wrong side, it drains, the layer holds the picture it showed
        let held = try #require(playback.frame(at: 50, direction: 1))
        #expect(ring.isEmpty && held.frameIndex == 0 && held.texture0 === shownTexture)
        // the decode thread refills the freed slots with the frames after the seek, the slot of frame 0 first
        for i in 50..<54 {
            let slot = try #require(ring.slotForWriting())
            slot.clear()
            slot.frameIndex = i
            slot.texture0 = try texture()
            ring.commit()
        }
        #expect(held.frameIndex == 0 && held.texture0 === shownTexture, "the held frame was rewritten under the GPU: \(held.frameIndex)")
        #expect(playback.holdFrame === held && playback.holdFrameIndex == 0)
        // the next tick lands on the seek's frame: the copy is no longer the held frame
        let landed = try #require(playback.frame(at: 50, direction: 1))
        #expect(landed.frameIndex == 50 && landed !== held)
    }
}
