// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Metal
import Testing

@testable import FanousEngine

/// B294: the first frame a file shows is its start position (the in point, or the out point in a reverse mode), not
/// frame 0. The loader used to ask the decoder for frame 0 before the compositor's hand-off asked for the start, so the
/// ring's first frames were 0, 1, 2 and the swap drew them. Compositor-level, a real movie and decoder (GPU: not hosted).
@Suite(.cleansTempFiles) struct FirstFrameTests {
    @Test(arguments: [(PlayMode.loopForward, 0.5 as Float, 10), (PlayMode.loopReverse, 0 as Float, 19)])
    func theFirstFrameShownIsTheStartPosition(mode: PlayMode, inPoint: Float, expected: Int) async throws {
        let directory = try tempDir("fanous-first-frame-tests")
        let url = directory.appending(path: "clip.mov")
        try await IngestQueueTests.writeSource(to: url, seconds: 2, audio: false)  // 20 frames at 10 fps: the in point 0.5 is frame 10, the end 19
        let context = try MetalContext()
        let layer = RenderLayer(index: 0)
        let (compositor, parameters) = try makeCompositor(context, size: (64, 36), maxLayers: 1)
        compositor.skipsIdleWork = true
        layer.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
        compositor.setLayers([layer])
        parameters.write { slot in
            slot.sequence = 1
            slot.layers[0].intensity = 1
            slot.layers[0].folder = 1
            slot.layers[0].file = 1
            slot.layers[0].playMode = mode
            slot.layers[0].inPoint = inPoint
        }
        let source = try await MovieSource.open(url: url, device: context.device, poolSize: 4)
        let ring = FrameRing(capacity: 4)
        let decoder = LayerDecoder(source: source, ring: ring, logger: testLogger)
        decoder.start(name: "test.decode")  // as the loader does: no request of its own
        defer { decoder.stop() }
        let playback = LayerPlayback(key: MediaKey(folder: 1, file: 1), movie: source, decoder: decoder, ring: ring)
        // the loader's latency to the compositor's next tick: a decoder that starts at frame 0 fills the ring with 0...3
        // meanwhile and the swap draws one of them; a decoder that waits for the request decodes nothing yet
        try await Task.sleep(for: .milliseconds(100))
        #expect(ring.isEmpty, "decoded before the hand-off asked for the start frame")
        layer.pending.withLock { $0.set = true; $0.playback = playback }
        var ticks = 0
        func tick() { compositor.tick(target: 3600 + Double(ticks) / 60, drawable: nil); ticks += 1 }
        // tick until the file is on air, and read the frame of that very tick: the one the swap drew
        let deadline = Date().addingTimeInterval(5)
        while layer.current !== playback, Date() < deadline {
            tick()
            if layer.current !== playback { try await Task.sleep(for: .milliseconds(5)) }
        }
        try #require(layer.current === playback, "the staged file did not get its first frame")
        #expect(playback.holdFrameIndex == expected, "first frame shown: \(playback.holdFrameIndex), expected \(expected)")
    }
}
