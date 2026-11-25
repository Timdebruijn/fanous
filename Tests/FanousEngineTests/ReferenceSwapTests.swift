// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Metal
import QuartzCore
import Synchronization
import Testing

@testable import FanousEngine

/// B273: a reference that one thread swaps while a render or feed thread reads it. Each test swaps while the reader
/// runs; the swap itself is the data race, which ThreadSanitizer shows (`swift test --sanitize=thread --filter
/// ReferenceSwap`, docs/DEVELOPMENT.md): on the old code it reports the race, after the fix it is clean. Without TSan
/// the tests check that the swapped value reaches the reader; only the offsets test also fails without it on the old
/// code (the tick's unretained read meets the writer's release: the process aborts on a freed `TimecodeOffsets`).
@Suite(.cleansTempFiles)
struct ReferenceSwapGPUTests {
    /// `Compositor.timecodeOffsets`, written by Control (`timecode.set`) while the tick chases.
    @Test func timecodeOffsetsSwappedWhileTheTickChases() async throws {
        let context = try MetalContext()
        let (compositor, parameters) = try makeCompositor(context, size: (64, 36))
        let url = tempFile("fanous-b273-chase", ext: "mov")
        try await writePatternMovie(to: url, size: (64, 36), fps: 25, frames: 100, codec: .hap(.hap))
        let movie = try await MovieSource.open(url: url, device: context.device, poolSize: 3)  // ring + 1, as the loader opens it (B386)
        let ring = FrameRing(capacity: 2)
        let playback = LayerPlayback(key: MediaKey(folder: 1, file: 1), movie: movie, decoder: LayerDecoder(source: movie, ring: ring, logger: testLogger), ring: ring)
        compositor.setLayers([.playing(playback)])
        let clock = TimecodeClock()
        compositor.timecode = clock
        parameters.write { slot in
            slot.sequence = 1
            slot.layers[0].intensity = 1
            slot.layers[0].folder = 1
            slot.layers[0].file = 1
            slot.layers[0].playMode = .timecode
        }
        clock.update(Timecode(frameCount: 100, rate: .fps25), at: 1000, source: "test")
        let done = Atomic(false)
        let swaps = Atomic(0)
        async let writer: Void = offPool {
            while !done.load(ordering: .acquiring) {
                compositor.timecodeOffsets = TimecodeOffsets(project: Double(swaps.load(ordering: .relaxed) % 3), layers: [1: 1])
                swaps.add(1, ordering: .relaxed)
            }
        }
        try await offPool {
            ReferenceSwapTests.spin { swaps.load(ordering: .relaxed) > 0 }  // the writer runs: the ticks overlap its swaps
            for _ in 0..<300 { compositor.tick(target: 1000, drawable: nil) }
            done.store(true, ordering: .releasing)
        }
        try await writer
        #expect(swaps.load(ordering: .relaxed) > 1)
        // the next tick chases with the offsets set last: (100 − 25 − 5) frames = frame 70, then (100 − 10 − 0) = 90
        compositor.timecodeOffsets = TimecodeOffsets(project: 25, layers: [1: 5])
        compositor.tick(target: 1000, drawable: nil)
        #expect(abs(playback.clock.position - 70) < 1e-6, "\(playback.clock.position)")
        compositor.timecodeOffsets = TimecodeOffsets(project: 10, layers: [:])
        compositor.tick(target: 1000, drawable: nil)
        #expect(abs(playback.clock.position - 90) < 1e-6, "\(playback.clock.position)")
    }

    /// A set made to replace `marker`: the render thread that draws it takes and clears `previous` (`OutputPass.adopt`),
    /// which shows that thread drew this set.
    static func set(_ plan: OutputPlan, replacing marker: OutputSet) -> OutputSet { OutputSet(plans: [plan], previous: marker) }

    /// B356: `RenderLayer.current`, swapped by the tick at every hand-off while the feed (`publishLive`) and CITP
    /// (`citpLayers`) read the layer's frame through `currentFrame`. The old `currentFrame` read `current` itself; now
    /// the tick publishes the frame in an atomic. 1000 swaps between a still (frame 0) and a movie parked at frame 7.
    @Test func currentSwappedWhileTheFeedReadsTheFrame() async throws {
        let context = try MetalContext()
        let (compositor, parameters) = try makeCompositor(context, size: (64, 36))
        let url = tempFile("fanous-b356-frame", ext: "mov")
        try await writePatternMovie(to: url, size: (64, 36), fps: 25, frames: 20, codec: .hap(.hap))
        let source = try await MovieSource.open(url: url, device: context.device, poolSize: 3)
        let ring = FrameRing(capacity: 2)
        let movie = LayerPlayback(key: MediaKey(folder: 1, file: 1), movie: source, decoder: LayerDecoder(source: source, ring: ring, logger: testLogger), ring: ring)
        movie.clock.position = 7
        let layer = RenderLayer.playing(movie)
        compositor.setLayers([layer])
        parameters.write { slot in
            slot.sequence = 1
            slot.layers[0].intensity = 1
            slot.layers[0].folder = 1
            slot.layers[0].file = 1
            slot.layers[0].speed = 0  // the movie stays on frame 7
        }
        let done = Atomic(false)
        let reads = Atomic(0)
        let wrong = Atomic(0)
        async let feed: Void = offPool {
            while !done.load(ordering: .acquiring) {
                let frame = layer.currentFrame
                if frame != 0 && frame != 7 { wrong.add(1, ordering: .relaxed) }
                reads.add(1, ordering: .relaxed)
            }
        }
        try await offPool {
            ReferenceSwapTests.spin { reads.load(ordering: .relaxed) > 0 }  // the feed thread runs: the swaps overlap its reads
            for i in 0..<1000 {
                if i % 2 == 0 {  // a still through the hand-off: swapped in by this tick, the movie retired
                    layer.pending.withLock { $0.set = true; $0.playback = LayerPlayback(key: MediaKey(folder: 1, file: 1), still: DecodedFrame(poolIndex: 0)) }
                } else {
                    layer.current = movie  // the tick's own thread: the movie back without a decoded frame
                }
                compositor.tick(target: 1000 + Double(i) / 60, drawable: nil)
            }
            done.store(true, ordering: .releasing)
        }
        try await feed
        #expect(reads.load(ordering: .relaxed) > 1)
        #expect(wrong.load(ordering: .relaxed) == 0)
        #expect(layer.currentFrame == 7, "the last tick played the movie")
        layer.pending.withLock { $0.set = true; $0.playback = nil }  // no media
        compositor.tick(target: 1100, drawable: nil)
        #expect(layer.currentFrame == 0)
    }

