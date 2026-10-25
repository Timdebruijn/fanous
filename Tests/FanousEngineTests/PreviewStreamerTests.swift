// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Metal
import Synchronization
import Testing

@testable import FanousEngine

/// The whole preview path on the GPU: compositor tick → preview tap (output pass into a pooled pixel
/// buffer) → VideoToolbox H.264 → avcC + a key frame access unit in the wire layout (DESIGN.md §11.3).
struct PreviewStreamerTests {
    @Test func canvasTickProducesKeyFrameAndAVCC() async throws {
        let logger = Logger(label: "test")
        let context = try MetalContext()
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) }
        let compositor = try Compositor(
            context: context, canvasWidth: 320, canvasHeight: 180, fps: 60, maxLayers: 1, metrics: MetricsRing(capacity: 64), parameters: parameters,
            logger: logger)
        let streamer = try PreviewStreamer(context: context, width: 320, height: 180, fps: 30, canvasFPS: 60, parameters: parameters, logger: logger)
        let frames = Mutex<[(payload: [UInt8], avcC: [UInt8])]>([])
        streamer.onFrame = { payload, avcC in frames.withLock { $0.append((payload, avcC)) } }
        streamer.alwaysEncode = true  // no WebSocket subscriber in this test
        compositor.previewTap = { canvas, buffer, target in streamer.tap(canvas: canvas, commandBuffer: buffer, target: target) }
        // every second tick is a preview frame at 30 of 60 fps
        for i in 0..<8 { compositor.tick(target: 1 + Double(i) / 60, drawable: nil) }
        for _ in 0..<100 where frames.withLock({ $0.count }) < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let delivered = frames.withLock { $0 }
        #expect(delivered.count >= 2, "expected encoded frames, got \(delivered.count)")
        let first = try #require(delivered.first)
        #expect(first.payload[0] == 1, "first access unit is a key frame")
        #expect(first.payload.count > 9 + 16)
        #expect(first.avcC.first == 1)
        #expect(first.avcC.count > 8 && first.avcC[1] == 0x42, "Baseline profile")
        #expect(first.avcC[4] == 0xFF && first.avcC[5] == 0xE1, "4-byte NAL lengths, one SPS")
        // the timestamp is microseconds, big-endian, after the key flag
        var micros: UInt64 = 0
        for i in 1..<9 { micros = micros << 8 | UInt64(first.payload[i]) }
        #expect(micros >= 1_000_000 && micros < 2_000_000)
        #expect(streamer.framesIn.load(ordering: .relaxed) == 4)
    }
}
