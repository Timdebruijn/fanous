// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Metal
import Testing

@testable import FanousEngine

/// B371: a movie picture drawn with a frame other than the one its clock asked for is counted (per tick in the metrics
/// record, since start per layer). The real decoder, ring and playback on a compositor the test ticks, one frame per
/// tick; nobody watches, so no GPU work unless a test asks for the drawn path. Metal: local only, not on `--hosted`.
@Suite(.serialized, .cleansTempFiles)
struct StaleFrameTests {
    static let capacity = 8

    final class Rig {
        let compositor: Compositor
        let layer: RenderLayer
        let metrics = MetricsRing(capacity: 4096)
        let playback: LayerPlayback
        private let parameters: TripleBuffer<ParameterSnapshotSlot>
        private var ticks = 0
        private var sequence: UInt64 = 0

        /// A 20-frame 25 fps movie on a 25 fps compositor, playing in `mode`; the decode thread is not started yet.
        /// `drawn`: every tick encodes and commits a command buffer (the record written after the encode), else idle ticks.
        init(mode: PlayMode, frames: Int = 20, drawn: Bool = false) async throws {
            let url = try tempDir("fanous-ingest-tests").appending(path: "clip.mov")
            try await writePatternMovie(to: url, size: (128, 64), fps: 25, frames: frames)
            let context = try MetalContext()
            let source = try await MovieSource.open(url: url, device: context.device, poolSize: StaleFrameTests.capacity)
            let ring = FrameRing(capacity: StaleFrameTests.capacity)
            playback = LayerPlayback(
                key: MediaKey(folder: 1, file: 1), movie: source, decoder: LayerDecoder(source: source, ring: ring, logger: testLogger), ring: ring)
            (compositor, parameters) = try makeCompositor(context, size: (64, 36), fps: 25, metrics: metrics)
            compositor.skipsIdleWork = !drawn
            layer = .playing(playback)
            compositor.setLayers([layer])
            sequence += 1
            let sequence = sequence
            parameters.write { slot in
                slot.sequence = sequence
                slot.layers[0].intensity = 1
                slot.layers[0].speed = 1
                slot.layers[0].folder = 1
                slot.layers[0].file = 1
                slot.layers[0].playMode = mode
            }
        }

        var decoder: LayerDecoder { playback.decoder! }
        var ring: FrameRing { playback.ring! }

        /// One tick; with `fed`, first waits until the decode thread has filled the ring (a decoder faster than the clock).
        func tick(fed: Bool = true) async {
            if fed {
                #expect(await waitUntil(.seconds(2)) { self.ring.count == self.ring.capacity }, "the decode thread filled the ring before tick \(ticks)")
            }
            compositor.tick(target: 3600 + Double(ticks) / 25, drawable: nil)
            ticks += 1
        }

        /// Stale and missed pictures over every tick so far.
        var stale: Int { metrics.totalStaleFrames.load(ordering: .relaxed) }
        var misses: Int { metrics.summary(seconds: 1e6, now: 3600 + 1e5).textureMisses }
        var shown: Int { playback.currentShown }
        var clockFrame: Int { playback.clock.frame(lo: 0, hi: playback.frameCount - 1) }
    }

    // a tick with no frame at all is a texture miss and not also stale; a healthy layer then counts nothing, across
    // 15 loop wraps
    @Test func aHealthyLayerCountsNoStaleFrameAcrossLoopWraps() async throws {
        let rig = try await Rig(mode: .loopForward)
        defer { rig.decoder.stop() }
        await rig.tick(fed: false)  // the decode thread is not running: an empty ring
        #expect(rig.misses == 1 && rig.stale == 0)
        rig.decoder.start(name: "test.decode")
        for _ in 0..<300 { await rig.tick() }
        #expect(rig.misses == 1)
        #expect(rig.stale == 0)
        #expect(rig.layer.staleFrames.load(ordering: .relaxed) == 0)
    }

