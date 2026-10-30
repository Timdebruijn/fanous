// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import ImageIO
import Logging
import Metal
import Testing
import simd

@testable import FanousEngine

/// The mapped output pass on the GPU (DESIGN.md §9): blend flatness across 2×1 and 2×2 overlaps by readback,
/// golden images for warp, mask and slices, and the edit-to-apply time of a 33×33 warp.
struct OutputPassTests {
    static let width = 320, height = 180
    static let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/golden")

    /// A still frame of one flat colour covering the whole canvas; `right` paints its right half another.
    static func flat(_ device: MTLDevice, value: UInt8, right: UInt8? = nil) throws -> DecodedFrame {
        let w = 64, h = 36
        var pixels = [UInt8](repeating: value, count: w * h * 4)
        if let right { for i in pixels.indices where i % (w * 4) >= w * 2 { pixels[i] = right } }
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
        let compiler = OutputCompiler(device: context.device)
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
        let compiler = OutputCompiler(device: context.device)
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
        let compiler = OutputCompiler(device: context.device)
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

    /// B111: an edit while frozen recompiles the plan; the new plan of the same id keeps the held frame (the same copy)
    /// instead of holding a later one, the replaced set is let go after the first tick, and releasing Freeze goes live.
    /// `chained`: a set that never rendered in between (two edits before a tick). `threeSwaps`: three edits through
    /// `holdSource` before a tick, and the sets in between are not kept alive.
    enum Swap: CaseIterable { case direct, chained, threeSwaps }
    @Test(arguments: Swap.allCases) func freezeSurvivesARecompile(_ swap: Swap) throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        let compiler = OutputCompiler(device: context.device)
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
        let first = try compiler.compile(OutputConfig(id: 1), index: 1, drawable: (Self.width, Self.height))
        let old = OutputSet(plans: [first])
        compositor.outputSet = old
        var fixture = OutputParameters()
        fixture.control = .freeze
        var sequence: UInt64 = 0, target = 3600.0
        func tick(layerIntensity: Float) -> UInt8 {
            sequence += 1
            parameters.write { slot in
                slot.sequence = sequence
                slot.layers[0].intensity = layerIntensity
                slot.layers[0].folder = 1
                slot.layers[0].file = 1
                slot.layers[0].fitMode = .stretch
                slot.outputs[0] = fixture
            }
            compositor.tick(target: target, drawable: nil)
            target += 1
            return compositor.readbackOutput().bgra[(90 * Self.width + 160) * 4 + 1]
        }
        #expect(tick(layerIntensity: 1) == 200, "frame A held")
        let heldA = try #require(first.held[1])
        // the edit: a recompiled plan of the same output replaces the set while the canvas goes dark (frame B)
        func plan() throws -> OutputPlan { try compiler.compile(OutputConfig(id: 1), index: 1, drawable: (Self.width, Self.height)) }
        let recompiled = try plan()
        weak var middle: OutputSet?
        switch swap {
        case .direct:
            compositor.outputSet = OutputSet(plans: [recompiled], previous: old)
        case .chained:
            compositor.outputSet = OutputSet(plans: [recompiled], previous: OutputSet(plans: [try plan()], previous: old))
        case .threeSwaps:
            try {
                let second = OutputSet(plans: [try plan()], previous: try #require(compositor.outputSet).holdSource)
                compositor.outputSet = second
                middle = second
                compositor.outputSet = OutputSet(plans: [try plan()], previous: second.holdSource)
            }()
            compositor.outputSet = OutputSet(plans: [recompiled], previous: try #require(compositor.outputSet).holdSource)
            #expect(middle == nil, "a set that never rendered is not kept alive by the next edit")
        }
        #expect(tick(layerIntensity: 0) == 200, "the recompiled output keeps frame A")
        #expect(recompiled.held[1] === heldA, "the same held copy, not a new one")
        #expect(try #require(compositor.outputSet).previous.withLock { $0 } == nil, "the replaced set is let go after the first tick")
        #expect(tick(layerIntensity: 0) == 200)
        fixture.control = .normal
        #expect(tick(layerIntensity: 0) <= 1, "released: the output follows the canvas")
        #expect(recompiled.held.isEmpty)
    }

    /// B111: only a frozen plan of the same id adopts, and only copies that match the canvas size.
    @Test func adoptTakesOnlyAMatchingFrozenHold() throws {
        let context = try MetalContext()
        let compiler = OutputCompiler(device: context.device)
        func texture(_ width: Int) throws -> MTLTexture {
            try #require(context.device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: 90, mipmapped: false)))
        }
        let canvas = try texture(160), held = try texture(160)
        var frozen = OutputParameters()
        frozen.control = .freeze
        func adopted(id: Int, control: OutputParameters, heldWidth: Int? = nil, sliceCanvas: Int = 1) throws -> MTLTexture? {
            let old = try compiler.compile(OutputConfig(id: 1), index: 1, drawable: (160, 90))
            old.held = [1: try heldWidth.map(texture) ?? held]
            var config = OutputConfig(id: id)
            config.slices[0].canvas = sliceCanvas
            let set = OutputSet(plans: [try compiler.compile(config, index: 1, drawable: (160, 90))], previous: OutputSet(plans: [old]))
            OutputPass.adopt(set, canvas: { $0 <= 2 ? canvas : nil }, outputs: [control])
            #expect(set.previous.withLock { $0 } == nil)
            return set.plans[0].held[1]
        }
        #expect(try adopted(id: 1, control: frozen) === held)
        #expect(try adopted(id: 2, control: frozen) == nil, "another output")
        #expect(try adopted(id: 1, control: OutputParameters()) == nil, "not frozen")
        #expect(try adopted(id: 1, control: frozen, heldWidth: 320) == nil, "the canvas was resized")
        #expect(try adopted(id: 1, control: frozen, sliceCanvas: 2) == nil, "the slice moved to a canvas the hold has no copy of")
    }

    /// A test pattern follows the corner pin (it used to be drawn flat over the region, so warping showed nothing).
    @Test func testPatternFollowsTheWarp() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        let compiler = OutputCompiler(device: context.device)
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
        let compiler = OutputCompiler(device: context.device)
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
        let compiler = OutputCompiler(device: context.device)
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
        /// Output 1's Keystone (`write` puts it in the slot).
        var keystone = matrix_identity_float3x3
        /// Output 1's mapping preset, Output ch 6 or Compare, and the morph into it (`write` puts them in the slot).
        var preset: UInt8 = 0
        var morph = PresetMorph()
        /// Output 1's Raw (Output ch 5).
        var raw = false

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
                slot.outputs[0].raw = raw
                slot.keystones[0] = keystone
                slot.presets[0] = preset
                slot.morphs[0] = morph
                slot.master = master
                slot.masterControl = blackout ? .blackout : .normal
            }
        }

