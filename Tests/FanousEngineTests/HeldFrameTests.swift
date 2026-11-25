// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Metal
import Testing

@testable import FanousEngine

/// B386: after a seek drains the ring, the frame the layer keeps showing is the playback's own held frame, which took
/// the drained slot's picture and pool texture; the slot got the spare one. The decode thread refills that slot with the
/// frame after the seek: before, the held frame's label and textures changed under the GPU while `prepare` and `encode`
/// read them in the same tick, and a HAP frame, decoded in place into its pool texture, would change pixels even under
/// a copied reference.
@Suite(.cleansTempFiles) struct HeldFrameTests {
    @Test func theFrameHeldAcrossADrainSurvivesTheSlotsRefill() async throws {
        let directory = try tempDir("fanous-held-frame-tests")
        let url = directory.appending(path: "clip.mov")
        try await IngestQueueTests.writeSource(to: url, seconds: 2, audio: false)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try await MovieSource.open(url: url, device: device, poolSize: 4)
        let ring = FrameRing(capacity: 4)
        // the decoder is never started: the test writes the ring as the decode thread would, into a pool of fixed
        // textures per pool index like HAP (one spare, as the loader opens a movie with ring capacity + 1)
        let playback = LayerPlayback(key: MediaKey(folder: 1, file: 1), movie: source, decoder: LayerDecoder(source: source, ring: ring, logger: testLogger), ring: ring)
        let pool = try (0...4).map { _ -> MTLTexture in
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
            return try #require(device.makeTexture(descriptor: d))
        }
        func decode(_ i: Int) throws {
            let slot = try #require(ring.slotForWriting())
            slot.clear()
            slot.frameIndex = i
            slot.texture0 = pool[slot.poolIndex]
            ring.commit()
        }
        for i in 0..<4 { try decode(i) }  // the decode thread filled frames 0...3 (a 20-frame clip)
        let shown = try #require(playback.frame(at: 0, direction: 1))
        let shownTexture = try #require(shown.texture0)
        #expect(shown.frameIndex == 0 && shownTexture === pool[0])
        // a seek: everything in the ring is on the wrong side, it drains, the layer holds the picture it showed
        let held = try #require(playback.frame(at: 10, direction: 1))
        #expect(ring.isEmpty && held.frameIndex == 0 && held.texture0 === shownTexture)
        // the decode thread refills the freed slots with the frames after the seek, the slot of frame 0 first: it must
        // decode into the spare pool texture, not into the one the GPU reads
        for i in 10..<14 { try decode(i) }
        #expect(held.frameIndex == 0 && held.texture0 === shownTexture, "the held frame was rewritten under the GPU: \(held.frameIndex)")
        for i in 0..<4 { #expect(ring.peek(i)?.texture0 !== shownTexture, "slot \(i) decoded into the held frame's texture") }
        #expect(playback.holdFrame === held && playback.holdFrameIndex == 0)
        // the next tick lands on the seek's frame: the held frame is no longer the one shown
        let landed = try #require(playback.frame(at: 10, direction: 1))
        #expect(landed.frameIndex == 10 && landed !== held)
    }
}