    /// `PreviewStreamer.outputSet`, written by `Engine.previewOutput` at every mapping edit while the compositor taps.
    @Test func previewOutputSetSwappedWhileTheCompositorTaps() async throws {
        let context = try MetalContext()
        let (compositor, parameters) = try makeCompositor(context, size: (64, 36), fps: 240)
        let streamer = try PreviewStreamer(context: context, width: 64, height: 36, fps: 120, canvasFPS: 240, parameters: parameters, logger: testLogger)
        streamer.alwaysEncode = true  // no subscriber here
        compositor.previewTap = { canvas, buffer, target, live in streamer.tap(canvas: canvas, commandBuffer: buffer, target: target, live: live) }
        let plan = try OutputCompiler(device: context.device).compile(OutputConfig(id: 1), index: 1, drawable: (64, 36))
        let marker = OutputSet(plans: [])
        let driver = HeadlessDriver(fps: 240, compositor: compositor)
        defer { driver.stop() }
        for _ in 0..<20 {
            let set = Self.set(plan, replacing: marker)
            streamer.outputSet = set
            #expect(await waitUntil { set.previous.withLock { $0 } == nil }, "the tap never drew the new set")
        }
    }

    /// `SecondaryDriver.set`, written on the main actor at every mapping edit while the display's thread presents. A
    /// layer on no display still hands out drawables.
    @Test func secondaryDriverSetSwappedWhileItPresents() async throws {
        let context = try MetalContext()
        let parameters = TripleBuffer({ ParameterSnapshotSlot(maxLayers: 1) }, copy: { $0.copy(from: $1) })  // as DMXStore's: a secondary display reads `withLatest`
        let (compositor, _) = try makeCompositor(context, size: (64, 36), parameters: parameters)
        let layer = CAMetalLayer()
        layer.device = context.device
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 64, height: 36)
        let uniforms = try (0..<3).map { _ in try #require(context.device.makeBuffer(length: Compositor.mappedUniformsLength, options: .storageModeShared)) }
        let plan = try OutputCompiler(device: context.device).compile(OutputConfig(id: 1), index: 1, drawable: (64, 36))
        let marker = OutputSet(plans: [])
        let first = Self.set(plan, replacing: marker)
        let driver = SecondaryDriver(layer: layer, hz: 240, compositor: compositor, set: first, uniforms: uniforms)
        defer { driver.stop() }
        #expect(await waitUntil { first.previous.withLock { $0 } == nil }, "the driver never presented")
        for _ in 0..<20 {
            let set = Self.set(plan, replacing: marker)
            driver.set = set
            #expect(await waitUntil { set.previous.withLock { $0 } == nil }, "the driver never presented the new set")
        }
    }
}

/// The feed queue's side of B273: `Engine.ltc`/`mtc`, swapped on Control by `applyTimecodeSettings` while the feed queue
/// builds `live.timecode`. MTC only: an LTC input asks for the microphone.
struct ReferenceSwapTests {
    @Test func timecodeInputsSwappedWhileTheFeedReadsThem() async throws {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        let documents = try ["mtc", "off"].map { source in
            var project = testProject(layers: 1, outputs: 0)
            try project.set(["source": .string(source), "channel": 0, "offset": 0, "freewheel": 2, "layerOffsets": [:]], at: "/timecode")
            return project
        }
        let done = Atomic(false)
        let reads = Atomic(0)
        async let feed: Void = offPool {
            while !done.load(ordering: .acquiring) {
                _ = engine.timecodeLive()
                reads.add(1, ordering: .relaxed)
            }
        }
        try await offPool {
            Self.spin { reads.load(ordering: .relaxed) > 0 }  // the feed thread runs: the swaps overlap its reads
            for i in 0..<40 { engine.projectChanged(documents[i % 2]) }  // ends on off: no MTC input left open
            done.store(true, ordering: .releasing)
        }
        try await feed
        #expect(reads.load(ordering: .relaxed) > 1)
        // the swapped input reaches the feed: an open MTC input reports its missing source, none reports nothing
        engine.projectChanged(documents[0])
        #expect(engine.timecodeLive()["error"] == .string(MTCInput.missing(nil)))
        engine.projectChanged(documents[1])
        #expect(engine.timecodeLive()["error"] == .null)
    }

    /// On a thread of the test's own: until `condition` holds, for 10 s at most (the expectations after it then fail).
    static func spin(_ condition: () -> Bool) {
        let end = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < end { sched_yield() }
    }
}
