// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import Foundation
import ImageIO
import FanousCore
import Logging
import Metal
import Testing
import UniformTypeIdentifiers

@testable import FanousEngine

/// Golden images for every blend mode, effect and transform (DESIGN.md §19,
/// Phase 3). Renders a synthetic still through the real compositor at 320×180
/// and compares with Tests/Fixtures/golden/<case>.png. Set
/// `FANOUS_RECORD_GOLDEN=1` to (re)write the references.
@Suite(.serialized)
struct GoldenTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/golden")
    static let record = ProcessInfo.processInfo.environment["FANOUS_RECORD_GOLDEN"] == "1"
    static let width = 320, height = 180

    struct Case {
        var name: String
        var layer = LayerParameters()
        var background: LayerParameters?
        var master: Float = 1
        var masterControl: MasterControl = .normal
        var time = 0.0
        var dissolve: Float = 0  // > 0: an outgoing playback at this progress
        var testPattern: TestPattern = .off
        /// Render the output pass (drawable-sized bgra8) instead of reading the canvas.
        var output = false

        init(_ name: String, _ edit: (inout LayerParameters) -> Void = { _ in }) {
            self.name = name
            layer.intensity = 1
            layer.folder = 1
            layer.file = 1
            edit(&layer)
        }
    }

    static var cases: [Case] {
        var all: [Case] = [
            Case("baseline"),
            Case("fit-fill") { $0.fitMode = .fill },
            Case("fit-stretch") { $0.fitMode = .stretch },
            Case("fit-native") { $0.fitMode = .native },
            Case("position") { $0.positionX = 0.25; $0.positionY = -0.1 },
            Case("scale") { $0.scaleX = 0.5; $0.scaleY = 1.5 },
            Case("rotation-z") { $0.rotationZ = 30 * .pi / 180 },
            Case("rotation-x") { $0.rotationX = 45 * .pi / 180 },
            Case("rotation-y") { $0.rotationY = -60 * .pi / 180 },
            Case("position-z") { $0.positionZ = 0.5 },
            Case("crop") { $0.cropLeft = 0.1; $0.cropRight = 0.2; $0.cropTop = 0.3; $0.cropBottom = 0.05 },
            Case("colour-rgb") { $0.red = 0.5; $0.blue = 0.2 },
            Case("colour-brightness") { $0.brightness = 0.3 },
            Case("colour-contrast") { $0.contrast = 1.6 },
            Case("colour-saturation") { $0.saturation = 0.2 },
            Case("colour-hue") { $0.hue = 120 * .pi / 180 },
            Case("intensity-half") { $0.intensity = 0.5 },
            Case("effect-blur") { $0.effect1 = .blur; $0.effect1A = 0.5 },
            Case("effect-blur-motion") { $0.effect1 = .blur; $0.effect1A = 0.5; $0.effect1B = 0.25 },
            Case("effect-pixelate") { $0.effect1 = .pixelate; $0.effect1A = 0.3 },
            Case("effect-mirror-lr") { $0.effect1 = .mirror; $0.effect1A = 0.1; $0.effect1B = 0.2 },
            Case("effect-mirror-bt") { $0.effect1 = .mirror; $0.effect1A = 0.9; $0.effect1B = 0.0 },
            Case("effect-kaleidoscope") { $0.effect1 = .kaleidoscope; $0.effect1A = 0.3; $0.effect1B = 0.1 },
            Case("effect-invert") { $0.effect1 = .invert },
            Case("effect-strobe-on") { $0.effect1 = .strobe; $0.effect1A = 0; $0.effect1B = 0.5 },
            Case("effect-lumakey") { $0.effect1 = .lumaKey; $0.effect1A = 0.4; $0.effect1B = 0.1 },
            Case("effect-chromakey") { $0.effect1 = .chromaKey; $0.effect1A = 0.3; $0.effect1B = 1.0 / 3.0 },
            Case("effect-edge") { $0.effect1 = .edge; $0.effect1A = 0.5 },
            Case("effect-threshold") { $0.effect1 = .threshold; $0.effect1A = 0.5; $0.effect1B = 0.1 },
            Case("effect-tint") { $0.effect1 = .tint; $0.effect1A = 1; $0.effect1B = 0 },
            Case("effect-two-slots") { $0.effect1 = .pixelate; $0.effect1A = 0.3; $0.effect2 = .invert },
        ]
        var strobeOff = Case("effect-strobe-off") { $0.effect1 = .strobe; $0.effect1A = 0; $0.effect1B = 0.1 }
        strobeOff.time = 0.5
        all.append(strobeOff)
        for blend in BlendMode.allCases {
            var c = Case("blend-\(blend)") { $0.blendMode = blend; $0.intensity = 0.8 }
            var background = LayerParameters()
            background.intensity = 1
            background.folder = 1
            background.file = 2
            c.background = background
            all.append(c)
        }
        var master = Case("master-half")
        master.master = 0.5
        all.append(master)
        var blackout = Case("master-blackout")
        blackout.masterControl = .blackout
        all.append(blackout)
        var dissolve = Case("dissolve-half")
        dissolve.dissolve = 0.5
        all.append(dissolve)
        var dissolveAdd = Case("dissolve-half-add") { $0.blendMode = .add }
        dissolveAdd.dissolve = 0.5
        all.append(dissolveAdd)
        var outputCopy = Case("output-canvas")
        outputCopy.output = true
        all.append(outputCopy)
        for pattern in TestPattern.allCases where pattern != .off {
            var c = Case("output-pattern-\(pattern)")
            c.output = true
            c.testPattern = pattern
            all.append(c)
        }
        return all
    }

    /// 256×144 synthetic still: hue across x, luminance across y, a white square,
    /// a transparent corner, a saturated green patch and hard edges.
    static func pattern(device: MTLDevice, variant: Int) throws -> DecodedFrame {
        let w = 256, h = 144
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let hue = Double(x) / Double(w)
                let value = 0.25 + 0.75 * Double(y) / Double(h)
                var (r, g, b) = hsv(hue, 1, value)
                var a = 1.0
                if variant == 1 {  // background: diagonal grey ramp with a magenta bar
                    let t = Double(x + y) / Double(w + h)
                    (r, g, b) = (t, t, t)
                    if x > 180 && x < 200 { (r, g, b) = (0.9, 0.1, 0.9) }
                } else {
                    if x > 32 && x < 64 && y > 24 && y < 56 { (r, g, b) = (1, 1, 1) }
                    if x > 96 && x < 144 && y > 80 && y < 120 { (r, g, b) = (0.1, 0.9, 0.15) }
                    if x > 200 && y < 40 { a = 0 }
                    if x > 160 && x < 170 && y > 40 && y < 140 { (r, g, b) = (0, 0, 0) }
                }
                pixels[i] = UInt8((r * 255).rounded())
                pixels[i + 1] = UInt8((g * 255).rounded())
                pixels[i + 2] = UInt8((b * 255).rounded())
                pixels[i + 3] = UInt8((a * 255).rounded())
            }
        }
        let texture = try MovieSource.makeTexture(device, .rgba8Unorm, w, h)
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        let frame = DecodedFrame(poolIndex: 0)
        frame.kind = .rgba
        frame.frameIndex = 0
        frame.texture0 = texture
        return frame
    }

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    static func render(_ c: Case, context: MetalContext) throws -> (Int, Int, [UInt8]) {
        let metrics = MetricsRing(capacity: 16)
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 2) }
        let compositor = try Compositor(
            context: context, canvasWidth: width, canvasHeight: height, fps: 60, maxLayers: 2, metrics: metrics, parameters: parameters,
            logger: Logger(label: "golden"))
        let background = RenderLayer(index: 0)
        let layer = RenderLayer(index: 1)
        let still = try pattern(device: context.device, variant: 0)
        layer.current = LayerPlayback(key: MediaKey(folder: 1, file: 1), still: still)
        if c.background != nil {
            background.current = LayerPlayback(key: MediaKey(folder: 1, file: 2), still: try pattern(device: context.device, variant: 1))
        }
        if c.dissolve > 0 {
            layer.outgoing = LayerPlayback(key: MediaKey(folder: 1, file: 2), still: try pattern(device: context.device, variant: 1))
            layer.dissolveStart = 100
            layer.dissolveDuration = 1
        }
        compositor.setLayers([background, layer])
        var outputTexture: MTLTexture?
        if c.output {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.outputFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            outputTexture = context.device.makeTexture(descriptor: descriptor)
            compositor.offscreenOutput = outputTexture
        }
        parameters.write { slot in
            slot.sequence = 1
            slot.master = c.master
            slot.masterControl = c.masterControl
            slot.testPattern = c.testPattern
            slot.layers[0] = c.background ?? LayerParameters()
            slot.layers[1] = c.layer
        }
        // the hand-off would ask the (absent) loader for media; the slots already hold the stills, so wanted == loaded
        background.wanted.store(slot(c.background), ordering: .relaxed)
        layer.wanted.store(c.layer.mediaKey.packed, ordering: .relaxed)
        let target = c.dissolve > 0 ? 100 + Double(c.dissolve) : 3600 + c.time
        compositor.tick(target: target, drawable: nil)
        if let outputTexture {
            // wait for the GPU (readback() below does the same through its own command buffer)
            _ = compositor.readback()
            var bgra = [UInt8](repeating: 0, count: width * height * 4)
            outputTexture.getBytes(&bgra, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            for i in stride(from: 0, to: bgra.count, by: 4) { bgra.swapAt(i, i + 2) }
            return (width, height, bgra)
        }
        let result = compositor.readback()
        return (result.width, result.height, result.rgba)
    }

    static func slot(_ p: LayerParameters?) -> UInt32 { p?.mediaKey.packed ?? 0 }

    @Test func goldenImages() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        _ = device
        let context = try MetalContext()
        var failures: [String] = []
        for c in Self.cases {
            let (w, h, rgba) = try Self.render(c, context: context)
            #expect(w == Self.width && h == Self.height, Comment(rawValue: c.name))
            let file = Self.directory.appending(path: "\(c.name).png")
            if Self.record {
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                try Self.writePNG(rgba, width: w, height: h, to: file)
                continue
            }
            guard let reference = Self.readPNG(file) else {
                failures.append("\(c.name): no golden image (record with FANOUS_RECORD_GOLDEN=1)")
                continue
            }
            if let problem = Self.compare(rgba, reference, name: c.name) { failures.append(problem) }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    /// GPUs differ in the last bits (fast math, filtering): allow small noise, catch real changes.
    static func compare(_ a: [UInt8], _ b: [UInt8], name: String) -> String? {
        guard a.count == b.count else { return "\(name): size differs" }
        var over4 = 0, maxDiff = 0, sum = 0
        for i in a.indices {
            let d = abs(Int(a[i]) - Int(b[i]))
            sum += d
            if d > 4 { over4 += 1 }
            maxDiff = max(maxDiff, d)
        }
        let mean = Double(sum) / Double(a.count)
        if Double(over4) > Double(a.count) * 0.005 || maxDiff > 48 || mean > 1 {
            return "\(name): mean \(String(format: "%.2f", mean)), max \(maxDiff), \(over4) samples > 4"
        }
        return nil
    }

    static func writePNG(_ rgba: [UInt8], width: Int, height: Int, to url: URL) throws {
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw RenderError.pipeline("png") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.pipeline("png write") }
    }

    static func readPNG(_ url: URL) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? pixels : nil
    }
}
