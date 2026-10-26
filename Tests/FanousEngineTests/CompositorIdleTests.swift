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
