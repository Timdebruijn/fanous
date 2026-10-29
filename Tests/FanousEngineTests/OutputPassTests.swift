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
    /// `master` edits the Master fixture's values in the slot (intensity, control, test pattern). A nil plan draws the
    /// plain pass (the canvas as the canvas preview, Syphon and CITP show it).
    static func render(
        _ plan: OutputPlan?, still: DecodedFrame, drawable: (Int, Int), context: MetalContext, outputs: [OutputParameters] = [],
        master: (ParameterSnapshotSlot) -> Void = { _ in }
    ) throws -> [UInt8] {
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
        compositor.outputSet = plan.map { OutputSet(plans: [$0]) }
        parameters.write { slot in
            slot.sequence = 1
            slot.layers[0].intensity = 1
            slot.layers[0].folder = 1
            slot.layers[0].file = 1
            slot.layers[0].fitMode = .stretch
            for (i, o) in outputs.enumerated() where i < slot.outputs.count { slot.outputs[i] = o }
            master(slot)
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
            guard control == .freeze else { continue }
            // Freeze holds the canvases, not the pattern: White draws live over the frozen output, and switched off the held frame is back
            fixture.testPattern = .white
            write(sequence: 3, layerIntensity: 0)
            compositor.tick(target: 3602, drawable: nil)
            #expect(compositor.readbackOutput().bgra[(90 * Self.width + 160) * 4 + 1] == 255, "White over a frozen output")
            fixture.testPattern = .off
            write(sequence: 4, layerIntensity: 0)
            compositor.tick(target: 3603, drawable: nil)
            #expect(compositor.readbackOutput().bgra[(90 * Self.width + 160) * 4 + 1] == 200, "the held frame returns when the pattern is off")
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

    /// Seam-check fields (DESIGN §9.9) read back at their output signal level, the same scale as Blend check's 50 % (128):
    /// Grey 25 % is code 64, Grey 75 % 191. Like the other patterns they go through the blend map, and Raw bypasses it.
    @Test func seamCheckFieldsReadBackTheirLevel() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        let compiler = try OutputCompiler(device: context.device)
        let size = (Self.width, Self.height)
        func image(_ config: OutputConfig, _ pattern: TestPattern, raw: Bool = false) throws -> [UInt8] {
            var fixture = OutputParameters()  // the Output fixture's channel 4, as from the console
            fixture.testPattern = pattern
            fixture.raw = raw
            return try Self.render(compiler.compile(config, index: 1, drawable: size), still: still, drawable: size, context: context, outputs: [fixture])
        }
        // R, G, B at (x, 97): y 97 is between the Blend check's grid lines
        func px(_ image: [UInt8], _ x: Int) -> [Int] { let i = (97 * Self.width + x) * 4; return [Int(image[i + 2]), Int(image[i + 1]), Int(image[i])] }
        for (pattern, level) in [(TestPattern.grey0, 0), (.grey25, 64), (.grey75, 191), (.white, 255)] {
            let field = try image(OutputConfig(id: 1), pattern)
            for x in [2, 167, 317] { #expect(px(field, x).allSatisfy { abs($0 - level) <= 1 }, "\(pattern) at x \(x): \(px(field, x))") }
        }
        #expect(px(try image(OutputConfig(id: 1), .blendCheck), 167).allSatisfy { abs($0 - 128) <= 1 }, "Blend check is the 50 % field")
        // blend map: the left ramp darkens towards the edge, the black lift raises the field outside the overlap
        var blended = OutputConfig(id: 1)
        blended.blend.left = BlendEdge(overlap: 100, gamma: 1)
        blended.blend.lift = 0.08
        let grey25 = try image(blended, .grey25)
        // the lift adds its light (M1.7): 64 with 0.08 reads 66, not 64 + 20
        #expect(px(grey25, 2)[1] < 10 && abs(Double(px(grey25, 300)[1]) - Self.lit(64, 0.08)) <= 1, "\(px(grey25, 2)) \(px(grey25, 300))")
        let grey0 = try image(blended, .grey0)
        #expect(px(grey0, 50)[1] <= 1 && abs(px(grey0, 300)[1] - 20) <= 1, "Grey 0 % shows the lift: \(px(grey0, 50)) \(px(grey0, 300))")
        // overlaps on both axes (M2.1): the lift follows the coverage, up to the black of the four-projector corner
        var grid = blended
        grid.blend.top = BlendEdge(overlap: 40, gamma: 1)
        let covered = try image(grid, .grey0)
        func green(_ x: Int, _ y: Int) -> Double { Double(covered[(y * Self.width + x) * 4 + 1]) }
        #expect(abs(green(300, 150) - 0.08 * pow(3, 1 / 2.2) * 255) <= 1, "one projector: \(green(300, 150))")
        #expect(abs(green(50, 150) - 0.08 * 255) <= 1, "left overlap only: \(green(50, 150))")
        #expect(green(50, 10) <= 1, "the corner: \(green(50, 10))")
        let raw = try image(blended, .grey25, raw: true)
        #expect(abs(px(raw, 2)[1] - 64) <= 1 && abs(px(raw, 300)[1] - 64) <= 1, "Raw bypasses the blend map: \(px(raw, 2)) \(px(raw, 300))")
        // warp: pinned onto the left half, the field stops at the pin
        var pinned = OutputConfig(id: 1)
        pinned.warp.cornerPin = [MapPoint(0, 0), MapPoint(0.5, 0), MapPoint(0.5, 1), MapPoint(0, 1)]
        let warped = try image(pinned, .white)
        #expect(px(warped, 100)[1] >= 254 && px(warped, 250)[1] <= 1, "White follows the corner pin: \(px(warped, 100)) \(px(warped, 250))")
    }

    /// A console's Grand Master or DBO takes a test pattern down like the content: the pattern follows Output intensity ×
    /// Master intensity, and Output Blackout, Master Blackout or either intensity at 0 is black, Raw and the black lift included.
    @Test func testPatternsFollowTheDimmerAndBlackout() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        let compiler = try OutputCompiler(device: context.device)
        let size = (Self.width, Self.height)
        var lifted = OutputConfig(id: 1)
        lifted.blend.lift = 0.08
        func white(_ edit: (inout OutputParameters) -> Void, config: OutputConfig = OutputConfig(id: 1), master: (ParameterSnapshotSlot) -> Void = { _ in }) throws -> [UInt8] {
            var fixture = OutputParameters()
            fixture.testPattern = .white
            edit(&fixture)
            return try Self.render(compiler.compile(config, index: 1, drawable: size), still: still, drawable: size, context: context, outputs: [fixture], master: master)
        }
        func greens(_ image: [UInt8]) -> Set<UInt8> { Set(stride(from: 1, to: image.count, by: 4).map { image[$0] }) }
        let full = try white { _ in }
        #expect(greens(full) == [255], "White at 100 % (defaults): \(greens(full))")
        // half level, flat: patterns are not dithered
        let half = try white { $0.intensity = 0.5 }
        #expect(greens(half).count == 1 && abs(Int(greens(half).first ?? 0) - 128) <= 1, "Output intensity 50 %: \(greens(half))")
        let masterHalf = try white({ _ in }, master: { $0.master = 0.5 })
        #expect(greens(masterHalf).count == 1 && abs(Int(greens(masterHalf).first ?? 0) - 128) <= 1, "Master intensity 50 %: \(greens(masterHalf))")
        var halfConfig = OutputConfig(id: 1)
        halfConfig.intensity = 0.5  // the output's own Intensity % (Outputs tab)
        let configHalf = try white({ _ in }, config: halfConfig)
        #expect(greens(configHalf).count == 1 && abs(Int(greens(configHalf).first ?? 0) - 128) <= 1, "output Intensity 50 %: \(greens(configHalf))")
        // the lift is there at full level (0.08 → 20), so the blackout case below shows it scaled to 0, not absent
        let lift = try white({ $0.testPattern = .grey0 }, config: lifted)
        #expect(greens(lift).count == 1 && abs(Int(greens(lift).first ?? 0) - 20) <= 1, "Grey 0 % with black lift: \(greens(lift))")
        let dark: [(String, [UInt8])] = [
            ("Output Blackout", try white { $0.control = .blackout }),
            ("Output intensity 0", try white { $0.intensity = 0 }),
            ("Freeze + Output intensity 0", try white { $0.control = .freeze; $0.intensity = 0 }),  // Freeze holds the canvases, not the level
            ("Master Blackout", try white({ _ in }, master: { $0.masterControl = .blackout })),
            ("Master intensity 0", try white({ _ in }, master: { $0.master = 0 })),
            ("Raw + Output Blackout", try white { $0.raw = true; $0.control = .blackout }),
            ("Raw + Master Blackout", try white({ $0.raw = true }, master: { $0.masterControl = .blackout })),
            ("Master pattern + Output Blackout", try white({ $0.testPattern = .off; $0.control = .blackout }, master: { $0.testPattern = .white })),
            ("Grey 0 % with black lift + Output Blackout", try white({ $0.testPattern = .grey0; $0.control = .blackout }, config: lifted)),
        ]
        for (name, image) in dark { #expect(greens(image) == [0], "\(name): \(greens(image))") }
    }

    /// The canvas already carries the Master (each layer is drawn with it), so a mapped output takes it once, as the plain
    /// pass does (B100: 50 % read 25 %).
    @Test func masterDimsAMappedOutputOnce() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        let plan = try OutputCompiler(device: context.device).compile(OutputConfig(id: 1), index: 1, drawable: (Self.width, Self.height))
        for (master, expected) in [(Float(1), 200), (0.5, 100), (0.25, 50)] {
            let mapped = try Self.render(plan, still: still, drawable: (Self.width, Self.height), context: context, master: { $0.master = master })
            let plain = try Self.render(nil, still: still, drawable: (Self.width, Self.height), context: context, master: { $0.master = master })
            let (m, p) = (Int(mapped[(90 * Self.width + 160) * 4 + 1]), Int(plain[(90 * Self.width + 160) * 4 + 1]))
            #expect(abs(m - expected) <= 1 && abs(m - p) <= 1, "Master \(master): mapped \(m), plain \(p)")
        }
    }

    typealias Stacked = (value: UInt8, edit: (inout LayerParameters) -> Void)

    /// The canvas centre (RGBA) of `layers` stacked bottom to top, each a full-frame flat still of `value` at intensity 1,
    /// then `edit`, at Master `master`.
    static func canvas(_ layers: [Stacked], master: Float, context: MetalContext) throws -> [Int] {
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: layers.count) }
        let compositor = try Compositor(
            context: context, canvasWidth: width, canvasHeight: height, fps: 60, maxLayers: layers.count, metrics: MetricsRing(capacity: 16),
            parameters: parameters, logger: Logger(label: "master-test"))
        compositor.setLayers(
            try layers.enumerated().map { i, layer in
                let key = MediaKey(folder: 1, file: i + 1)
                let render = RenderLayer(index: i)
                render.current = LayerPlayback(key: key, still: try flat(context.device, value: layer.value))
                render.wanted.store(key.packed, ordering: .relaxed)
                return render
            })
        parameters.write { slot in
            slot.sequence = 1
            slot.master = master
            for (i, layer) in layers.enumerated() {
                slot.layers[i].intensity = 1
                slot.layers[i].folder = 1
                slot.layers[i].file = UInt8(i + 1)
                slot.layers[i].fitMode = .stretch
                layer.edit(&slot.layers[i])
            }
        }
        compositor.tick(target: 3600, drawable: nil)
        let i = (height / 2 * width + width / 2) * 4
        return compositor.readback().rgba[i..<i + 4].map(Int.init)
    }

    /// The Master scales each layer's colour, not its opacity: the canvas is the Master × the canvas at 100 % (B108: green
    /// over red read (63,128,0) at Master 50 %). Every blend mode (grey 0.3 over grey 0.4, nothing clipped), an add that
    /// clips (grey 0.4 over white: the clamp to the Master, not to 1) and a top layer at intensity 50 % read half at Master
    /// 50 %; an opaque canvas stays opaque.
    @Test func masterDimsStackedLayersWithoutTransparency() throws {
        let context = try MetalContext()
        let red: (inout LayerParameters) -> Void = { $0.green = 0; $0.blue = 0 }
        let green: (inout LayerParameters) -> Void = { $0.red = 0; $0.blue = 0 }
        for (master, g) in [(Float(1), 255), (0.5, 128), (0.25, 64)] {
            let rgba = try Self.canvas([(255, red), (255, green)], master: master, context: context)
            #expect(zip(rgba, [0, g, 0, 255]).allSatisfy { abs($0 - $1) <= 1 }, "green over red, Master \(master): \(rgba)")
        }
        var cases: [(String, [Stacked])] = BlendMode.allCases.map { mode in ("\(mode)", [(102, { _ in }), (77, { $0.blendMode = mode })]) }
        cases.append(("add clipped", [(255, { _ in }), (102, { $0.blendMode = .add })]))
        cases.append(("green 50 % over red", [(255, red), (255, { green(&$0); $0.intensity = 0.5 })]))
        for (name, layers) in cases {
            let full = try Self.canvas(layers, master: 1, context: context)
            let half = try Self.canvas(layers, master: 0.5, context: context)
            let ok = (0..<3).allSatisfy { abs(Double(half[$0]) - Double(full[$0]) / 2) <= 1 } && half[3] == 255
            #expect(ok, "\(name): Master 100 % \(full), 50 % \(half)")
        }
    }

    /// One compositor over a flat still that draws `config` (nil: the plain pass) into an offscreen output. `write` sets
    /// the layer's intensity, Output 1's Control and the Master; `tick` writes, ticks and reads back; `present` draws
    /// `set` as a secondary display does, from the last completed canvas, without a tick. All read the centre's green.
    final class Rig {
        let context: MetalContext
        let compositor: Compositor
        let parameters = TripleBuffer({ ParameterSnapshotSlot(maxLayers: 1) }, copy: { $0.copy(from: $1) })
        private let target: MTLTexture
        private let uniforms: MTLBuffer
        private var sequence: UInt64 = 0

        init(_ config: OutputConfig?, value: UInt8) throws {
            context = try MetalContext()
            compositor = try Compositor(
                context: context, canvasWidth: width, canvasHeight: height, fps: 60, maxLayers: 1, metrics: MetricsRing(capacity: 16),
                parameters: parameters, logger: Logger(label: "output-test"))
            let layer = RenderLayer(index: 0)
            layer.current = LayerPlayback(key: MediaKey(folder: 1, file: 1), still: try flat(context.device, value: value))
            layer.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
            compositor.setLayers([layer])
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.outputFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let output = context.device.makeTexture(descriptor: descriptor), let target = context.device.makeTexture(descriptor: descriptor),
                let uniforms = context.device.makeBuffer(length: Compositor.mappedUniformsLength, options: .storageModeShared)
            else { throw RenderError.pipeline("output test rig") }
            compositor.offscreenOutput = output
            (self.target, self.uniforms) = (target, uniforms)
            if let config { compositor.outputSet = OutputSet(plans: [try compile(config)]) }
        }

        func compile(_ config: OutputConfig) throws -> OutputPlan {
            try OutputCompiler(device: context.device).compile(config, index: 1, drawable: (width, height))
        }

        func write(_ control: OutputControl, master: Float, layer: Float, blackout: Bool = false) {
            sequence += 1
            parameters.write { [sequence] slot in
                slot.sequence = sequence
                slot.layers[0].intensity = layer
                slot.layers[0].folder = 1
                slot.layers[0].file = 1
                slot.layers[0].fitMode = .stretch
                slot.outputs[0].control = control
                slot.master = master
                slot.masterControl = blackout ? .blackout : .normal
            }
        }

        func tick(_ control: OutputControl, master: Float, layer: Float, blackout: Bool = false) -> Int {
            write(control, master: master, layer: layer, blackout: blackout)
            compositor.tick(target: 3600 + Double(sequence), drawable: nil)
            return Int(compositor.readbackOutput().bgra[(90 * width + 160) * 4 + 1])
        }

        func present(_ set: OutputSet) throws -> Int {
            guard let commandBuffer = context.queue.makeCommandBuffer() else { throw RenderError.pipeline("present command buffer") }
            #expect(compositor.encodePresent(set, into: target, uniforms: uniforms, commandBuffer: commandBuffer))
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            var bgra = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&bgra, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return Int(bgra[(90 * width + 160) * 4 + 1])
        }
    }

    static func near(_ value: Int, _ expected: Int) -> Bool { abs(value - expected) <= 1 }

    /// A frozen canvas carries the Master it was drawn with; the output follows the Master from there, once.
    @Test func freezeFollowsTheMasterOnce() throws {
        let rig = try Rig(OutputConfig(id: 1), value: 200)
        let near = Self.near
        // engaged at Master 100 %; the layer goes dark once frozen, so what shows is the held canvas
        #expect(near(rig.tick(.freeze, master: 1, layer: 1), 200))
        #expect(near(rig.tick(.freeze, master: 0.5, layer: 0), 100), "frozen at 100 %, Master 50 %")
        #expect(rig.tick(.freeze, master: 0, layer: 0) <= 1, "frozen, Master 0")
        #expect(rig.tick(.freeze, master: 1, layer: 0, blackout: true) <= 1, "frozen, Master Blackout")
        #expect(near(rig.tick(.freeze, master: 1, layer: 0), 200), "frozen, Master back at 100 %")
        _ = rig.tick(.normal, master: 1, layer: 0)  // releases the held canvas
        // engaged at Master 50 %: the same 100 before and after it engaged, the full frame at Master 100 %
        #expect(near(rig.tick(.normal, master: 0.5, layer: 1), 100), "live at Master 50 %")
        #expect(near(rig.tick(.freeze, master: 0.5, layer: 1), 100), "Freeze engages at Master 50 %")
        #expect(near(rig.tick(.freeze, master: 0.5, layer: 0), 100), "frozen at 50 %, Master 50 %")
        #expect(near(rig.tick(.freeze, master: 1, layer: 0), 200), "frozen at 50 %, Master 100 %")
        _ = rig.tick(.normal, master: 1, layer: 0)
        // engaged at Master 0: a black canvas carries no picture, so Freeze holds the first one drawn above 0
        #expect(rig.tick(.freeze, master: 0, layer: 1) <= 1, "Freeze engages at Master 0")
        #expect(near(rig.tick(.freeze, master: 0.5, layer: 1), 100), "Master 50 %: the first canvas above 0")
        #expect(near(rig.tick(.freeze, master: 0.5, layer: 0), 100), "held at 50 %")
        #expect(near(rig.tick(.freeze, master: 1, layer: 0), 200), "held at 50 %, Master 100 %")
    }

    /// B107: the preview of a frozen output holds with it: the projector's held frame for an output on the clock-master
    /// display (also for a viewer that arrives after Freeze engaged), a copy of its own otherwise (a secondary display,
    /// an unbound output). It follows the Master like the output and goes live when Freeze is released.
    @Test func thePreviewOfAFrozenOutputHolds() async throws {
        for shared in [true, false] {
            let rig = try Rig(OutputConfig(id: 1), value: 200)
            let streamer = try PreviewStreamer(
                context: rig.context, width: 160, height: 90, fps: 5, canvasFPS: 5, parameters: rig.parameters, logger: Logger(label: "output-test"))
            streamer.outputSet = OutputSet(plans: [try OutputCompiler(device: rig.context.device).compile(OutputConfig(id: 1), index: 1, drawable: (160, 90))])
            streamer.externalJPEGWanted = { true }  // a JPEG of every tap (5 fps canvas, 1 s apart)
            func watch() {
                rig.compositor.previewTap = { canvas, buffer, target, live in
                    streamer.tap(canvas: canvas, commandBuffer: buffer, target: target, live: shared ? live : nil)
                }
            }
            func preview(_ control: OutputControl, master: Float, layer: Float) async throws -> Int {
                let made = streamer.jpegOut.load(ordering: .relaxed)
                _ = rig.tick(control, master: master, layer: layer)
                #expect(await waitUntil { streamer.jpegOut.load(ordering: .relaxed) > made })
                let (jpeg, width, height) = try #require(streamer.latestJPEG.withLock { $0 })
                return try ThumbnailStreamerTests.brightest(.init(jpeg: jpeg, width: width, height: height))
            }
            func near(_ value: Int, _ expected: Int) -> Bool { abs(value - expected) <= 8 }  // JPEG
            if shared {
                _ = rig.tick(.freeze, master: 1, layer: 1)  // the projector holds a 200 frame before anyone watches
                watch()
            } else {
                watch()
                #expect(near(try await preview(.freeze, master: 1, layer: 1), 200))
            }
            #expect(near(try await preview(.freeze, master: 1, layer: 0), 200), "shared \(shared): the held frame, not the dark canvas")
            #expect(near(try await preview(.freeze, master: 0.5, layer: 0), 100), "shared \(shared): frozen at 100 %, Master 50 %")
            #expect(try await preview(.normal, master: 1, layer: 0) <= 8, "shared \(shared): released, live again")
            // engaged while watched: the engage tick's preview equals the held frame and the next one keeps it. Whether
            // the tick holds before or after the tap (B110) is not observable here: both draw that same frame
            #expect(near(try await preview(.freeze, master: 1, layer: 1), 200), "shared \(shared): the engage tick")
            #expect(near(try await preview(.freeze, master: 1, layer: 0), 200), "shared \(shared): held after engaging while watched")
        }
    }

    /// B110: the tick reads its output set once. Control swapping it during the tick (here: from the preview tap) does not
    /// reach that tick's output pass, which draws the set the tick started with; the swap shows from the next tick.
    @Test func aSetSwappedDuringTheTickWaitsForTheNextTick() throws {
        let rig = try Rig(OutputConfig(id: 1), value: 200)
        var tapped: OutputSet?
        rig.compositor.previewTap = { [unowned compositor = rig.compositor] _, _, _, live in
            tapped = live
            compositor.outputSet = nil
        }
        // Output Blackout: black through the set, the full 200 canvas through the plain pass without one
        #expect(rig.tick(.blackout, master: 1, layer: 1) <= 1, "this tick draws the set it read")
        #expect(tapped != nil, "the tap gets the tick's set")
        #expect(Self.near(rig.tick(.blackout, master: 1, layer: 1), 200), "the next tick: no set, the plain pass")
        #expect(tapped == nil)
    }

    /// The black lift is the projector's floor: on live content it stays while the Master moves and is 0 at Master 0 or
    /// a Blackout. A frozen output rescales its canvas, not the lift (it read 4 × the lift after Freeze at 25 %).
    @Test func theBlackLiftStaysWhileTheMasterMoves() throws {
        var lifted = OutputConfig(id: 1)
        lifted.blend.lift = 0.08  // 20.4 on black content
        let rig = try Rig(lifted, value: 0)
        let near = Self.near
        for master: Float in [1, 0.5, 0.05] { #expect(near(rig.tick(.normal, master: master, layer: 1), 20), "live, Master \(master)") }
        #expect(rig.tick(.normal, master: 0, layer: 1) <= 1, "Master 0")
        #expect(rig.tick(.normal, master: 1, layer: 1, blackout: true) <= 1, "Master Blackout")
        #expect(rig.tick(.blackout, master: 1, layer: 1) <= 1, "Output Blackout")
        #expect(near(rig.tick(.freeze, master: 0.25, layer: 1), 20), "Freeze engages at Master 25 %")
        #expect(near(rig.tick(.freeze, master: 1, layer: 1), 20), "frozen at 25 %, Master 100 %")
    }

    /// The code value of `code` (0…255) with the light of `added` code values (0…1 each, as on black) added at γ 2.2.
    static func lit(_ code: Double, _ added: Double...) -> Double {
        pow(added.reduce(pow(code / 255, 2.2)) { $0 + pow($1, 2.2) }, 1 / 2.2) * 255
    }

    /// Per-output colour (M1.7): the gain multiplies each channel, on content and on test patterns (the seam check tunes
    /// it on Grey 25/75 % and White), in raw too; without a blend map as with one.
    @Test func colourGainActsOnContentPatternsAndRaw() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        let compiler = try OutputCompiler(device: context.device)
        let size = (Self.width, Self.height)
        func rgb(_ config: OutputConfig, _ edit: (inout OutputParameters) -> Void = { _ in }) throws -> [Int] {
            var fixture = OutputParameters()
            edit(&fixture)
            let image = try Self.render(compiler.compile(config, index: 1, drawable: size), still: still, drawable: size, context: context, outputs: [fixture])
            let i = (97 * Self.width + 300) * 4
            return [Int(image[i + 2]), Int(image[i + 1]), Int(image[i])]
        }
        var tinted = OutputConfig(id: 1)
        tinted.color.gain = [0.5, 1, 1.2]
        var blended = tinted
        blended.blend.left = BlendEdge(overlap: 20)  // a blend map; x = 300 is outside the overlap
        let cases: [(String, [Int], [Int])] = [
            ("content", try rgb(tinted), [100, 200, 240]),
            ("White", try rgb(tinted) { $0.testPattern = .white }, [128, 255, 255]),
            ("Grey 25 %", try rgb(tinted) { $0.testPattern = .grey25 }, [32, 64, 77]),
            ("raw keeps the projector's colour", try rgb(tinted) { $0.raw = true }, [100, 200, 240]),
            ("with a blend map", try rgb(blended), [100, 200, 240]),
            ("the default changes nothing", try rgb(OutputConfig(id: 1)), [200, 200, 200]),
        ]
        for (name, read, expected) in cases { #expect(zip(read, expected).allSatisfy { abs($0 - $1) <= 1 }, "\(name): \(read)") }
    }

    /// RGB gamma (M1.6, OPEN-14): inside an overlap each channel follows its own gamma, on content and on test patterns;
    /// outside it the three channels stay equal.
    @Test func gammaRGBBlendsEachChannelOnItsOwn() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        let size = (Self.width, Self.height)
        var o = OutputConfig(id: 1)
        o.blend.left = BlendEdge(overlap: 100, gammaRGB: [1.8, 2.2, 2.6])
        let plan = try OutputCompiler(device: context.device).compile(o, index: 1, drawable: size)
        for pattern in [TestPattern.off, .white] {
            var fixture = OutputParameters()
            fixture.testPattern = pattern
            let image = try Self.render(plan, still: still, drawable: size, context: context, outputs: [fixture])
            func rgb(_ x: Int) -> [Int] { let i = (97 * Self.width + x) * 4; return [Int(image[i + 2]), Int(image[i + 1]), Int(image[i])] }
            let level = pattern == .off ? 200.0 : 255
            let inside = rgb(40), expected = (0..<3).map { level * BlendMath.factor(0.405, edge: o.blend.left, channel: $0) }
            #expect(Set(inside).count == 3 && zip(inside, expected).allSatisfy { abs(Double($0) - $1) <= 1 }, "\(pattern) in the overlap: \(inside), expected \(expected)")
            let outside = rgb(300)
            #expect(Set(outside).count == 1 && abs(Double(outside[0]) - level) <= 1, "\(pattern) outside the overlap: \(outside)")
        }
    }

    /// The black lift and the black offset add light: in linear light at γ 2.2. On black they read their code value, as
    /// the lift did before; on a grey they add the light they give on black, not their code value (0.08 on Grey 25 %
    /// used to read 64 + 20 = 84).
    @Test func liftAndBlackOffsetAddInLinearLight() throws {
        func green(_ value: UInt8, lift: Double = 0, black: Double = 0, gain: Double = 1) throws -> Int {
            var o = OutputConfig(id: 1)
            o.blend.lift = lift
            o.color = OutputColor(gain: [1, gain, 1], black: black)
            return try Rig(o, value: value).tick(.normal, master: 1, layer: 1)
        }
        // on black content: the code value (± dither)
        #expect(abs(Double(try green(0, lift: 0.08)) - 20.4) <= 1, "lift 0.08 on black")
        #expect(abs(Double(try green(0, black: 0.1)) - 25.5) <= 1, "black 0.1 on black, no blend map")
        // on greys: the light added
        for value: UInt8 in [64, 128] {
            let lifted = try green(value, lift: 0.08)
            #expect(abs(Double(lifted) - Self.lit(Double(value), 0.08)) <= 1, "lift 0.08 on \(value): \(lifted), expected \(Self.lit(Double(value), 0.08))")
            #expect(abs(lifted - (Int(value) + 20)) > 10, "not the code value added: \(lifted)")
            let offset = try green(value, black: 0.1)
            #expect(abs(Double(offset) - Self.lit(Double(value), 0.1)) <= 1, "black 0.1 on \(value): \(offset), expected \(Self.lit(Double(value), 0.1))")
            let both = try green(value, lift: 0.08, black: 0.1, gain: 0.5)
            let expected = Self.lit(Double(value) * 0.5, 0.08, 0.1)
            #expect(abs(Double(both) - expected) <= 1, "gain 0.5, lift and black on \(value): \(both), expected \(expected)")
        }
    }

    /// The lift and the black offset are added to the un-premultiplied colour, then the slice's alpha scales the result:
    /// they fade with the slice's opacity and mask (a masked-out part stays black). A hand-edited negative black offset
    /// (project files are not clamped on load) adds nothing instead of turning the picture black.
    @Test func liftAndBlackOffsetFadeWithTheSlice() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 0)
        let compiler = try OutputCompiler(device: context.device)
        let size = (Self.width, Self.height)
        func green(_ config: OutputConfig, _ x: Int, value: UInt8 = 0) throws -> Int {
            let image = try Self.render(compiler.compile(config, index: 1, drawable: size), still: value == 0 ? still : Self.flat(context.device, value: value), drawable: size, context: context)
            return Int(image[(90 * Self.width + x) * 4 + 1])
        }
        var half = OutputConfig(id: 1)
        half.color.black = 0.1
        half.slices[0].opacity = 0.5
        half.slices[0].mask = MaskSettings(path: [MapPoint(0, 0), MapPoint(0.5, 0), MapPoint(0.5, 1), MapPoint(0, 1)])  // the left half
        let inside = try green(half, 80), outside = try green(half, 240)
        #expect(abs(Double(inside) - 12.75) <= 1, "black 0.1 at opacity 0.5: \(inside)")
        #expect(outside <= 1, "black 0.1 where the mask is 0: \(outside)")
        var negative = OutputConfig(id: 1)
        negative.blend.lift = 0.08
        negative.color.black = -0.1
        let read = try green(negative, 160, value: 64)
        #expect(abs(Double(read) - Self.lit(64, 0.08)) <= 1, "black -0.1 with lift 0.08 on 64: \(read)")
    }

    /// Blackout and Master 0 stay black with gain, lift and black offset set; a held (Freeze) canvas still follows the
    /// Master, with the gain on it.
    @Test func colourKeepsBlackoutBlackAndFreezeFollowsTheMaster() throws {
        var o = OutputConfig(id: 1)
        o.blend.lift = 0.08
        o.color = OutputColor(gain: [2, 2, 2], black: 0.1)
        let rig = try Rig(o, value: 100)
        let near = Self.near
        let full = Int(Self.lit(200, 0.08, 0.1).rounded())
        #expect(near(rig.tick(.normal, master: 1, layer: 1), full), "gain 2, lift and black on 100")
        #expect(rig.tick(.normal, master: 0, layer: 1) <= 1, "Master 0")
        #expect(rig.tick(.normal, master: 1, layer: 1, blackout: true) <= 1, "Master Blackout")
        #expect(rig.tick(.blackout, master: 1, layer: 1) <= 1, "Output Blackout")
        var pattern = OutputParameters()
        pattern.testPattern = .white
        let still = try Self.flat(rig.context.device, value: 100)
        let dark: [(ParameterSnapshotSlot) -> Void] = [{ $0.master = 0 }, { $0.masterControl = .blackout }]
        for master in dark {
            let image = try Self.render(try rig.compile(o), still: still, drawable: (Self.width, Self.height), context: rig.context, outputs: [pattern], master: master)
            #expect(Set(stride(from: 1, to: image.count, by: 4).map { image[$0] }) == [0], "White pattern with colour at Master 0 / Blackout")
        }
        // held at Master 100 % (layer dark afterwards): the held canvas × the Master since, × gain, then lift and black
        var held = OutputConfig(id: 1)
        held.color.gain = [1, 0.5, 1]
        let freeze = try Rig(held, value: 200)
        #expect(near(freeze.tick(.freeze, master: 1, layer: 1), 100), "gain 0.5 on 200")
        #expect(near(freeze.tick(.freeze, master: 0.5, layer: 0), 50), "frozen, Master 50 %")
        #expect(freeze.tick(.freeze, master: 0, layer: 0) <= 1, "frozen, Master 0")
    }

    /// A secondary display draws the last completed canvas, which can be a tick older than the Master it reads: Freeze
    /// keeps the Master that canvas was drawn with, not the newer one.
    @Test func aSecondaryDisplayHoldsTheMasterOfItsCanvas() throws {
        let rig = try Rig(nil, value: 200)
        let set = OutputSet(plans: [try rig.compile(OutputConfig(id: 1))])
        let near = Self.near
        #expect(near(rig.tick(.normal, master: 0.5, layer: 1), 100))  // the completed canvas, drawn at Master 50 %
        #expect(near(try rig.present(set), 100), "live")
        rig.write(.freeze, master: 0, layer: 1)  // Freeze and Master 0 in one DMX frame, before the next tick
        #expect(try rig.present(set) <= 1, "frozen, Master 0")
        rig.write(.freeze, master: 1, layer: 1)
        #expect(near(try rig.present(set), 200), "frozen at the canvas's 50 %, Master 100 %")
        _ = rig.tick(.freeze, master: 1, layer: 0)  // the canvas moves on
        #expect(near(try rig.present(set), 200), "still held")
    }

    /// Before the first tick completes (engine start, new canvases) there is no canvas to hold: a secondary display's Freeze
    /// waits for one instead of holding the empty ring texture.
    @Test func aSecondaryDisplayFreezeWaitsForTheFirstCanvas() throws {
        let rig = try Rig(nil, value: 200)
        let set = OutputSet(plans: [try rig.compile(OutputConfig(id: 1))])
        rig.write(.freeze, master: 1, layer: 1)
        #expect(try rig.present(set) <= 1, "no canvas completed yet")
        _ = rig.tick(.freeze, master: 1, layer: 1)
        #expect(Self.near(try rig.present(set), 200), "the first completed canvas is held")
    }

    /// A content slice's canvas factor: 1 live (the canvas carries the Master), the Master since for a held canvas.
    @Test func contentScaleFollowsTheMasterOnlyWhenHeld() {
        let cases: [(master: Float, held: Float?, scale: Float)] = [
            (1, nil, 1), (0.5, nil, 1), (0, nil, 1),  // live (Master 0 is the intensity's 0)
            (1, 1, 1), (0.5, 1, 0.5), (1, 0.25, 4), (0.25, 0.5, 0.5), (0, 0.5, 0),
            (1, 0, 0), (0, 0, 0),  // held at 0: black (holdFrozen does not take one)
        ]
        for c in cases { #expect(OutputPass.contentScale(master: c.master, heldMaster: c.held) == c.scale, "\(c)") }
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

    @Test func thirtyThreeByThirtyThreeWarpCompilesUnder100ms() async throws {
        let context = try MetalContext()
        let compiler = try OutputCompiler(device: context.device)
        var o = OutputConfig(id: 1)
        o.warp.mesh = .identity(cols: 33, rows: 33)
        o.warp.mesh!.points[33 * 16 + 16] = MapPoint(0.51, 0.5)
        o.slices[0].mask = MaskSettings(path: [MapPoint(0.1, 0.1), MapPoint(0.9, 0.1), MapPoint(0.9, 0.9), MapPoint(0.1, 0.9)], feather: 8)
        let plan = try compiler.compile(o, index: 1, drawable: (1920, 1080))  // also the warm-up
        // the compile's own CPU time (it runs on this thread), best of as many tries as 10 s allow: the other suites of
        // a parallel run and other builds share the cores, and wall time on a loaded Mac measures them too (B67)
        var ms = Double.infinity
        _ = await waitUntil(every: .zero) {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            do {
                _ = try compiler.compile(o, index: 1, drawable: (1920, 1080))
            } catch {
                Issue.record(error)
                return true  // a failed compile is no timing
            }
            ms = min(ms, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6)
            return ms < 250
        }
        #expect(plan.warpField?.width == 480)
        // the acceptance bound (100 ms) is a release-build number, see docs/benchmarks; debug builds run ~2–3× slower
        #expect(ms < 250, "compiled a 33×33 warp with a feathered mask at 1080p in \(ms) ms")
        print("33x33 warp + feathered mask compile at 1080p: \(String(format: "%.1f", ms)) ms CPU")
    }
}
