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
        compositor.previewBook = { streamer.book() }
        // the first preview frame starts making the encoder (B66) and skips H.264 while it is made; a tick after the GPU
        // finished books it (B109)
        for i in 0..<2 { compositor.tick(target: 0.5 + Double(i) / 60, drawable: nil) }
        drainGPU(context.queue)
        compositor.tick(target: 0.5 + 2.0 / 60, drawable: nil)
        for _ in 0..<250 where !streamer.hasEncoder { try await Task.sleep(for: .milliseconds(20)) }
        #expect(streamer.hasEncoder)
        // every second tick is a preview frame at 30 of 60 fps; the last tick only books
        for i in 0..<7 { compositor.tick(target: 1 + Double(i) / 60, drawable: nil) }
        drainGPU(context.queue)
        compositor.tick(target: 1 + 7.0 / 60, drawable: nil)
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
        #expect(streamer.framesIn.load(ordering: .relaxed) == 1 + 4)
    }

    /// B66: no VideoToolbox session at init (engine start makes the canvas streamer); JPEG works without one, the first
    /// H.264 subscriber makes it, the last one leaving releases it, and a streamer that never had one goes away fine.
    @Test func theH264SessionIsMadeOnTheFirstH264SubscriberAndReleasedWithTheLast() async throws {
        let rig = try PreviewHubTests.Rig()
        let streamer = rig.hub.canvas
        #expect(!streamer.hasEncoder, "init makes no encoder")
        let viewer = rig.connection()
        #expect(rig.attach("canvas", viewer, stream: 1, jpeg: true))
        for _ in 0..<50 where streamer.latestJPEG.withLock({ $0 }) == nil {
            rig.tick(12)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(streamer.latestJPEG.withLock { $0 } != nil, "JPEG before any H.264 subscriber")
        #expect(streamer.jpegOut.load(ordering: .relaxed) > 0 && streamer.jpegFailed.load(ordering: .relaxed) == 0)
        #expect(streamer.jpegDropped.load(ordering: .relaxed) > 0, "the rig's connection has no socket: each send is refused")
        #expect(!streamer.hasEncoder)
        #expect(rig.attach("canvas", viewer, stream: 2))
        for _ in 0..<250 where !streamer.hasEncoder { try await Task.sleep(for: .milliseconds(20)) }
        #expect(streamer.hasEncoder, "the first H.264 subscriber makes the encoder")
        rig.hub.unsubscribe(connection: viewer, stream: 2)
        #expect(!streamer.hasEncoder, "released with the last H.264 subscriber")
        #expect(streamer.hasSubscribers, "the JPEG viewer stays")
        // never had a session: deinit has nothing to invalidate
        weak var gone: PreviewStreamer?
        do {
            let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) }
            let unused = try PreviewStreamer(context: rig.context, width: 320, height: 180, fps: 30, canvasFPS: 60, parameters: parameters, logger: Logger(label: "test"))
            gone = unused
            #expect(!unused.hasEncoder)
        }
        #expect(gone == nil)
    }

    /// B109: what one preview tap, one thumbnail pass and one Syphon publish allocate on the calling (compositor) thread,
    /// and what booking them a tick later adds. Before B109 the taps and the publish each registered a capturing
    /// completion handler: preview tap 16, thumbnail tap 27, Syphon publish 8; after: 13 + 2, 24 + 2, 6 + 0 (M1 Pro,
    /// macOS 27, `-c release`).
    @Test(.enabled(if: MallocCounter.availableOrRequired, "malloc_logger not exported by libsystem_malloc on this macOS"))
    func mallocCounterStreamerTapsAndSyphonPublish() throws {
        try #require(MallocCounter.available, "malloc_logger not exported by libsystem_malloc on this macOS")
        let rig = try ThumbnailStreamerTests.Rig(layers: 1, grid: 0)
        rig.thumbnails.alwaysEncode = true
        let context = rig.compositor.context
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) }
        let streamer = try PreviewStreamer(context: context, width: 320, height: 180, fps: 60, canvasFPS: 60, parameters: parameters, logger: Logger(label: "test"))
        streamer.alwaysEncode = true
        let output = try SyphonOutput(name: "FanousTest-\(UUID().uuidString)", device: context.device)
        defer { output.stop() }
        let canvas = rig.compositor.latestCanvas
        /// (encode, book): `encode` into a fresh buffer, then `book` once the GPU finished it.
        func measure(_ encode: (MTLCommandBuffer) -> Void, book: () -> Void) throws -> (Int, Int) {
            let buffer = try #require(context.queue.makeCommandBuffer())
            let encoded = MallocCounter.count { encode(buffer) }
            buffer.commit()
            buffer.waitUntilCompleted()
            return (encoded, MallocCounter.count(book))
        }
        var preview = (0, 0), syphon = (0, 0), thumbs = (0, 0)
        for _ in 0..<20 {
            preview = try measure({ streamer.tap(canvas: canvas, commandBuffer: $0, target: 1) }, book: streamer.book)
            syphon = try measure({ output.publish(texture: canvas, commandBuffer: $0) }, book: output.publishCompleted)
        }
        _ = try rig.pass()
        rig.hub.thumbnails = nil  // from here only this test taps the thumbnails
        for _ in 0..<3 {
            rig.tick(15 - rig.compositor.ticks.load(ordering: .relaxed) % 15)  // to a pass tick
            usleep(50_000)  // the last set's encode has returned: this pass is not skipped
            thumbs = try measure({ rig.thumbnails.tap(commandBuffer: $0) }, book: rig.thumbnails.book)
        }
        #expect(rig.thumbnails.passes.load(ordering: .relaxed) == 4)
        // the last set is published before the rig goes (its `onPublish` holds the rig unowned)
        for _ in 0..<300 where rig.published.withLock({ $0.count }) < 4 { usleep(10_000) }
        #expect(rig.published.withLock { $0.count } == 4)
        #expect(streamer.skipped.load(ordering: .relaxed) == 0 && rig.thumbnails.skipped.load(ordering: .relaxed) == 0)
        // the encode side is mostly Core Video and Metal (OS-dependent, printed); booking is ours: one dispatch to the
        // streamer's queue (closure context and block), nothing for Syphon
        #if !DEBUG
            #expect(preview.1 <= 2 && thumbs.1 <= 2 && syphon.1 == 0, "booking: preview \(preview.1), thumbnails \(thumbs.1), Syphon \(syphon.1)")
        #endif
        print("B109 mallocs (encode + book): preview tap \(preview), thumbnail tap \(thumbs), syphon publish \(syphon)")
    }
}
