// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Metal
import Testing

@testable import FanousEngine

/// The Master intensity over stacked opaque layers across ticks (B108; `OutputPassTests` covers green over red at 100,
/// 50 and 25 % and every blend mode in one tick): black at Master 0 and Blackout and back, an add that clips before
/// the Master dims it, and a dimmed tick that allocates no more than a full one.
@Suite(.serialized)
struct MasterIntensityTests {
    /// Solid red underneath, solid `top` (green) above with `blend`, both at full intensity, on a 64×36 canvas.
    final class Rig {
        let compositor: Compositor
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 2) }
        let blend: BlendMode
        var target = 3600.0
        var sequence: UInt64 = 0

        init(blend: BlendMode = .normal, top: (UInt8, UInt8, UInt8) = (0, 255, 0)) throws {
            let context = try MetalContext()
            compositor = try Compositor(
                context: context, canvasWidth: 64, canvasHeight: 36, fps: 60, maxLayers: 2, metrics: MetricsRing(capacity: 16),
                parameters: parameters, logger: Logger(label: "master"))
            let red = RenderLayer(index: 0)
            let green = RenderLayer(index: 1)
            red.current = LayerPlayback(key: MediaKey(folder: 1, file: 1), still: try Self.solid(context.device, 255, 0, 0))
            green.current = LayerPlayback(key: MediaKey(folder: 1, file: 2), still: try Self.solid(context.device, top.0, top.1, top.2))
            compositor.setLayers([red, green])
            self.blend = blend
            // the stills are already in place: wanted == loaded, so the hand-off asks the (absent) loader for nothing
            red.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
            green.wanted.store(MediaKey(folder: 1, file: 2).packed, ordering: .relaxed)
        }

        static func solid(_ device: MTLDevice, _ r: UInt8, _ g: UInt8, _ b: UInt8) throws -> DecodedFrame {
            let texture = try MovieSource.makeTexture(device, .rgba8Unorm, 4, 4)
            let pixels = [UInt8]((0..<16).flatMap { _ in [r, g, b, 255] })
            pixels.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16)
            }
            let frame = DecodedFrame(poolIndex: 0)
            frame.kind = .rgba
            frame.frameIndex = 0
            frame.texture0 = texture
            return frame
        }

        func set(master: Float, control: MasterControl = .normal) {
            sequence += 1
            parameters.write { slot in  // a whole slot: the writer's slot is not the last one published
                slot.sequence = sequence
                slot.master = master
                slot.masterControl = control
                for (i, file) in [UInt8(1), 2].enumerated() {
                    slot.layers[i] = LayerParameters()
                    slot.layers[i].intensity = 1
                    slot.layers[i].folder = 1
                    slot.layers[i].file = file
                    slot.layers[i].fitMode = .stretch
                }
                slot.layers[1].blendMode = blend
            }
        }

        func tick() {
            target += 1 / 60
            compositor.tick(target: target, drawable: nil)
        }

        /// The canvas centre after one tick at `master`.
        func pixel(master: Float, control: MasterControl = .normal) -> [Int] {
            set(master: master, control: control)
            tick()
            let (w, h, rgba) = compositor.readback()
            let i = ((h / 2) * w + w / 2) * 4
            return rgba[i..<i + 3].map(Int.init)
        }
    }

    static func near(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 1 } }

    @Test func masterZeroAndBlackoutAreBlackAndComeBack() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let rig = try Rig()
        #expect(rig.pixel(master: 0) == [0, 0, 0], "Master 0")
        #expect(rig.pixel(master: 1, control: .blackout) == [0, 0, 0], "Blackout")
        #expect(rig.pixel(master: 1) == [0, 255, 0], "back from Blackout")
    }

    @Test func theMasterDimsTheBlendedResult() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        // add: red + yellow clips to yellow at full level, then × Master; dimming each layer first gave (191, 128, 0)
        let rig = try Rig(blend: .add, top: (255, 255, 0))
        let got = rig.pixel(master: 0.5)
        #expect(Self.near(got, [128, 128, 0]), "add at Master 50 %: \(got)")
    }

    /// Allocations on this (ticking) thread per tick with two layers, at 100 % and at 50 % (printed); in an optimised
    /// build the Master adds none (it is a uniform of the layer draw). Release only: `swift test -c release
    /// -Xswiftc -enable-testing --filter printDimmedTickMallocs` (through `scripts/test.sh`).
    @Test(.enabled(if: MallocCounter.availableOrRequired, "malloc_logger not exported by libsystem_malloc on this macOS"))
    func printDimmedTickMallocs() throws {
        try #require(MallocCounter.available, "malloc_logger not exported by libsystem_malloc on this macOS")
        let rig = try Rig()
        var counts: [Int] = []
        for master: Float in [1, 0.5] {
            rig.set(master: master)
            var i = 0
            while i < 120 {  // warm-up: the in-flight ring fills, the uniform slots are touched
                rig.tick()
                i += 1
            }
            counts.append(
                MallocCounter.count {
                    var i = 0
                    while i < 600 {
                        rig.tick()
                        i += 1
                    }
                })
            _ = rig.compositor.readback()  // drain the GPU between the windows
        }
        print(String(format: "Master 100 %%: %.2f mallocs per tick, Master 50 %%: %.2f", Double(counts[0]) / 600, Double(counts[1]) / 600))
        #if !DEBUG
            // Metal allocates now and then on either side (±0.02 per tick measured); a render encoder more would be +3
            #expect(abs(counts[1] - counts[0]) < 300, "Master 50 %: \(counts[1]) mallocs in 600 ticks, 100 %: \(counts[0])")
        #endif
    }
}
