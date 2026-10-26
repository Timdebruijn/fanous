// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Metal
import QuartzCore
import Testing

@testable import FanousEngine

/// Work that nobody sees is not done: unwatched ticks, unchanged pictures, generators that cannot change.
@Suite(.serialized)
struct CompositorIdleTests {
    static let width = 160, height = 90

    /// A compositor with one layer showing a solid still, parameters at intensity 1.
    struct Rig {
        let context: MetalContext
        let compositor: Compositor
        let layer: RenderLayer
        let parameters: TripleBuffer<ParameterSnapshotSlot>
        let metrics = MetricsRing(capacity: 256)
        var sequence: UInt64 = 1

        init(playback: LayerPlayback? = nil, idleWork: Bool, offscreen: Bool, size: (Int, Int) = (CompositorIdleTests.width, CompositorIdleTests.height)) throws {
            context = try MetalContext()
            parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) }
            compositor = try Compositor(
                context: context, canvasWidth: size.0, canvasHeight: size.1, fps: 60, maxLayers: 1,
                metrics: metrics, parameters: parameters, logger: Logger(label: "idle-test"))
            layer = RenderLayer(index: 0)
            layer.current = try playback ?? Self.stillPlayback(context)
            layer.wanted.store(layer.current?.key.packed ?? 0, ordering: .relaxed)
            compositor.setLayers([layer])
            compositor.skipsIdleWork = idleWork
            if offscreen {
                let d = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: MetalContext.outputFormat, width: size.0, height: size.1, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .shared
                compositor.offscreenOutput = context.device.makeTexture(descriptor: d)
            }
            setIntensity(1)
        }

        static func stillPlayback(_ context: MetalContext) throws -> LayerPlayback {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 16, height: 9, mipmapped: false)
            let texture = try #require(context.device.makeTexture(descriptor: descriptor))
            texture.replace(region: MTLRegionMake2D(0, 0, 16, 9), mipmapLevel: 0, withBytes: [UInt8](repeating: 200, count: 16 * 9 * 4), bytesPerRow: 64)
            let frame = DecodedFrame(poolIndex: 0)
            frame.frameIndex = 0
            frame.kind = .rgba
            frame.texture0 = texture
            return LayerPlayback(key: MediaKey(folder: 1, file: 1), still: frame)
        }

        mutating func setIntensity(_ value: Float) {
            sequence += 1
            let sequence = sequence
            parameters.write { slot in
                slot.sequence = sequence
                slot.layers[0].intensity = value
                slot.layers[0].folder = 1
                slot.layers[0].file = 1
                slot.layers[0].fitMode = .stretch
            }
        }

        func tick(_ n: Int, from start: Int = 0) {
            for i in 0..<n { compositor.tick(target: 3600 + Double(start + i) / 60, drawable: nil) }
        }

        /// Green channel at the centre of the offscreen output (blocks until the GPU is done).
        func centre() -> Int {
            let image = compositor.readbackOutput()
            return Int(image.bgra[(image.height / 2 * image.width + image.width / 2) * 4 + 1])
        }
    }

    /// A bottom-up frame (Syphon) is sampled with v0 and v1 swapped, and the crop sides swap with them.
    @Test func bottomUpFramesSampleFlipped() {
        #expect(Compositor.uvRect(cropLeft: 0, cropTop: 0, cropRight: 0, cropBottom: 0, bottomUp: false) == SIMD4(0, 0, 1, 1))
        #expect(Compositor.uvRect(cropLeft: 0, cropTop: 0, cropRight: 0, cropBottom: 0, bottomUp: true) == SIMD4(0, 1, 1, 0))
        // 10 % off the top of the picture: v0 moves down from the top in Metal order, up from v = 1 in GL order
        #expect(Compositor.uvRect(cropLeft: 0.2, cropTop: 0.1, cropRight: 0.3, cropBottom: 0.4, bottomUp: false) == SIMD4(0.2, 0.1, 0.7, 0.6))
        #expect(Compositor.uvRect(cropLeft: 0.2, cropTop: 0.1, cropRight: 0.3, cropBottom: 0.4, bottomUp: true) == SIMD4(0.2, 0.9, 0.7, 0.4))
    }

    @Test func unwatchedTicksEncodeNothingAndTheFirstWatchedFrameIsComplete() throws {
        let rig = try Rig(idleWork: true, offscreen: false)
        rig.tick(30)
        #expect(rig.compositor.idleTicks.load(ordering: .relaxed) == 30)
        #expect(rig.compositor.completed.load(ordering: .relaxed) == 0, "no command buffer for an unwatched canvas")
        #expect(rig.metrics.summary(seconds: 10, now: 3601).idle == 30, "frames still counted, marked idle")
        // somebody starts watching: the very next canvas holds the picture
        rig.compositor.previewWanted = { true }
        rig.compositor.tick(target: 3600.6, drawable: nil)
        let canvas = rig.compositor.readback()
        let mid = (canvas.height / 2 * canvas.width + canvas.width / 2) * 4
        #expect(canvas.rgba[mid] > 150, "first watched frame is complete, got \(canvas.rgba[mid])")
    }

    @Test func handOffStillRunsWhileUnwatched() throws {
        let rig = try Rig(idleWork: true, offscreen: false)
        let next = try Rig.stillPlayback(rig.context)
        rig.layer.pending.withLock { box in
            box.set = true
            box.playback = next
        }
        rig.tick(2)
        #expect(rig.layer.current === next, "the loader's playback was taken while idle")
        #expect(rig.compositor.idleTicks.load(ordering: .relaxed) == 2)
    }

    @Test func anUnchangedPictureIsNotDrawnAgain() throws {
        var rig = try Rig(idleWork: true, offscreen: true)
        rig.tick(10)
        #expect(rig.compositor.reusedCanvases.load(ordering: .relaxed) == 9, "first tick draws, the rest reuse")
        let before = rig.centre()
        #expect(before > 150)
        rig.setIntensity(0.5)
        rig.tick(1, from: 10)
        #expect(rig.compositor.reusedCanvases.load(ordering: .relaxed) == 9, "a parameter change draws")
        #expect(rig.centre() < before - 30, "the new intensity is on screen")
        rig.tick(5, from: 11)
        #expect(rig.compositor.reusedCanvases.load(ordering: .relaxed) == 14)
        // at least one real redraw per second
        rig.tick(200, from: 20)
        #expect(rig.compositor.reusedCanvases.load(ordering: .relaxed) < 14 + 200 - 2)
    }

    /// Printed, not asserted: GPU time of 600 ticks of a 1080p still, watched (drawn every tick / reused) and unwatched.
    @Test func printIdleSavings() throws {
        func run(idleWork: Bool, offscreen: Bool) throws -> (cpu: Double, gpu: Double) {
            let rig = try Rig(idleWork: idleWork, offscreen: offscreen, size: (1920, 1080))
            rig.tick(30)
            if offscreen { _ = rig.centre() }
            let start = CACurrentMediaTime()
            rig.tick(600, from: 30)
            let wall = CACurrentMediaTime() - start
            _ = rig.compositor.readback()
            let summary = rig.metrics.summary(seconds: 1e9, now: 1e9)
            return (wall / 600 * 1000, summary.gpuP50)
        }
        let always = try run(idleWork: false, offscreen: true)
        let reuse = try run(idleWork: true, offscreen: true)
        let unwatched = try run(idleWork: true, offscreen: false)
        print(String(format: "TIMING 1080p still per tick: every tick drawn cpu %.3f ms gpu p50 %.3f ms | reused cpu %.3f ms gpu p50 %.3f ms | unwatched cpu %.3f ms", always.cpu, always.gpu, reuse.cpu, reuse.gpu, unwatched.cpu))
    }

    @Test func withoutTheEngineFlagEveryTickDraws() throws {
        let rig = try Rig(idleWork: false, offscreen: true)
        rig.tick(5)
        #expect(rig.compositor.reusedCanvases.load(ordering: .relaxed) == 0)
        #expect(rig.compositor.idleTicks.load(ordering: .relaxed) == 0)
    }

    @Test func staticGeneratorsDrawOnceTheClockOncePerSecondTheRestEveryFrame() throws {
        let context = try MetalContext()
        func draws(_ file: Int, ticks: Int) throws -> Int {
            let generator = try #require(GeneratorSource(context: context, file: file, width: Self.width, height: Self.height))
            let rig = try Rig(playback: LayerPlayback(key: MediaKey(folder: 0, file: file), live: generator), idleWork: false, offscreen: true)
            rig.tick(ticks)
            return generator.encodeCount
        }
        #expect(try draws(101, ticks: 20) == 1, "grid: only the creation draw")
        #expect(try draws(107, ticks: 20) == 1)
        #expect(try draws(110, ticks: 20) == 21, "test card: every frame")
        #expect(try draws(111, ticks: 20) == 21)
        #expect(try draws(113, ticks: 20) == 21)
        let clock = try draws(112, ticks: 20)
        #expect(clock >= 2 && clock <= 3, "clock: once per wall-clock second, got \(clock)")
    }

    @Test func aGeneratorOnAnInvisibleLayerIsNotRedrawnUntilItShows() throws {
        let context = try MetalContext()
        let generator = try #require(GeneratorSource(context: context, file: 110, width: Self.width, height: Self.height))
        var rig = try Rig(playback: LayerPlayback(key: MediaKey(folder: 0, file: 110), live: generator), idleWork: false, offscreen: true)
        rig.setIntensity(0)
        rig.tick(10)
        #expect(generator.encodeCount == 1)
        rig.setIntensity(1)
        rig.tick(1, from: 10)
        #expect(generator.encodeCount == 2, "drawn in the tick it becomes visible")
    }

    /// B31: the headless loop of an output coordinator without displays keeps running through a canvas change, at the
    /// new size and rate; a canvas that cannot be made leaves the old one running.
    @MainActor @Test func setCanvasRunsTheCompositorAtTheNewSizeAndRate() async throws {
        let rig = try Rig(idleWork: false, offscreen: false)
        let compositor = rig.compositor
        let coordinator = try OutputCoordinator(compositor: compositor, context: rig.context, fps: 60, displays: [], logger: Logger(label: "canvas-test"))
        coordinator.apply(outputs: [], clockMaster: nil)
        defer { coordinator.stop() }
        func ticksAdvance() async throws {
            let start = compositor.completed.load(ordering: .relaxed)
            for _ in 0..<200 where compositor.completed.load(ordering: .relaxed) < start + 5 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(compositor.completed.load(ordering: .relaxed) >= start + 5, "the render loop runs")
        }
        try await ticksAdvance()

        try coordinator.setCanvas(width: 320, height: 180, fps: 50)
        try await ticksAdvance()
        let canvas = compositor.readback()
        #expect((canvas.width, canvas.height, compositor.fps) == (320, 180, 50))
        #expect(canvas.rgba[(canvas.height / 2 * canvas.width + canvas.width / 2) * 4] > 150, "the layer is drawn on the new canvas")

        // a canvas that cannot be made: refused before anything changes, the loop runs on at the old size and rate
        #expect(throws: RenderError.self) { try coordinator.setCanvas(width: 20_000, height: 180, fps: 60) }
        try await ticksAdvance()
        #expect((compositor.latestCanvas.width, compositor.canvasSizeSnapshot.width, compositor.fps) == (320, 320, 50))
    }

    /// B31: a generator on a layer follows the canvas size; new ones are made at the snapshot size.
    @Test func generatorsFollowTheCanvasSize() throws {
        let context = try MetalContext()
        let generator = try #require(GeneratorSource(context: context, file: 110, width: Self.width, height: Self.height))
        let rig = try Rig(playback: LayerPlayback(key: MediaKey(folder: 0, file: 110), live: generator), idleWork: false, offscreen: false)
        rig.tick(2)
        try rig.compositor.reconfigure(width: 320, height: 240, fps: 25)
        #expect(rig.compositor.canvasSizeSnapshot == (320, 240))
        let canvas = rig.compositor.readback()
        #expect(canvas.width == 320 && canvas.rgba.allSatisfy { $0 == 0 || $0 == 255 }, "new canvases are cleared before the first tick")
        rig.tick(1, from: 2)
        #expect((generator.texture.width, generator.texture.height) == (320, 240))
        // a layer on another canvas: the generator takes that canvas's size
        try rig.compositor.reconfigure(.init(fps: 25, canvases: [.init(id: 1, width: 320, height: 240), .init(id: 2, width: 640, height: 360)]))
        rig.compositor.layerCanvas = [2]
        rig.tick(1, from: 3)
        #expect((generator.texture.width, generator.texture.height) == (640, 360))
    }

    /// Multiple canvases: a layer on canvas 2 is drawn there and not on canvas 1; an output slice takes its picture from
    /// the canvas it names, and a slice on a canvas that does not render stays black instead of failing.
    @Test func aLayerRendersIntoItsCanvasAndSlicesSampleTheirCanvas() throws {
        let rig = try Rig(idleWork: false, offscreen: true)
        try rig.compositor.reconfigure(.init(fps: 60, canvases: [.init(id: 1, width: Self.width, height: Self.height), .init(id: 2, width: 320, height: 240)]))
        #expect(rig.compositor.canvasIDs == [1, 2])
        func centre(_ image: (width: Int, height: Int, rgba: [UInt8])) -> UInt8 { image.rgba[(image.height / 2 * image.width + image.width / 2) * 4] }

        rig.tick(2)
        #expect(centre(rig.compositor.readback(canvas: 1)) > 150, "canvas 1 by default")
        #expect(centre(rig.compositor.readback(canvas: 2)) == 0)

        rig.compositor.layerCanvas = [2]
        rig.tick(2, from: 2)
        #expect(centre(rig.compositor.readback(canvas: 1)) == 0, "absent from canvas 1")
        let second = rig.compositor.readback(canvas: 2)
        #expect((second.width, second.height) == (320, 240) && centre(second) > 150, "present on canvas 2")
        #expect(rig.compositor.readback(canvas: 3).rgba.isEmpty)

        let compiler = try OutputCompiler(device: rig.context.device)
        func show(canvas: Int) throws -> Int {
            var config = OutputConfig(id: 1)
            config.slices[0].canvas = canvas
            rig.compositor.outputSet = OutputSet(plans: [try compiler.compile(config, index: 1, drawable: (Self.width, Self.height))])
            rig.tick(1, from: 10)
            return rig.centre()
        }
        #expect(try show(canvas: 2) > 150, "the slice takes canvas 2")
        #expect(try show(canvas: 1) <= 1, "canvas 1 is black now")
        #expect(try show(canvas: 3) <= 1, "a removed canvas fails safe: black")

        // the layer leaves canvas 2: cleared in all three textures, then no longer cleared, and black whatever is read
        rig.compositor.layerCanvas = [1]
        for i in 0..<6 {
            rig.tick(1, from: 20 + i)
            #expect(centre(rig.compositor.readback(canvas: 2)) == 0, "empty canvas 2 is black (tick \(i))")
        }
        rig.compositor.layerCanvas = [2]
        rig.tick(1, from: 30)
        #expect(centre(rig.compositor.readback(canvas: 2)) > 150, "drawn again when a layer comes back")

        // removing canvas 2 again: the layer is not drawn anywhere, canvas 1 stays black, the slice on 2 is black
        try rig.compositor.reconfigure(.init(fps: 60, canvases: [.init(id: 1, width: Self.width, height: Self.height)]))
        #expect(try show(canvas: 2) <= 1)
        rig.compositor.layerCanvas = [1]
        #expect(try show(canvas: 1) > 150, "back on canvas 1")
    }

    @Test func invisibleLayersStopAskingForFramesAfterTwoSecondsAndResumeWhenVisible() {
        var hold = InvisibilityHold()
        let visible = hold.allowsRequests(visible: true, at: 0)
        let start = hold.allowsRequests(visible: false, at: 1)  // invisible since 1
        let before = hold.allowsRequests(visible: false, at: 2.9)
        let held = hold.allowsRequests(visible: false, at: 3.0)
        let stillHeld = hold.allowsRequests(visible: false, at: 60)
        let resumed = hold.allowsRequests(visible: true, at: 61)
        let again = hold.allowsRequests(visible: false, at: 62)  // a new invisible period starts a new timer
        let heldAgain = hold.allowsRequests(visible: false, at: 64.5)
        #expect(visible && start && before && !held && !stillHeld && resumed && again && !heldAgain)
    }
}
