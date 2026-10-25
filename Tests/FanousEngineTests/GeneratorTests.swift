// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Metal
import Testing

@testable import FanousEngine

/// Folder 0 generators and the output test patterns, rendered through the real compositor. `FANOUS_DUMP_PATTERNS=DIR`
/// writes every image as PNG for review.
struct GeneratorTests {
    static let width = 960, height = 540

    /// One tick of a 960×540 canvas with `playback` on layer 1, read back through a plain full-region output.
    static func render(_ playback: LayerPlayback?, pattern: Int = 0, context: MetalContext, ticks: Int = 1, compositor existing: Compositor? = nil) throws -> (Compositor, [UInt8]) {
        let compositor: Compositor
        if let existing {
            compositor = existing
        } else {
            let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) }
            compositor = try Compositor(
                context: context, canvasWidth: width, canvasHeight: height, fps: 60, maxLayers: 1, metrics: MetricsRing(capacity: 64), parameters: parameters,
                logger: Logger(label: "generator-test"))
            let layer = RenderLayer(index: 0)
            layer.current = playback
            if let playback { layer.wanted.store(playback.key.packed, ordering: .relaxed) }
            compositor.setLayers([layer])
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.outputFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            compositor.offscreenOutput = context.device.makeTexture(descriptor: descriptor)
            var o = OutputConfig(id: 1)
            o.testPattern = pattern
            compositor.outputSet = OutputSet(plans: [try OutputCompiler(device: context.device).compile(o, index: 1, drawable: (width, height))])
            parameters.write { slot in
                slot.sequence = 1
                slot.layers[0].intensity = 1
                slot.layers[0].folder = UInt8(clamping: playback?.key.folder ?? 0)
                slot.layers[0].file = UInt8(clamping: playback?.key.file ?? 0)
                slot.layers[0].fitMode = .stretch
            }
        }
        var bgra: [UInt8] = []
        for i in 0..<ticks {
            compositor.tick(target: 3600 + Double(i) / 60, drawable: nil)
            bgra = compositor.readbackOutput().bgra
        }
        return (compositor, bgra)
    }

    static func dump(_ bgra: [UInt8], _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["FANOUS_DUMP_PATTERNS"] else { return }
        var rgba = bgra
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
        try GoldenTests.writePNG(rgba, width: width, height: height, to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }

    static func pixel(_ bgra: [UInt8], _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(bgra[i + 2]), Int(bgra[i + 1]), Int(bgra[i]))
    }

    @Test func everyGeneratorDrawsAndTheTestCardRedrawsEachFrame() throws {
        let context = try MetalContext()
        for (file, name) in Generators.names.sorted(by: { $0.key < $1.key }) {
            let generator = try #require(GeneratorSource(context: context, file: file, width: Self.width, height: Self.height))
            let (_, image) = try Self.render(LayerPlayback(key: MediaKey(folder: 0, file: file), live: generator), context: context, ticks: 2)
            #expect(image.contains { $0 > 40 }, "\(name) drew nothing")
            try Self.dump(image, "generator-\(file)-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }
        // solid colour is white × the layer tint
        let solid = try #require(GeneratorSource(context: context, file: 100, width: Self.width, height: Self.height))
        let (_, white) = try Self.render(LayerPlayback(key: MediaKey(folder: 0, file: 100), live: solid), context: context)
        #expect(Self.pixel(white, 480, 270).r > 250 && Self.pixel(white, 480, 270).g > 250)
        // test card: the frame flag (top-left square) flips between consecutive ticks
        let card = try #require(GeneratorSource(context: context, file: 110, width: Self.width, height: Self.height))
        let (compositor, first) = try Self.render(LayerPlayback(key: MediaKey(folder: 0, file: 110), live: card), context: context)
        let (_, second) = try Self.render(nil, context: context, compositor: compositor)
        let flag = (x: Int(Double(Self.height) * 0.09), y: Int(Double(Self.height) * 0.09))
        #expect(Self.pixel(first, flag.x, flag.y).g != Self.pixel(second, flag.x, flag.y).g, "frame flag did not alternate")
    }

    @Test func testPatternsRender() throws {
        let context = try MetalContext()
        for pattern in TestPattern.allCases where pattern != .off {
            let (_, image) = try Self.render(nil, pattern: pattern.rawValue, context: context)
            #expect(image.contains { $0 > 40 }, "\(pattern) drew nothing")
            try Self.dump(image, "pattern-\(pattern.rawValue)-\(pattern)")
        }
        // output ID: a large "1" through the centre of output 1, on its colour
        let (_, id) = try Self.render(nil, pattern: TestPattern.outputID.rawValue, context: context)
        #expect(Self.pixel(id, 480, 270).r > 240 && Self.pixel(id, 480, 270).g > 240, "\(Self.pixel(id, 480, 270))")
        #expect(Self.pixel(id, 300, 270).r < 200, "background is the output colour, not white")
    }
}