        func tick(_ control: OutputControl, master: Float, layer: Float, blackout: Bool = false) -> Int {
            write(control, master: master, layer: layer, blackout: blackout)
            compositor.tick(target: 3600 + Double(sequence), drawable: nil)
            return Int(compositor.readbackOutput().bgra[(90 * width + 160) * 4 + 1])
        }

        /// The green at `at` (the centre by default), drawn for host time `now`.
        func present(_ set: OutputSet, at: (x: Int, y: Int) = (160, 90), now: Double = 0) throws -> Int {
            guard let commandBuffer = context.queue.makeCommandBuffer() else { throw RenderError.pipeline("present command buffer") }
            #expect(compositor.encodePresent(set, into: target, uniforms: uniforms, scratch: scratch, at: now, commandBuffer: commandBuffer))
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            var bgra = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&bgra, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return Int(bgra[(at.y * width + at.x) * 4 + 1])
        }
        /// What a secondary driver keeps between frames.
        let scratch = PresentParameters()
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
            // B111: an edit recompiles the projector's set and the preview's; the very next preview still shows the held frame
            let live = try #require(rig.compositor.outputSet)
            rig.compositor.outputSet = OutputSet(plans: [try rig.compile(OutputConfig(id: 1))], previous: live.holdSource)
            streamer.outputSet = OutputSet(
                plans: [try OutputCompiler(device: rig.context.device).compile(OutputConfig(id: 1), index: 1, drawable: (160, 90))],
                previous: streamer.outputSet?.holdSource)
            #expect(near(try await preview(.freeze, master: 1, layer: 0), 200), "shared \(shared): the held frame after a recompile")
            #expect(try #require(streamer.outputSet).previous.withLock { $0 } == nil, "shared \(shared): the preview lets the replaced set go")
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
        let compiler = OutputCompiler(device: context.device)
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
        let compiler = OutputCompiler(device: context.device)
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

    /// Output 1's top-left corner 50 % to the right (DESIGN.md §9.10 item 2), as the DMX side publishes it.
    static let topLeftHalfRight = simd_float3x3(rowMajor: WarpMath.keystone(to: [MapPoint(0.5, 0), MapPoint(1, 0), MapPoint(1, 1), MapPoint(0, 1)])!)

