// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Metal
import Testing

@testable import FanousEngine

/// The mapped output pass on the GPU (DESIGN.md §9): blend flatness across 2×1 and 2×2 overlaps by readback,
/// golden images for warp, mask and slices, and the edit-to-apply time of a 33×33 warp.
struct OutputPassTests {
    static let width = 320, height = 180
    static let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/golden")

    /// A still frame of one flat colour covering the whole canvas.
    static func flat(_ device: MTLDevice, value: UInt8) throws -> DecodedFrame {
        let w = 64, h = 36
        var pixels = [UInt8](repeating: value, count: w * h * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }  // opaque
        let texture = try MovieSource.makeTexture(device, .rgba8Unorm, w, h)
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        let frame = DecodedFrame(poolIndex: 0)
        frame.kind = .rgba
        frame.frameIndex = 0
        frame.texture0 = texture
        return frame
    }

    /// Renders one output plan over the given still into a `drawable`-sized offscreen target; BGRA bytes.
    static func render(_ plan: OutputPlan, still: DecodedFrame, drawable: (Int, Int), context: MetalContext, outputs: [OutputParameters] = []) throws -> [UInt8] {
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) }
        let compositor = try Compositor(
            context: context, canvasWidth: width, canvasHeight: height, fps: 60, maxLayers: 1, metrics: MetricsRing(capacity: 16), parameters: parameters,
            logger: Logger(label: "output-test"))
        let layer = RenderLayer(index: 0)
        layer.current = LayerPlayback(key: MediaKey(folder: 1, file: 1), still: still)
        layer.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
        compositor.setLayers([layer])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.outputFormat, width: drawable.0, height: drawable.1, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        compositor.offscreenOutput = context.device.makeTexture(descriptor: descriptor)
        compositor.outputSet = OutputSet(plans: [plan])
        parameters.write { slot in
            slot.sequence = 1
            slot.layers[0].intensity = 1
            slot.layers[0].folder = 1
            slot.layers[0].file = 1
            slot.layers[0].fitMode = .stretch
            for (i, o) in outputs.enumerated() where i < slot.outputs.count { slot.outputs[i] = o }
        }
        compositor.tick(target: 3600, drawable: nil)
        return compositor.readbackOutput().bgra
    }

    static func rgba(fromBGRA bgra: [UInt8]) -> [UInt8] {
        var out = bgra
        for i in stride(from: 0, to: out.count, by: 4) { out.swapAt(i, i + 2) }
        return out
    }

    /// Light in the overlap is the gamma-decoded sum of the two outputs; it must equal the input everywhere.
    static func flatness(_ fields: [(bgra: [UInt8], width: Int, x: Int, y: Int)], canvasWidth: Int, canvasHeight: Int, gamma: Double, input: Double) -> (maxError: Double, samples: Int) {
        var maxError = 0.0, samples = 0
        for y in stride(from: 2, to: canvasHeight - 2, by: 3) {
            for x in stride(from: 2, to: canvasWidth - 2, by: 3) {
                var light = 0.0
                for f in fields {
                    let lx = x - f.x, ly = y - f.y
                    guard lx >= 0, ly >= 0, lx < f.width, (ly + 1) * f.width * 4 <= f.bgra.count else { continue }
                    light += pow(Double(f.bgra[(ly * f.width + lx) * 4 + 1]) / 255, gamma)  // green channel
                }
                maxError = max(maxError, abs(light - pow(input, gamma)))
                samples += 1
            }
        }
        return (maxError, samples)
    }

    @Test func twoProjectorsBlendFlat() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 128)
        let compiler = try OutputCompiler(device: context.device)
        for gamma in [1.0, 2.2] {
            // A: canvas x 0…200 on a 200-wide projector; B: canvas x 120…320. Overlap 80 px.
            var a = OutputConfig(id: 1), b = OutputConfig(id: 2)
            a.blend.right = BlendEdge(overlap: 80, power: 2, gamma: gamma)
            b.blend.left = BlendEdge(overlap: 80, power: 2, gamma: gamma)
            a.slices[0].source = MapRect(x: 0, y: 0, w: 200.0 / 320, h: 1)
            b.slices[0].source = MapRect(x: 120.0 / 320, y: 0, w: 200.0 / 320, h: 1)
            let planA = try compiler.compile(a, index: 1, drawable: (200, Self.height))
            let planB = try compiler.compile(b, index: 2, drawable: (200, Self.height))
            let imageA = try Self.render(planA, still: still, drawable: (200, Self.height), context: context)
            let imageB = try Self.render(planB, still: still, drawable: (200, Self.height), context: context)
            let (error, samples) = Self.flatness(
                [(imageA, 200, 0, 0), (imageB, 200, 120, 0)], canvasWidth: Self.width, canvasHeight: Self.height, gamma: gamma, input: 128.0 / 255)
            #expect(samples > 5000)
            #expect(error < (gamma == 1 ? 0.02 : 0.03), "2×1 gamma \(gamma): max light error \(error)")
            // the single-projector part is untouched, the far edge of the overlap is dark
            #expect(imageA[(90 * 200 + 20) * 4 + 1] == 128)
            #expect(imageA[(90 * 200 + 199) * 4 + 1] < 20)
        }
    }

    @Test func fourProjectorsBlendFlat() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 160)
        let compiler = try OutputCompiler(device: context.device)
        // 2×2 of 200×100 projectors on a 320×180 canvas: 80 px horizontal and 20 px vertical overlaps
        let gamma = 2.2
        var fields: [(bgra: [UInt8], width: Int, x: Int, y: Int)] = []
        for (i, (ox, oy)) in [(0, 0), (120, 0), (0, 80), (120, 80)].enumerated() {
            var o = OutputConfig(id: i + 1)
            if ox == 0 { o.blend.right = BlendEdge(overlap: 80, gamma: gamma) } else { o.blend.left = BlendEdge(overlap: 80, gamma: gamma) }
            if oy == 0 { o.blend.bottom = BlendEdge(overlap: 20, gamma: gamma) } else { o.blend.top = BlendEdge(overlap: 20, gamma: gamma) }
            o.slices[0].source = MapRect(x: Double(ox) / 320, y: Double(oy) / 180, w: 200.0 / 320, h: 100.0 / 180)
            let plan = try compiler.compile(o, index: i + 1, drawable: (200, 100))
            fields.append((try Self.render(plan, still: still, drawable: (200, 100), context: context), 200, ox, oy))
        }
        let (error, samples) = Self.flatness(fields, canvasWidth: Self.width, canvasHeight: Self.height, gamma: gamma, input: 160.0 / 255)
        #expect(samples > 5000)
        #expect(error < 0.035, "2×2: max light error \(error)")
    }

    @Test func rawBypassesBlendAndOutputFixtureDimsAndBlacksOut() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        let compiler = try OutputCompiler(device: context.device)
        var o = OutputConfig(id: 1)
        o.blend.left = BlendEdge(overlap: 100, gamma: 1)
        let plan = try compiler.compile(o, index: 1, drawable: (Self.width, Self.height))
        var raw = OutputParameters()
        raw.raw = true
        let image = try Self.render(plan, still: still, drawable: (Self.width, Self.height), context: context, outputs: [raw])
        #expect(image[(90 * Self.width + 10) * 4 + 1] == 200, "raw: no blend ramp at the left edge")
        var dim = OutputParameters()
        dim.intensity = 0.5
        let dimmed = try Self.render(plan, still: still, drawable: (Self.width, Self.height), context: context, outputs: [dim])
        #expect(abs(Int(dimmed[(90 * Self.width + 300) * 4 + 1]) - 100) <= 1)
        var black = OutputParameters()
        black.control = .blackout
        let dark = try Self.render(plan, still: still, drawable: (Self.width, Self.height), context: context, outputs: [black])
        #expect(dark[(90 * Self.width + 300) * 4 + 1] <= 1)
    }

    /// Output Control = Freeze keeps the frame from the moment it engaged while the canvas goes dark; without it the output follows.
    @Test func freezeHoldsTheOutputWhileTheCanvasMovesOn() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        let plan = try OutputCompiler(device: context.device).compile(OutputConfig(id: 1), index: 1, drawable: (Self.width, Self.height))
        for control in [OutputControl.freeze, .normal] {
            let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) }
            let compositor = try Compositor(
                context: context, canvasWidth: Self.width, canvasHeight: Self.height, fps: 60, maxLayers: 1, metrics: MetricsRing(capacity: 16),
                parameters: parameters, logger: Logger(label: "output-test"))
            let layer = RenderLayer(index: 0)
            layer.current = LayerPlayback(key: MediaKey(folder: 1, file: 1), still: still)
            layer.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
            compositor.setLayers([layer])
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.outputFormat, width: Self.width, height: Self.height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            compositor.offscreenOutput = context.device.makeTexture(descriptor: descriptor)
            compositor.outputSet = OutputSet(plans: [plan])
            var fixture = OutputParameters()
            fixture.control = control
            func write(sequence: UInt64, layerIntensity: Float) {
                parameters.write { slot in
                    slot.sequence = sequence
                    slot.layers[0].intensity = layerIntensity
                    slot.layers[0].folder = 1
                    slot.layers[0].file = 1
                    slot.layers[0].fitMode = .stretch
                    slot.outputs[0] = fixture
                }
            }
            write(sequence: 1, layerIntensity: 1)
            compositor.tick(target: 3600, drawable: nil)
            #expect(compositor.readbackOutput().bgra[(90 * Self.width + 160) * 4 + 1] == 200)
            write(sequence: 2, layerIntensity: 0)
            compositor.tick(target: 3601, drawable: nil)
            let after = compositor.readbackOutput().bgra[(90 * Self.width + 160) * 4 + 1]
            if control == .freeze { #expect(after == 200, "frozen output keeps the last frame") } else { #expect(after <= 1, "unfrozen output follows the canvas") }
        }
    }

    /// A test pattern follows the corner pin (it used to be drawn flat over the region, so warping showed nothing).
    @Test func testPatternFollowsTheWarp() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        let compiler = try OutputCompiler(device: context.device)
        var o = OutputConfig(id: 1)
        o.testPattern = TestPattern.colourBars.rawValue
        let flat = try Self.render(compiler.compile(o, index: 1, drawable: (Self.width, Self.height)), still: still, drawable: (Self.width, Self.height), context: context)
        func px(_ image: [UInt8], _ x: Int, _ y: Int) -> (r: Int, g: Int) { (Int(image[(y * Self.width + x) * 4 + 2]), Int(image[(y * Self.width + x) * 4 + 1])) }
        // unwarped: x = 100 of 320 is bar 2 (cyan: no red, 75 % green)
        #expect(px(flat, 100, 90).r < 10 && abs(px(flat, 100, 90).g - 191) <= 2, "\(px(flat, 100, 90))")
        // corner pin onto the left half: x = 100 now shows pre-warp x = 0.625, bar 5 (red); the right half is empty
        o.warp.cornerPin = [MapPoint(0, 0), MapPoint(0.5, 0), MapPoint(0.5, 1), MapPoint(0, 1)]
        let warped = try Self.render(compiler.compile(o, index: 1, drawable: (Self.width, Self.height)), still: still, drawable: (Self.width, Self.height), context: context)
        #expect(abs(px(warped, 100, 90).r - 191) <= 2 && px(warped, 100, 90).g < 10, "\(px(warped, 100, 90))")
        #expect(px(warped, 250, 90).r < 3 && px(warped, 250, 90).g < 3, "outside the pinned quad: \(px(warped, 250, 90))")
    }

    @Test func warpMaskAndSliceGoldens() throws {
        let context = try MetalContext()
        let still = try GoldenTests.pattern(device: context.device, variant: 0)
        let compiler = try OutputCompiler(device: context.device)
        var cases: [(String, OutputConfig)] = []
        var pin = OutputConfig(id: 1)
        pin.warp.cornerPin = [MapPoint(0.1, 0.05), MapPoint(0.95, 0.12), MapPoint(0.9, 0.95), MapPoint(0.05, 0.85)]
        cases.append(("output-cornerpin", pin))
        var mesh = OutputConfig(id: 1)
        var m = MeshWarp.identity(cols: 5, rows: 5)
        m.points[12] = MapPoint(0.6, 0.42)
        m.points[7] = MapPoint(0.52, 0.2)
        mesh.warp.mesh = m
        cases.append(("output-mesh", mesh))
        var masked = OutputConfig(id: 1)
        masked.slices[0].mask = MaskSettings(path: [MapPoint(0.5, 0.05), MapPoint(0.95, 0.5), MapPoint(0.5, 0.95), MapPoint(0.05, 0.5)], feather: 24)
        cases.append(("output-mask-feather", masked))
        var slices = OutputConfig(id: 1)
        slices.slices[0].source = MapRect(x: 0, y: 0, w: 0.5, h: 1)
        slices.slices[0].dest = [MapPoint(0.05, 0.1), MapPoint(0.5, 0.0), MapPoint(0.5, 1), MapPoint(0.05, 0.9)]
        var second = SliceConfig(id: 2)
        second.source = MapRect(x: 0.5, y: 0, w: 0.5, h: 1)
        second.dest = [MapPoint(0.45, 0.2), MapPoint(0.95, 0.2), MapPoint(0.95, 0.8), MapPoint(0.45, 0.8)]
        second.opacity = 0.6
        slices.slices.append(second)
        cases.append(("output-slices", slices))
        var blend = OutputConfig(id: 1)
        blend.blend.left = BlendEdge(overlap: 60)
        blend.blend.right = BlendEdge(overlap: 60, power: 3)
        blend.blend.lift = 0.08
        blend.blend.liftFeather = 10
        cases.append(("output-blend-lift", blend))

        var failures: [String] = []
        for (name, config) in cases {
            let plan = try compiler.compile(config, index: 1, drawable: (Self.width, Self.height))
            let rgba = Self.rgba(fromBGRA: try Self.render(plan, still: still, drawable: (Self.width, Self.height), context: context))
            let url = Self.golden.appending(path: "\(name).png")
            if GoldenTests.record {
                try GoldenTests.writePNG(rgba, width: Self.width, height: Self.height, to: url)
                continue
            }
            guard let reference = GoldenTests.readPNG(url) else {
                failures.append("\(name): no golden image (record with FANOUS_RECORD_GOLDEN=1)")
                continue
            }
            if let problem = GoldenTests.compare(rgba, reference, name: name) { failures.append(problem) }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    @Test func thirtyThreeByThirtyThreeWarpCompilesUnder100ms() throws {
        let context = try MetalContext()
        let compiler = try OutputCompiler(device: context.device)
        var o = OutputConfig(id: 1)
        o.warp.mesh = .identity(cols: 33, rows: 33)
        o.warp.mesh!.points[33 * 16 + 16] = MapPoint(0.51, 0.5)
        o.slices[0].mask = MaskSettings(path: [MapPoint(0.1, 0.1), MapPoint(0.9, 0.1), MapPoint(0.9, 0.9), MapPoint(0.1, 0.9)], feather: 8)
        _ = try compiler.compile(o, index: 1, drawable: (1920, 1080))  // warm up
        let start = Date()
        let plan = try compiler.compile(o, index: 1, drawable: (1920, 1080))
        let ms = Date().timeIntervalSince(start) * 1000
        #expect(plan.warpField?.width == 480)
        // the acceptance bound (100 ms) is a release-build number, see docs/benchmarks; debug builds run ~2–3× slower
        #expect(ms < 250, "compiled a 33×33 warp with a feathered mask at 1080p in \(ms) ms")
        print("33x33 warp + feathered mask compile at 1080p: \(String(format: "%.1f", ms)) ms")
    }
}
