// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Metal

/// Built-in content in folder 0 (DESIGN.md §8.2): drawn on the GPU every frame, no files. Selected like media,
/// so a console (or the UI) can put a test card on any layer and transform, tint and dissolve it like a clip.
public enum Generators {
    /// file number → name; 100 is white (the layer's Red/Green/Blue channels give it a colour)
    public static let names: [Int: String] = [
        100: "Solid colour", 101: "Grid", 102: "Colour bars", 103: "Blend check", 104: "Output ID", 105: "Crosshair", 106: "Grey steps",
        107: "Checkerboard", 110: "Test card", 111: "Colour sweep", 112: "Clock", 113: "Motion test",
    ]

    public static func isGenerator(_ key: MediaKey) -> Bool { key.folder == 0 && names[key.file] != nil }
}

/// Layout matches `GeneratorUniforms` in Shaders.swift. Characters: 0–9 digits, 10 colon, 11 blank.
struct GeneratorUniforms {
    var size: SIMD2<Float> = .zero
    var kind: UInt32 = 0
    var frame: UInt32 = 0
    var time: Float = 0
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
    var d0 = SIMD4<UInt32>(repeating: 11), d1 = SIMD4<UInt32>(repeating: 11), d2 = SIMD4<UInt32>(repeating: 11)
    var d3 = SIMD4<UInt32>(repeating: 11), d4 = SIMD4<UInt32>(repeating: 11)

    mutating func put(_ c: Int, at i: Int) {
        let v = UInt32(c)
        switch i / 4 {
        case 0: d0[i % 4] = v
        case 1: d1[i % 4] = v
        case 2: d2[i % 4] = v
        case 3: d3[i % 4] = v
        default: d4[i % 4] = v
        }
    }

    /// "hh:mm:ss:ff" at 0…10 (ff = -1 leaves the last pair blank → "hh:mm:ss" at 0…7)
    /// No array of the parts: the clock's array allocated on the compositor thread once per second (B112).
    mutating func putTime(h: Int, m: Int, s: Int, f: Int, at start: Int) {
        putPair(h, at: start)
        put(10, at: start + 2)
        putPair(m, at: start + 3)
        put(10, at: start + 5)
        putPair(s, at: start + 6)
        guard f >= 0 else { return }
        put(10, at: start + 8)
        putPair(f, at: start + 9)
    }

    private mutating func putPair(_ value: Int, at i: Int) {
        put(value / 10 % 10, at: i)
        put(value % 10, at: i + 1)
    }
}

/// One generator instance on a layer: a canvas-sized texture the compositor redraws each tick.
public final class GeneratorSource: LiveTextureSource, @unchecked Sendable {
    let kind: UInt32
    /// Kinds 100–107 look the same every frame: drawn once at creation.
    var isStatic: Bool { (100...107).contains(kind) }
    /// Wall-clock second the clock (112) was last drawn for.
    var drawnSecond = -1
    /// Draws encoded so far (the first one is the creation draw); diagnostics and tests.
    private(set) var encodeCount = 0
    /// Replaced only by `resize` on the compositor thread, which is also the only reader once the layer has it.
    private(set) var texture: MTLTexture
    private let context: MetalContext
    /// Made once (B112): made per draw, the descriptor added 4 allocations on the compositor thread and the label 1.
    /// The label is an `NSString`: a small (≤15-byte) Swift `String` is bridged, and allocates, on every assignment.
    private let pass = MTLRenderPassDescriptor()
    private let label: NSString
    public var latestFrame: LiveFrame? { LiveFrame(texture0: texture) }

    init?(context: MetalContext, file: Int, width: Int, height: Int) {
        guard Generators.names[file] != nil, let texture = Self.makeTexture(context, file: file, width: width, height: height) else { return nil }
        self.kind = UInt32(file)
        self.texture = texture
        self.context = context
        label = "generator \(file)" as NSString
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        drawFirstFrame()
    }

    private static func makeTexture(_ context: MetalContext, file: Int, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = context.device.makeTexture(descriptor: descriptor)
        texture?.label = "generator \(file)"
        return texture
    }

    /// First frame now, so the layer never shows an empty texture before the compositor's next tick.
    private func drawFirstFrame() {
        var u = GeneratorUniforms()
        u.kind = kind
        drawnSecond = -1
        if let commandBuffer = context.queue.makeCommandBuffer() {
            encode(into: commandBuffer, uniforms: u)
            commandBuffer.commit()
        }
    }

    /// The canvas changed size (B31): a new texture at that size, drawn before the tick's own command buffer.
    /// Compositor thread only; keeps the old texture when the new one cannot be made.
    func resize(width: Int, height: Int) {
        guard let texture = Self.makeTexture(context, file: Int(kind), width: width, height: height) else { return }
        self.texture = texture
        pass.colorAttachments[0].texture = texture
        drawFirstFrame()
    }

    func encode(into commandBuffer: MTLCommandBuffer, uniforms: GeneratorUniforms) {
        encodeCount += 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        u.kind = kind
        u.size = SIMD2(Float(texture.width), Float(texture.height))
        encoder.label = label as String
        encoder.setRenderPipelineState(context.generatorPipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<GeneratorUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    public func stop() {}
}