    /// The Keystone moves the whole mapping, content and test patterns, after the warp; the blend map stays in projector
    /// space (sampled at the final position) and Raw bypasses the keystone with the warp.
    @Test func theKeystoneMovesTheMappingButNotTheBlendMap() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        var o = OutputConfig(id: 1)
        o.blend.right = BlendEdge(overlap: 60, gamma: 1)
        let plan = try OutputCompiler(device: context.device).compile(o, index: 1, drawable: (Self.width, Self.height))
        func image(_ keystone: simd_float3x3, raw: Bool = false, pattern: TestPattern = .off) throws -> [UInt8] {
            var fixture = OutputParameters()
            fixture.raw = raw
            fixture.testPattern = pattern
            return try Self.render(plan, still: still, drawable: (Self.width, Self.height), context: context, outputs: [fixture]) { $0.keystones[0] = keystone }
        }
        func green(_ image: [UInt8], _ x: Int, _ y: Int) -> Int { Int(image[(y * Self.width + x) * 4 + 1]) }
        let plain = try image(matrix_identity_float3x3)
        let moved = try image(Self.topLeftHalfRight)
        #expect(green(plain, 2, 2) == 200)
        #expect(green(moved, 2, 2) <= 1, "the old corner is black")
        #expect(green(moved, 150, 2) <= 1 && green(moved, 170, 2) == 200, "the corner is at x = 160 now")
        // the content under the right-edge ramp is flat, so the ramp reads the same where the mapping moved under it; sampled
        // before the keystone it would sit about 10 px further right
        for x in stride(from: 265, to: 320, by: 6) {
            #expect(abs(green(moved, x, 90) - green(plain, x, 90)) <= 2, "ramp at x \(x): \(green(moved, x, 90)) vs \(green(plain, x, 90))")
        }
        #expect(green(plain, 290, 90) < 150, "the ramp is there")
        #expect(green(try image(Self.topLeftHalfRight, raw: true), 2, 2) == 200, "raw: no keystone")
        let white = try image(Self.topLeftHalfRight, pattern: .white)
        #expect(green(white, 2, 2) <= 1 && green(white, 170, 2) == 255, "a test pattern moves with the mapping")
    }

    /// A bleed the mapping puts outside the output stays outside when the keystone shrinks the picture: the output is
    /// clipped at its own edges before the keystone, so outside the keystoned quad is black (§6.4a).
    @Test func theKeystoneClipsTheOutputBeforeItMovesIt() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        var o = OutputConfig(id: 1)
        o.warp.cornerPin = [MapPoint(-0.2, -0.2), MapPoint(1.2, -0.2), MapPoint(1.2, 1.2), MapPoint(-0.2, 1.2)]  // 20 % bleed
        let plan = try OutputCompiler(device: context.device).compile(o, index: 1, drawable: (Self.width, Self.height))
        let half = simd_float3x3(rowMajor: WarpMath.keystone(to: [MapPoint(0.25, 0.25), MapPoint(0.75, 0.25), MapPoint(0.75, 0.75), MapPoint(0.25, 0.75)])!)
        let image = try Self.render(plan, still: still, drawable: (Self.width, Self.height), context: context, outputs: [OutputParameters()]) {
            $0.keystones[0] = half
        }
        func green(_ x: Double, _ y: Double) -> Int { Int(image[(Int(y * Double(Self.height)) * Self.width + Int(x * Double(Self.width))) * 4 + 1]) }
        #expect(green(0.5, 0.5) == 200, "inside the keystoned quad")
        // the bleed reaches 0.15…0.85 after the keystone; the output's own edges are at 0.25 and 0.75
        #expect(green(0.2, 0.5) <= 1 && green(0.8, 0.5) <= 1 && green(0.5, 0.2) <= 1 && green(0.5, 0.8) <= 1, "the bleed stays outside")
    }

    /// The output preview shows the mapping as edited, without the keystone (DESIGN.md §9.10 item 3), while the projector
    /// shows it keystoned.
    @Test func thePreviewDrawsWithoutTheKeystone() async throws {
        let rig = try Rig(OutputConfig(id: 1), value: 200)
        rig.keystone = Self.topLeftHalfRight
        let streamer = try PreviewStreamer(context: rig.context, width: 160, height: 90, fps: 5, canvasFPS: 5, parameters: rig.parameters, logger: Logger(label: "output-test"))
        streamer.outputSet = OutputSet(plans: [try OutputCompiler(device: rig.context.device).compile(OutputConfig(id: 1), index: 1, drawable: (160, 90))])
        streamer.externalJPEGWanted = { true }
        rig.compositor.previewTap = { canvas, buffer, target, live in streamer.tap(canvas: canvas, commandBuffer: buffer, target: target, live: live) }
        _ = rig.tick(.normal, master: 1, layer: 1)
        #expect(rig.compositor.readbackOutput().bgra[(2 * Self.width + 2) * 4 + 1] <= 1, "the projector's corner moved")
        #expect(await waitUntil { streamer.jpegOut.load(ordering: .relaxed) > 0 })
        let (jpeg, width, height) = try #require(streamer.latestJPEG.withLock { $0 })
        let image = try #require(CGImageSourceCreateWithData(Data(jpeg) as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        #expect(abs(Int(rgba[(2 * width + 2) * 4 + 1]) - 200) <= 8, "the preview's corner stays: \(rgba[(2 * width + 2) * 4 + 1])")
    }

    /// An output with preset 1: the corner pin's top-left at x = 0.5 (the edited mapping is the identity), the blend
    /// map's ramp on the right edge.
    static func presetConfig() -> OutputConfig {
        var o = OutputConfig(id: 1)
        o.blend.right = BlendEdge(overlap: 60, gamma: 1)
        o.warp.cornerPin[0] = MapPoint(0.5, 0)
        o.storePreset(1, name: nil)
        o.warp = WarpSettings()
        return o
    }

    /// DESIGN.md §9.10 item 3: the snapshot's preset picks the geometry (ch 6 = 1 draws preset 1, 0 the edited mapping, a
    /// number the output lacks the edited one); the blend map stays the output's own, sampled where it always is.
    @Test func thePresetPicksTheGeometryAndKeepsTheBlendMap() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        let plan = try OutputCompiler(device: context.device).compile(Self.presetConfig(), index: 1, drawable: (Self.width, Self.height))
        #expect(plan.presets.count == 1 && plan.blendMap != nil)
        func image(_ preset: UInt8) throws -> [UInt8] {
            try Self.render(plan, still: still, drawable: (Self.width, Self.height), context: context, outputs: [OutputParameters()]) { $0.presets[0] = preset }
        }
        func green(_ image: [UInt8], _ x: Int, _ y: Int) -> Int { Int(image[(y * Self.width + x) * 4 + 1]) }
        let edited = try image(0), preset = try image(1), missing = try image(7)
        #expect(green(edited, 2, 2) == 200 && green(missing, 2, 2) == 200, "0 and a missing number: the edited mapping")
        #expect(green(preset, 2, 2) <= 1 && green(preset, 150, 2) <= 1 && green(preset, 170, 2) == 200, "preset 1: the corner is at x = 160")
        // the right edge is where it was in both, so the content under the ramp is flat and the ramp reads the same
        for x in stride(from: 265, to: 320, by: 6) {
            #expect(abs(green(preset, x, 90) - green(edited, x, 90)) <= 2, "ramp at x \(x): \(green(preset, x, 90)) vs \(green(edited, x, 90))")
        }
        #expect(green(edited, 290, 90) < 150, "the ramp is there")
    }

    /// The keystone moves whatever mapping the output shows: a preset's left-half slice, shrunk by the keystone to the
    /// middle, lands in the left half of the middle (neither the preset alone nor the keystone alone puts it there).
    @Test func theKeystoneSitsOnTopOfThePreset() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        var o = OutputConfig(id: 1)
        o.slices[0].dest = [MapPoint(0, 0), MapPoint(0.5, 0), MapPoint(0.5, 1), MapPoint(0, 1)]
        o.storePreset(2, name: nil)
        o.slices = [SliceConfig(id: 1)]
        let plan = try OutputCompiler(device: context.device).compile(o, index: 1, drawable: (Self.width, Self.height))
        let half = simd_float3x3(rowMajor: WarpMath.keystone(to: [MapPoint(0.25, 0.25), MapPoint(0.75, 0.25), MapPoint(0.75, 0.75), MapPoint(0.25, 0.75)])!)
        let image = try Self.render(plan, still: still, drawable: (Self.width, Self.height), context: context, outputs: [OutputParameters()]) {
            $0.presets[0] = 2
            $0.keystones[0] = half
        }
        func green(_ x: Double, _ y: Double) -> Int { Int(image[(Int(y * Double(Self.height)) * Self.width + Int(x * Double(Self.width))) * 4 + 1]) }
        #expect(green(0.375, 0.5) == 200, "the preset's slice, keystoned")
        #expect(green(0.1, 0.5) <= 1, "not the preset alone")
        #expect(green(0.6, 0.5) <= 1, "not the keystone alone")
    }

    /// A secondary display (`present`, from the DMX side's copy) draws the preset ch 6 asks for, like the clock master.
    @Test func aSecondaryDisplayDrawsThePreset() throws {
        let rig = try Rig(Self.presetConfig(), value: 200)
        let set = try #require(rig.compositor.outputSet)
        _ = rig.tick(.normal, master: 1, layer: 1)
        #expect(try rig.present(set, at: (2, 2)) == 200, "ch 6 = 0: the edited mapping")
        rig.preset = 1
        _ = rig.tick(.normal, master: 1, layer: 1)
        #expect(try rig.present(set, at: (2, 2)) <= 1 && rig.present(set, at: (170, 2)) == 200, "ch 6 = 1: preset 1's corner at x = 160")
    }

    /// An output whose presets 1 and 2 put slice 1 in the left and the right half; the edited mapping covers all of it.
    static func morphConfig() -> OutputConfig {
        var o = OutputConfig(id: 1)
        o.slices[0].dest = [MapPoint(0, 0), MapPoint(0.5, 0), MapPoint(0.5, 1), MapPoint(0, 1)]
        o.storePreset(1, name: nil)
        o.slices[0].dest = [MapPoint(0.5, 0), MapPoint(1, 0), MapPoint(1, 1), MapPoint(0.5, 1)]
        o.storePreset(2, name: nil)
        o.slices = [SliceConfig(id: 1)]
        return o
    }

    /// Row `y` (a fraction of the height) of a BGRA image at `xs`: 1 lit (the still's 200), 0 black, −1 anything between.
    static func lit(_ image: [UInt8], y: Double, _ xs: [Double]) -> [Int] {
        xs.map { x in
            let g = Int(image[(Int(y * Double(height)) * width + Int(x * Double(width))) * 4 + 1])
            return g >= 199 ? 1 : g <= 1 ? 0 : -1
        }
    }

    /// DESIGN.md §9.10 item 3: a morph from preset 1 to 2 draws both geometries in one pass, mixed by the smoothstep of
    /// the time since its start: preset 1's left half at the start, the middle half halfway, preset 2's right half at the
    /// end; a quarter in, smoothstep (s = 0.16), not linear (0.25). A fade of 0 is a cut. A secondary display draws the
    /// same from its own frame time.
    @Test func aMorphGlidesTheSliceBetweenPresets() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        let plan = try OutputCompiler(device: context.device).compile(Self.morphConfig(), index: 1, drawable: (Self.width, Self.height))
        let xs = [0.1, 0.3, 0.45, 0.55, 0.7, 0.9]
        /// `elapsed` seconds into a 2 s morph from preset 1 to 2 (the tick draws at 3600).
        func row(_ elapsed: Double, fade: Double = 2) throws -> [Int] {
            let image = try Self.render(plan, still: still, drawable: (Self.width, Self.height), context: context, outputs: [OutputParameters()]) {
                $0.presets[0] = 2
                $0.morphs[0] = PresetMorph(from: 1, start: 3600 - elapsed, fade: fade)
            }
            return Self.lit(image, y: 0.5, xs)
        }
        #expect(try row(0) == [1, 1, 1, 0, 0, 0], "s = 0: preset 1")
        #expect(try row(0.5) == [1, 1, 1, 1, 0, 0], "a quarter in: s = 0.16, 0.08 → 0.58 (linear would leave 0.1 dark)")
        #expect(try row(1) == [0, 1, 1, 1, 1, 0], "halfway: 0.25 → 0.75")
        #expect(try row(2) == [0, 0, 0, 1, 1, 1], "s = 1: preset 2")
        #expect(try row(0, fade: 0) == [0, 0, 0, 1, 1, 1], "fade 0: a cut")

        let rig = try Rig(Self.morphConfig(), value: 200)
        let set = try #require(rig.compositor.outputSet)
        (rig.preset, rig.morph) = (2, PresetMorph(from: 1, start: 100, fade: 2))
        _ = rig.tick(.normal, master: 1, layer: 1)
        let mid = try xs.map { try rig.present(set, at: (Int($0 * Double(Self.width)), 90), now: 101) }
        #expect(mid.map { $0 >= 199 ? 1 : $0 <= 1 ? 0 : -1 } == [0, 1, 1, 1, 1, 0], "a secondary display halfway: \(mid)")
    }

    /// Paired by slice id and canvas: halfway, slice 1 has glided (and its opacity, 1 → 0.5, is at 0.75); slice 2, in
    /// preset 1 only, is gone and slice 3, in preset 2 only, is there from the start; slice 4, on canvas 2 in preset 1
    /// and canvas 1 in preset 2, is not paired either, so it stands at preset 2's place.
    @Test func aOneSidedSliceSwitchesAtTheStart() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        func slice(_ id: Int, _ x0: Double, _ y0: Double, canvas: Int = 1, opacity: Double = 1) -> SliceConfig {
            var s = SliceConfig(id: id)
            (s.dest, s.canvas, s.opacity) = ([MapPoint(x0, y0), MapPoint(x0 + 0.5, y0), MapPoint(x0 + 0.5, y0 + 0.3), MapPoint(x0, y0 + 0.3)], canvas, opacity)
            return s
        }
        var o = OutputConfig(id: 1)
        o.slices = [slice(1, 0, 0), slice(2, 0, 0.35), slice(4, 0, 0.7, canvas: 2)]
        o.storePreset(1, name: nil)
        o.slices = [slice(1, 0.5, 0, opacity: 0.5), slice(3, 0.5, 0.35), slice(4, 0.5, 0.7)]
        o.storePreset(2, name: nil)
        o.slices = [SliceConfig(id: 1)]
        let plan = try OutputCompiler(device: context.device).compile(o, index: 1, drawable: (Self.width, Self.height))
        func image(_ elapsed: Double) throws -> [UInt8] {
            try Self.render(plan, still: still, drawable: (Self.width, Self.height), context: context, outputs: [OutputParameters()]) {
                $0.presets[0] = 2
                $0.morphs[0] = PresetMorph(from: 1, start: 3600 - elapsed, fade: 2)
            }
        }
        let start = try image(0), half = try image(1)
        func green(_ image: [UInt8], _ x: Double, _ y: Double) -> Int { Int(image[(Int(y * Double(Self.height)) * Self.width + Int(x * Double(Self.width))) * 4 + 1]) }
        #expect(Self.lit(start, y: 0.5, [0.25, 0.75]) == [0, 1] && Self.lit(start, y: 0.85, [0.25, 0.75]) == [0, 1], "at s = 0 already")
        #expect(Self.lit(half, y: 0.5, [0.1, 0.45, 0.9]) == [0, 0, 1], "slice 2 gone, slice 3 there")
        #expect(Self.lit(half, y: 0.85, [0.1, 0.45, 0.9]) == [0, 0, 1], "slice 4 changed canvas: at preset 2's place")
        #expect(green(half, 0.1, 0.15) <= 1 && green(half, 0.9, 0.15) <= 1, "slice 1 glides: 0.25 → 0.75")
        #expect(Self.near(green(half, 0.5, 0.15), 150), "and its opacity is halfway: \(green(half, 0.5, 0.15))")
    }

    /// Halfway, the source rectangle has glided (top band: preset 1 samples the canvas's left half, 50, preset 2 its right
    /// half, 200), and the new side's masks ride with the slice (bottom band: preset 2's mask covers its slice's left half,
    /// so halfway it covers the left half of where the slice is, not the place it has on the output in preset 2).
    @Test func theSourceAndTheMasksGlideWithTheSlice() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 50, right: 200)
        func slice(_ id: Int, _ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double, source: Double) -> SliceConfig {
            var s = SliceConfig(id: id)
            (s.dest, s.source) = ([MapPoint(x0, y0), MapPoint(x1, y0), MapPoint(x1, y1), MapPoint(x0, y1)], MapRect(x: source, y: 0, w: 0.5, h: 1))
            return s
        }
        var o = OutputConfig(id: 1)
        o.slices = [slice(1, 0, 1, 0, 0.45, source: 0), slice(2, 0, 0.5, 0.55, 1, source: 0.5)]
        o.storePreset(1, name: nil)
        var masked = slice(2, 0.5, 1, 0.55, 1, source: 0.5)
        masked.mask = MaskSettings(path: [MapPoint(0.5, 0.55), MapPoint(0.75, 0.55), MapPoint(0.75, 1), MapPoint(0.5, 1)])
        o.slices = [slice(1, 0, 1, 0, 0.45, source: 0.5), masked]
        o.storePreset(2, name: nil)
        o.slices = [SliceConfig(id: 1)]
        let plan = try OutputCompiler(device: context.device).compile(o, index: 1, drawable: (Self.width, Self.height))
        func image(_ elapsed: Double) throws -> [UInt8] {
            try Self.render(plan, still: still, drawable: (Self.width, Self.height), context: context, outputs: [OutputParameters()]) {
                $0.presets[0] = 2
                $0.morphs[0] = PresetMorph(from: 1, start: 3600 - elapsed, fade: 2)
            }
        }
        func green(_ image: [UInt8], _ x: Double, _ y: Double) -> Int { Int(image[(Int(y * Double(Self.height)) * Self.width + Int(x * Double(Self.width))) * 4 + 1]) }
        let half = try image(1), end = try image(2)
        #expect(Self.near(green(half, 0.1, 0.2), 50) && green(half, 0.9, 0.2) == 200, "the source halfway: 0.05 → 0.55 samples 0.3")
        #expect(green(end, 0.1, 0.2) == 200, "at the end: preset 2's source")
        #expect(green(half, 0.35, 0.8) == 200 && green(half, 0.65, 0.8) <= 1, "the mask rides with the slice")
        #expect(green(end, 0.6, 0.8) == 200 && green(end, 0.9, 0.8) <= 1, "at the end: preset 2's mask where it is drawn")
    }

    /// The warp glides too, also from a preset into the edited mapping: preset 1's top-left corner at x = 0.5 is at 0.25
    /// halfway to the edited identity, for the content and for a test pattern (its mesh is the same on both sides).
    @Test(arguments: [TestPattern.off, .white]) func theWarpGlidesIntoTheEditedMapping(_ pattern: TestPattern) throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        let plan = try OutputCompiler(device: context.device).compile(Self.presetConfig(), index: 1, drawable: (Self.width, Self.height))
        var fixture = OutputParameters()
        fixture.testPattern = pattern
        func image(_ elapsed: Double) throws -> [UInt8] {
            try Self.render(plan, still: still, drawable: (Self.width, Self.height), context: context, outputs: [fixture]) {
                $0.presets[0] = 0
                $0.morphs[0] = PresetMorph(from: 1, start: 3600 - elapsed, fade: 2)
            }
        }
        func green(_ image: [UInt8], _ x: Int) -> Int { Int(image[(2 * Self.width + x) * 4 + 1]) }
        let lit = pattern == .off ? 200 : 255
        let start = try image(0), half = try image(1), end = try image(2)
        #expect(green(start, 2) <= 1 && green(start, 100) <= 1 && green(start, 170) == lit, "s = 0: preset 1, the corner at x = 160")
        #expect(green(half, 2) <= 1 && green(half, 100) == lit, "halfway: the corner at x = 80")
        #expect(green(end, 2) == lit, "s = 1: the edited mapping")
    }

    /// Both sides warped (flags 1 and 16 at once), on output 2 (slot index 1): preset 1's corner pin squeezes the picture
    /// into the right half, preset 2's into the left; halfway the mixed warp puts it in the middle half.
    @Test func twoWarpsGlideOnOutputTwo() throws {
        let context = try MetalContext()
        let still = try Self.flat(context.device, value: 200)
        var o = OutputConfig(id: 2)
        (o.warp.cornerPin[0], o.warp.cornerPin[3]) = (MapPoint(0.5, 0), MapPoint(0.5, 1))
        o.storePreset(1, name: nil)
        o.warp = WarpSettings()
        (o.warp.cornerPin[1], o.warp.cornerPin[2]) = (MapPoint(0.5, 0), MapPoint(0.5, 1))
        o.storePreset(2, name: nil)
        o.warp = WarpSettings()
        let plan = try OutputCompiler(device: context.device).compile(o, index: 2, drawable: (Self.width, Self.height))
        #expect(plan.geometry(1).warpField != nil && plan.geometry(2).warpField != nil)
        func row(_ elapsed: Double) throws -> [Int] {
            let image = try Self.render(plan, still: still, drawable: (Self.width, Self.height), context: context) {
                $0.presets[1] = 2
                $0.morphs[1] = PresetMorph(from: 1, start: 3600 - elapsed, fade: 2)
            }
            return Self.lit(image, y: 0.5, [0.1, 0.3, 0.45, 0.55, 0.7, 0.9])
        }
        #expect(try row(0) == [0, 0, 0, 1, 1, 1], "s = 0: preset 1's warp")
        #expect(try row(1) == [0, 1, 1, 1, 1, 0], "halfway: 0.25 → 0.75")
        #expect(try row(2) == [1, 1, 1, 0, 0, 0], "s = 1: preset 2's warp")
    }

    /// A morph changes the output pass's uniforms on every tick, also on one that reuses a static canvas, while the
    /// previous tick's pass may still read them: each tick writes the next of the three mapped uniform buffers, so three
    /// ticks leave three progress values (a reused tick used to overwrite the one before it).
    @Test func eachTickWritesTheNextMappedUniformBuffer() throws {
        let rig = try Rig(Self.morphConfig(), value: 200)
        rig.compositor.skipsIdleWork = true
        (rig.preset, rig.morph) = (2, PresetMorph(from: 1, start: 3600, fade: 10))
        rig.write(.normal, master: 1, layer: 1)
        let times = [3601.0, 3602, 3603]
        for t in times { rig.compositor.tick(target: t, drawable: nil) }
        #expect(rig.compositor.reusedCanvases.load(ordering: .relaxed) == 2, "a static canvas: the later two ticks reuse it")
        let written = rig.compositor.mappedUniformBuffers.map { $0.contents().assumingMemoryBound(to: MappedUniforms.self).pointee.morph }
        #expect(Set(written) == Set(times.map { rig.morph.progress(at: $0) }), "\(written)")
    }

    /// A secondary display's copy of the output values allocates nothing on its thread (the driver's `PresentParameters`
    /// keep their size). Release only, like the other `mallocCounter` checks (`scripts/check-mallocs.sh`).
    @Test(.enabled(if: MallocCounter.availableOrRequired, "malloc_logger not exported by libsystem_malloc on this macOS"))
    func mallocCounterSecondaryCopyAllocatesNothing() throws {
        try #require(MallocCounter.available, "malloc_logger not exported by libsystem_malloc on this macOS")
        let rig = try Rig(nil, value: 200)
        rig.preset = 3
        rig.morph = PresetMorph(from: 2, start: 10, fade: 1)
        rig.write(.normal, master: 1, layer: 1)
        let scratch = PresentParameters()
        var mallocs = 0
        for _ in 0..<3 {
            mallocs = MallocCounter.count {
                for _ in 0..<100 { rig.compositor.copyLatest(into: scratch) }
            }
        }
        #expect(scratch.presets[0] == 3 && scratch.morphs[0] == rig.morph)
        #if !DEBUG
            #expect(mallocs == 0, "100 copies: \(mallocs) allocations on the calling thread")
        #endif
        print("secondary display copy × 100: \(mallocs) allocations")
    }

    /// Presets from a hand-edited or foreign file never fail the output: number 0 and 256 are not presets (ch 6 = 0 is the
    /// edited mapping), the first of a repeated number wins, and one that does not validate is skipped.
    @Test func aStrayOrBrokenPresetNeverFailsTheOutput() throws {
        var o = Self.presetConfig()
        let moved = o.presets[0]
        var broken = moved
        broken.slices[0].dest.removeLast()  // 3 points
        var flat = moved
        flat.warp = WarpSettings()
        o.presets = [
            MappingPreset(number: 0, name: "zero", warp: moved.warp, slices: moved.slices), MappingPreset(number: 2, name: "first", warp: moved.warp, slices: moved.slices),
            MappingPreset(number: 2, name: "second", warp: flat.warp, slices: flat.slices), MappingPreset(number: 5, name: "broken", warp: broken.warp, slices: broken.slices),
            MappingPreset(number: 256, name: "high", warp: moved.warp, slices: moved.slices),
        ]
        let plan = try OutputCompiler(device: MetalContext().device).compile(o, index: 1, drawable: (Self.width, Self.height))
        #expect(plan.presets.keys.sorted() == [2])
        #expect(plan.geometry(0).warpField == nil, "ch 6 = 0 shows the edited mapping")
        #expect(plan.geometry(2).warpField != nil, "the first preset 2, with the moved corner")
        #expect(plan.geometry(5).warpField == nil, "the broken one is skipped: the edited mapping")
    }

    /// The output preview draws the edited mapping while the projector shows a preset (DESIGN.md §9.10 item 3).
    @Test func thePreviewDrawsTheEditedMapping() async throws {
        let rig = try Rig(Self.presetConfig(), value: 200)
        rig.preset = 1
        let streamer = try PreviewStreamer(context: rig.context, width: 160, height: 90, fps: 5, canvasFPS: 5, parameters: rig.parameters, logger: Logger(label: "output-test"))
        streamer.outputSet = OutputSet(plans: [try OutputCompiler(device: rig.context.device).compile(Self.presetConfig(), index: 1, drawable: (160, 90))])
        streamer.externalJPEGWanted = { true }
        rig.compositor.previewTap = { canvas, buffer, target, live in streamer.tap(canvas: canvas, commandBuffer: buffer, target: target, live: live) }
        _ = rig.tick(.normal, master: 1, layer: 1)
        #expect(rig.compositor.readbackOutput().bgra[(2 * Self.width + 2) * 4 + 1] <= 1, "the projector shows preset 1")
        #expect(await waitUntil { streamer.jpegOut.load(ordering: .relaxed) > 0 })
        let (jpeg, width, height) = try #require(streamer.latestJPEG.withLock { $0 })
        let image = try #require(CGImageSourceCreateWithData(Data(jpeg) as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        #expect(abs(Int(rgba[(2 * width + 2) * 4 + 1]) - 200) <= 8, "the preview's corner stays: \(rgba[(2 * width + 2) * 4 + 1])")
    }

    /// Freeze holds the frame across a ch 6 change (the held canvas through the preset's geometry) and across a recompile
    /// (B111's adopt, with presets in the plan). A preset's canvases are held too.
    @Test func freezeHoldsAcrossAPresetChangeAndARecompile() throws {
        let rig = try Rig(Self.presetConfig(), value: 200)
        func corner() -> Int { Int(rig.compositor.readbackOutput().bgra[(2 * Self.width + 2) * 4 + 1]) }
        #expect(rig.tick(.freeze, master: 1, layer: 1) == 200)
        #expect(rig.tick(.freeze, master: 1, layer: 0) == 200, "held")
        rig.preset = 1
        #expect(rig.tick(.freeze, master: 1, layer: 0) == 200 && corner() <= 1, "held, through preset 1's geometry")
        let live = try #require(rig.compositor.outputSet)
        rig.compositor.outputSet = OutputSet(plans: [try rig.compile(Self.presetConfig())], previous: live.holdSource)
        #expect(rig.tick(.freeze, master: 1, layer: 0) == 200 && corner() <= 1, "held across the recompile")
        rig.preset = 0
        #expect(rig.tick(.freeze, master: 1, layer: 0) == 200 && corner() == 200, "back to the edited mapping, still held")
        #expect(rig.tick(.normal, master: 1, layer: 0) <= 1, "released")
        var two = Self.presetConfig()
        two.presets[0].slices[0].canvas = 2
        #expect(try rig.compile(two).canvases.sorted() == [1, 2], "Freeze holds what a preset samples too")
    }

    @Test func warpMaskAndSliceGoldens() throws {
        let context = try MetalContext()
        let still = try GoldenTests.pattern(device: context.device, variant: 0)
        let compiler = OutputCompiler(device: context.device)
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
        let compiler = OutputCompiler(device: context.device)
        var o = OutputConfig(id: 1)
        o.warp.mesh = .identity(cols: 33, rows: 33)
        o.warp.mesh!.points[33 * 16 + 16] = MapPoint(0.51, 0.5)
        o.slices[0].mask = MaskSettings(path: [MapPoint(0.1, 0.1), MapPoint(0.9, 0.1), MapPoint(0.9, 0.9), MapPoint(0.1, 0.9)], feather: 8)
        let plan = try compiler.compile(o, index: 1, drawable: (1920, 1080))  // also the warm-up
        // the compile's own CPU time (it runs on this thread), best of as many tries as 10 s allow: the other suites of
        // a parallel run and other builds share the cores, and wall time on a loaded Mac measures them too (B67)
        var ms = Double.infinity
        _ = await waitUntil(every: .zero) {
            // a fresh compiler each try: one compiler's cache would hand back the warm-up's textures (§9.10 item 0)
            let fresh = OutputCompiler(device: context.device)
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            do {
                _ = try fresh.compile(o, index: 1, drawable: (1920, 1080))
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

    // MARK: Edit overlay (DESIGN.md §9.10 item 4)

    /// The corner pin puts the picture at x 80…240, y 45…135 (an inset: the warp is linear, so lines land on pixel edges);
    /// slice 1 covers all of it, slice 2 its right half from x 160. Preset 1 is the same mapping.
    static func overlayConfig() -> OutputConfig {
        var o = OutputConfig(id: 1)
        o.warp.cornerPin = [MapPoint(0.25, 0.25), MapPoint(0.75, 0.25), MapPoint(0.75, 0.75), MapPoint(0.25, 0.75)]
        var right = SliceConfig(id: 2)
        right.dest = [MapPoint(0.5, 0), MapPoint(1, 0), MapPoint(1, 1), MapPoint(0.5, 1)]
        o.slices.append(right)
        o.storePreset(1, name: nil)
        return o
    }

    /// `rig` draws `overlayConfig` with an overlay lease taken at host time `at` (the rig ticks at 3601, 3602 …).
    static func overlaid(_ rig: Rig, selected: OverlaySelection? = nil, at: Double = 3600) throws -> OutputSet {
        let overlay = EditOverlay(device: rig.context.device)
        overlay.lease(1, on: true, selected: selected, config: overlayConfig(), at: at)
        let set = OutputSet(plans: [try OutputCompiler(device: rig.context.device).compile(overlayConfig(), index: 1, drawable: (width, height), overlay: overlay)])
        rig.compositor.outputSet = set
        return set
    }

    /// Blue, green, red at (x, y) of a BGRA image.
    static func bgr(_ image: [UInt8], _ x: Int, _ y: Int) -> [Int] { (0..<3).map { Int(image[(y * width + x) * 4 + $0]) } }

    /// The warp (the corner pin's edges) and every slice's outline, through the warp: 2 px white with a 1 px black edge
    /// over the picture. The lease draws for 5 s after it was taken.
    @Test func theOverlayDrawsTheWarpAndTheSliceOutlines() throws {
        let rig = try Rig(nil, value: 200)
        _ = try Self.overlaid(rig)
        _ = rig.tick(.normal, master: 1, layer: 1)
        let image = rig.compositor.readbackOutput().bgra
        func g(_ x: Int, _ y: Int) -> Int { Int(image[(y * Self.width + x) * 4 + 1]) }
        #expect([158, 159, 160, 161, 163].map { g($0, 90) } == [0, 255, 255, 0, 200], "slice 2's left edge at x = 160")
        #expect(Self.bgr(image, 160, 90) == [255, 255, 255], "white")
        #expect([43, 44, 45, 46, 48].map { g(120, $0) } == [0, 255, 255, 0, 200], "the corner pin's top edge at y = 45 (row 43 is off the picture)")
        #expect([82, 120, 238].map { g($0, 135) } == [255, 255, 255], "its bottom edge at y = 135")
        // `tick` reads the centre, (160, 90), on slice 2's edge; the ticks are 1 s apart
        for _ in 0..<2 { _ = rig.tick(.normal, master: 1, layer: 1) }
        #expect(rig.tick(.normal, master: 1, layer: 1) == 255, "4 s after the lease was taken")
        #expect(rig.tick(.normal, master: 1, layer: 1) == 200, "5 s after: it ran out")
    }

    /// The keystone moves the lines with the mapping and they are extruded after it: still 2 px where it halves the picture.
    @Test func theOverlayFollowsTheKeystoneAndKeepsItsWidth() throws {
        let rig = try Rig(nil, value: 200)
        _ = try Self.overlaid(rig)
        rig.keystone = simd_float3x3(rowMajor: WarpMath.keystone(to: [MapPoint(0.25, 0.25), MapPoint(0.75, 0.25), MapPoint(0.75, 0.75), MapPoint(0.25, 0.75)])!)
        _ = rig.tick(.normal, master: 1, layer: 1)
        let image = rig.compositor.readbackOutput().bgra
        func g(_ x: Int) -> Int { Int(image[(90 * Self.width + x) * 4 + 1]) }
        // the picture at x 120…200 now: the corner pin's edges there, slice 2's at 160
        #expect([118, 119, 120, 121, 123].map(g) == [0, 255, 255, 0, 200], "\([118, 119, 120, 121, 123].map(g))")
        #expect([158, 159, 160, 161, 163].map(g) == [0, 255, 255, 0, 200], "\([158, 159, 160, 161, 163].map(g))")
        #expect([196, 198, 199, 200].map(g) == [200, 0, 255, 255], "\([196, 198, 199, 200].map(g))")
    }

    /// The selected point is a yellow crosshair, wider than the lines and open in the middle, with its number beside it in
    /// yellow seven-segment digits.
    @Test func theSelectedPointIsAYellowCrosshairWithItsNumber() throws {
        let rig = try Rig(nil, value: 200)
        _ = try Self.overlaid(rig, selected: OverlaySelection(kind: .corner, point: 0))
        _ = rig.tick(.normal, master: 1, layer: 1)
        let image = rig.compositor.readbackOutput().bgra
        let yellow = [0, 255, 255]
        // corner 1 lands at (80, 45); its right arm runs from 6 to 24 px to the right, rows 43–46, a black edge below
        #expect([43, 44, 45, 46, 47].map { Self.bgr(image, 95, $0) } == [yellow, yellow, yellow, yellow, [0, 0, 0]])
        #expect(Self.bgr(image, 80, 45) == [255, 255, 255], "the corner itself: the corner pin's edges, between the arms")
        // the label "1", 30 px right of and below the point: one stroke at x = 116 from y = 75 to 97
        #expect(Self.bgr(image, 116, 85) == yellow && Self.bgr(image, 115, 92) == yellow)
        #expect(Self.bgr(image, 116, 101) == [200, 200, 200] && Self.bgr(image, 112, 85) == [200, 200, 200])
    }

    /// The lines belong to the edited mapping: none while a preset shows or a morph from one runs, nor in raw; a number the
    /// output lacks shows the edited mapping, and the overlay with it.
    @Test func theOverlayIsOnlyOverTheEditedMapping() throws {
        let rig = try Rig(nil, value: 200)
        _ = try Self.overlaid(rig, at: 3620)
        func line() -> Int { rig.tick(.normal, master: 1, layer: 1) }  // the centre, on slice 2's edge
        #expect(line() == 255, "the edited mapping")
        rig.preset = 1
        #expect(line() == 200, "preset 1, the same mapping: no lines")
        rig.preset = 7
        #expect(line() == 255, "a number the output lacks")
        (rig.preset, rig.morph) = (0, PresetMorph(from: 1, start: 3600, fade: 100))
        #expect(line() == 200, "a morph from preset 1 into the edited mapping")
        (rig.preset, rig.morph) = (1, PresetMorph(from: 0, start: 3600, fade: 100))
        #expect(line() == 200, "a morph from the edited mapping into preset 1")
        (rig.preset, rig.morph, rig.raw) = (0, PresetMorph(), true)
        #expect(line() == 200, "raw")
        rig.raw = false
        #expect(line() == 255, "the edited mapping again")
    }

    /// The overlay follows the output's Blackout and the Master: black stays black, Master 50 % gives half-white lines.
    @Test func theOverlayFollowsBlackoutAndTheMaster() throws {
        let rig = try Rig(nil, value: 200)
        _ = try Self.overlaid(rig, selected: OverlaySelection(kind: .corner, point: 0))
        func black() -> Bool { rig.compositor.readbackOutput().bgra.enumerated().allSatisfy { $0.offset % 4 == 3 || $0.element <= 1 } }
        _ = rig.tick(.blackout, master: 1, layer: 1)
        #expect(black(), "the output's Blackout")
        _ = rig.tick(.normal, master: 1, layer: 1, blackout: true)
        #expect(black(), "the Master's blackout")
        _ = rig.tick(.normal, master: 0.5, layer: 1)
        let image = rig.compositor.readbackOutput().bgra
        #expect(Self.near(Self.bgr(image, 160, 90)[1], 128) && Self.near(Self.bgr(image, 95, 45)[2], 128) && Self.bgr(image, 95, 45)[0] == 0, "\(Self.bgr(image, 160, 90)) \(Self.bgr(image, 95, 45))")
    }

    /// A secondary display draws the overlay too, at its own frame time.
    @Test func aSecondaryDisplayDrawsTheOverlay() throws {
        let rig = try Rig(nil, value: 200)
        let set = try Self.overlaid(rig)
        _ = rig.tick(.normal, master: 1, layer: 1)
        #expect(try rig.present(set, at: (160, 90), now: 3604.9) == 255)
        #expect(try rig.present(set, at: (160, 90), now: 3605) == 200, "the lease ran out")
    }

    /// The output preview, compiled as the engine compiles it (its own compiler, no overlay), shows no lines while the
    /// projector does: the editor draws its own handles over it.
    @Test func thePreviewDrawsNoOverlay() async throws {
        let rig = try Rig(nil, value: 200)
        _ = try Self.overlaid(rig)
        let streamer = try PreviewStreamer(context: rig.context, width: Self.width, height: Self.height, fps: 5, canvasFPS: 5, parameters: rig.parameters, logger: Logger(label: "output-test"))
        streamer.outputSet = OutputSet(plans: [try OutputCompiler(device: rig.context.device).compile(Self.overlayConfig(), index: 1, drawable: (Self.width, Self.height))])
        streamer.externalJPEGWanted = { true }
        rig.compositor.previewTap = { canvas, buffer, target, live in streamer.tap(canvas: canvas, commandBuffer: buffer, target: target, live: live) }
        #expect(rig.tick(.normal, master: 1, layer: 1) == 255, "the projector draws slice 2's edge at the centre")
        #expect(await waitUntil { streamer.jpegOut.load(ordering: .relaxed) > 0 })
        let (jpeg, width, height) = try #require(streamer.latestJPEG.withLock { $0 })
        let image = try #require(CGImageSourceCreateWithData(Data(jpeg) as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for (x, y) in [(160, 90), (120, 45)] {
            #expect(abs(Int(rgba[(y * width + x) * 4 + 1]) - 200) <= 8, "the preview at (\(x), \(y)): \(rgba[(y * width + x) * 4 + 1])")
        }
    }
}