    // a decoder that stops delivering: the frames already in the ring are shown on time, every tick after that holds the
    // last one and is stale (the tick record, the total and the layer's count agree). On the drawn path: the record
    // written after the encode carries the count
    @Test func aDecoderThatFallsBehindCountsEveryHeldTick() async throws {
        let rig = try await Rig(mode: .loopForward, drawn: true)
        rig.decoder.start(name: "test.decode")
        for _ in 0..<10 { await rig.tick() }
        #expect(rig.stale == 0)
        await waitUntil { rig.ring.count == rig.ring.capacity }
        // the ring is full: the shown frame, the two before it (the select keeps the last two shown when it pops) and 5 ahead
        rig.decoder.stop()
        var held = 0
        for _ in 0..<20 {
            await rig.tick(fed: false)
            if rig.shown != rig.clockFrame { held += 1 }
        }
        // the 5 frames ahead are on time, the rest held; one more on time when the decode thread read `running` just
        // before `stop()` and found the slot the first tick freed (it decodes at most that one frame, then exits)
        #expect([15, 14].contains(held), "\(held)")
        #expect(rig.stale == held)
        #expect(rig.layer.staleFrames.load(ordering: .relaxed) == held)
        #expect(rig.metrics.summary(seconds: 1e6, now: 3600 + 1e5).staleFrames == held)
        #expect(rig.misses == 0, "a held frame is not a miss")
        #expect(rig.metrics.summary(seconds: 1e6, now: 3600 + 1e5).idle == 0, "every tick took the drawn path")
    }

    // row B293: at a bounce turn the ring is full of frames on the old side and the decode thread sleeps on it; the layer
    // holds one frame until the clock is `capacity + 2` frames past it and the ring drains. Measured here: every turn,
    // at either end, holds exactly that long (the stale runs are read from the shown frame after each tick)
    @Test func aBounceTurnCountsTheTicksItHolds() async throws {
        let rig = try await Rig(mode: .bounce)
        rig.decoder.start(name: "test.decode")
        defer { rig.decoder.stop() }
        var runs: [Int] = []
        var run = 0
        for _ in 0..<100 {  // 20 frames: four turns
            await rig.tick()
            if rig.shown != rig.clockFrame {
                run += 1
            } else if run > 0 {
                runs.append(run)
                run = 0
            }
        }
        #expect(runs.count >= 3 && runs.allSatisfy { $0 == StaleFrameTests.capacity + 2 }, "\(runs)")
        #expect(rig.stale == runs.reduce(run, +))
        #expect(rig.layer.staleFrames.load(ordering: .relaxed) == rig.stale)
        #expect(rig.misses == 0)
    }

    final class Live: LiveTextureSource, @unchecked Sendable {
        let frame: LiveFrame
        init(_ texture: MTLTexture) { frame = LiveFrame(texture0: texture, texture1: nil, kind: .rgba, bottomUp: false) }
        var latestFrame: LiveFrame? { frame }
        func stop() {}
    }

    // a live input has no clock frame: its picture is never stale (its frame number is −1, the clock's 0)
    @Test func aLiveInputNeverCounts() throws {
        let context = try MetalContext()
        let metrics = MetricsRing(capacity: 64)
        let (compositor, parameters) = try makeCompositor(context, size: (64, 36), fps: 25, metrics: metrics)
        compositor.skipsIdleWork = true
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 16, height: 9, mipmapped: false)
        let texture = try #require(context.device.makeTexture(descriptor: descriptor))
        let layer = RenderLayer.playing(LayerPlayback(key: MediaKey(folder: 0, file: 1), live: Live(texture)))
        compositor.setLayers([layer])
        parameters.write { slot in
            slot.sequence = 1
            slot.layers[0].intensity = 1
            slot.layers[0].folder = 0
            slot.layers[0].file = 1
        }
        for i in 0..<10 { compositor.tick(target: 3600 + Double(i) / 25, drawable: nil) }
        #expect(metrics.totalStaleFrames.load(ordering: .relaxed) == 0)
        #expect(metrics.summary(seconds: 1e6, now: 3600 + 1e5).textureMisses == 0, "it was drawn")
    }
}

/// B371: the per-tick stale count in the summary and the total since start; no GPU.
struct MetricsStaleFramesTests {
    @Test func theSummaryAndTheTotalAddTheTicksCounts() {
        let ring = MetricsRing(capacity: 8)
        for (i, stale) in [0, 2, 0, 1, 3].enumerated() {
            var record = FrameRecord()
            record.target = 100 + Double(i) / 10
            record.staleFrames = UInt16(stale)
            _ = ring.write(record)
        }
        #expect(ring.totalStaleFrames.load(ordering: .relaxed) == 6)
        #expect(ring.summary(seconds: 1, now: 100.5).staleFrames == 6)
        #expect(ring.summary(seconds: 0.15, now: 100.4).staleFrames == 4, "the window: the last two ticks")
        #expect(ring.summary(seconds: 1, now: 100.5).description.contains("staleFrames 6"))
    }
}
