// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import Foundation
import LanthornCore
import Metal
import simd

/// Uniforms of the mapped output pass; layout matches `MappedUniforms` in Shaders.swift.
struct MappedUniforms {
    var size: SIMD2<Float> = .zero
    var intensity: Float = 1
    var opacity: Float = 1
    var flags: UInt32 = 0
    var pad = SIMD3<UInt32>(repeating: 0)
}

/// One slice ready to draw: tessellated mesh and an optional mask texture.
public final class SlicePlan: @unchecked Sendable {
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int
    let mask: MTLTexture?
    let opacity: Float
    init(vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int, mask: MTLTexture?, opacity: Float) {
        self.vertices = vertices
        self.indices = indices
        self.indexCount = indexCount
        self.mask = mask
        self.opacity = opacity
    }
}

/// Everything the render thread needs for one output region (DESIGN.md §9.5): GPU resources compiled on
/// Control by `OutputCompiler`, immutable afterwards, swapped in as a whole.
public final class OutputPlan: @unchecked Sendable {
    public let id: Int
    /// 1-based output number (Output fixture, "output ID" pattern).
    public let index: Int
    /// Region on the drawable, in pixels.
    public let region: MTLRegion
    public let intensity: Float
    public let testPattern: TestPattern
    let blendMap: MTLTexture?
    let warpField: MTLTexture?
    let slices: [SlicePlan]

    init(id: Int, index: Int, region: MTLRegion, intensity: Float, testPattern: TestPattern, blendMap: MTLTexture?, warpField: MTLTexture?, slices: [SlicePlan]) {
        self.id = id
        self.index = index
        self.region = region
        self.intensity = intensity
        self.testPattern = testPattern
        self.blendMap = blendMap
        self.warpField = warpField
        self.slices = slices
    }
}

/// The plans of one display, swapped into the compositor as one reference.
public final class OutputSet: @unchecked Sendable {
    public let plans: [OutputPlan]
    public init(plans: [OutputPlan]) { self.plans = plans }
}

/// Compiles `OutputConfig` into textures and meshes (edit-time cost only, DESIGN.md §9.2–9.4).
public struct OutputCompiler: @unchecked Sendable {
    public static let sliceSubdivisions = 64
    public static let fieldDivisor = 4
    private let device: MTLDevice
    private let uniforms: MTLBuffer

    public init(device: MTLDevice) throws {
        self.device = device
        guard let uniforms = device.makeBuffer(length: 256, options: .storageModeShared) else { throw RenderError.pipeline("mapped uniforms") }
        self.uniforms = uniforms
    }

    /// `drawable` is the size of the display's drawable in pixels; a nil region covers it entirely.
    public func compile(_ config: OutputConfig, index: Int, drawable: (width: Int, height: Int)) throws -> OutputPlan {
        let r = config.region ?? PixelRect(x: 0, y: 0, w: drawable.width, h: drawable.height)
        let x = min(max(0, r.x), max(0, drawable.width - 1)), y = min(max(0, r.y), max(0, drawable.height - 1))
        let w = max(1, min(r.w, drawable.width - x)), h = max(1, min(r.h, drawable.height - y))
        let region = MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0), size: MTLSize(width: w, height: h, depth: 1))

        var blendMap: MTLTexture? = nil
        if !config.blend.isIdentity {
            let map = BlendMath.map(config.blend, width: w, height: h).map { Float16($0) }
            blendMap = try texture(.rg16Float, width: w, height: h, bytesPerPixel: 4, label: "blend \(config.id)") { map.withUnsafeBytes { $0.baseAddress! } }
        }
        var warpField: MTLTexture? = nil
        if !config.warp.isIdentity {
            let cols = max(2, w / Self.fieldDivisor), rows = max(2, h / Self.fieldDivisor)
            let field = WarpMath.field(config.warp, cols: cols, rows: rows)
            warpField = try texture(.rg32Float, width: cols, height: rows, bytesPerPixel: 8, label: "warp \(config.id)") { field.withUnsafeBytes { $0.baseAddress! } }
        }
        var slices: [SlicePlan] = []
        for slice in config.slices {
            let (vertices, indices) = SliceMesh.build(slice, subdivisions: Self.sliceSubdivisions)
            guard !vertices.isEmpty,
                let vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SliceMesh.Vertex>.stride, options: .storageModeShared),
                let indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared)
            else { throw RenderError.pipeline("slice mesh \(slice.id)") }
            vertexBuffer.label = "slice \(config.id).\(slice.id)"
            var mask: MTLTexture? = nil
            if let m = slice.mask, m.path.count >= 3 {
                if m.feather >= 2 {
                    // signed-distance feather on a coarser grid (the field is smooth); 1080p with an 8 px feather → 480×270
                    let raster = MaskMath.raster(m, width: w, height: h, step: min(4, Int(m.feather / 2)))
                    mask = try texture(.r8Unorm, width: raster.width, height: raster.height, bytesPerPixel: 1, label: "mask \(config.id).\(slice.id)") { raster.bytes.withUnsafeBytes { $0.baseAddress! } }
                } else {
                    // hard edge: CoreGraphics fills the polygon pixel-exactly at full resolution
                    let raster = Self.fill(m.path, width: w, height: h)
                    mask = try texture(.r8Unorm, width: w, height: h, bytesPerPixel: 1, label: "mask \(config.id).\(slice.id)") { raster.withUnsafeBytes { $0.baseAddress! } }
                }
            }
            slices.append(SlicePlan(vertices: vertexBuffer, indices: indexBuffer, indexCount: indices.count, mask: mask, opacity: Float(slice.opacity)))
        }
        return OutputPlan(
            id: config.id, index: index, region: region, intensity: Float(config.intensity), testPattern: TestPattern(rawValue: config.testPattern) ?? .off,
            blendMap: blendMap, warpField: warpField, slices: slices)
    }

    /// Anti-aliased polygon fill, 8-bit coverage, row-major from the top-left.
    static func fill(_ path: [MapPoint], width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            context.setFillColor(gray: 1, alpha: 1)
            context.setShouldAntialias(true)
            // CoreGraphics' origin is bottom-left; flip so row 0 is the top
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.beginPath()
            for (i, p) in path.enumerated() {
                let point = CGPoint(x: p.x * Double(width), y: p.y * Double(height))
                if i == 0 { context.move(to: point) } else { context.addLine(to: point) }
            }
            context.closePath()
            context.fillPath(using: .evenOdd)
        }
        return bytes
    }

    private func texture(_ format: MTLPixelFormat, width: Int, height: Int, bytesPerPixel: Int, label: String, bytes: () -> UnsafeRawPointer) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.pipeline(label) }
        texture.label = label
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes(), bytesPerRow: width * bytesPerPixel)
        return texture
    }
}

/// Draws output plans into a drawable-sized target (the output pass of DESIGN.md §9.5).
enum OutputPass {
    /// `outputs` are the Output fixture values by index (1-based → index − 1); `master` the Master intensity.
    static func draw(
        _ set: OutputSet, canvas: MTLTexture, encoder: MTLRenderCommandEncoder, context: MetalContext, uniforms: MTLBuffer,
        master: Float, masterPattern: TestPattern, outputs: [OutputParameters]
    ) {
        var offset = 0
        for plan in set.plans {
            let fixture = plan.index - 1 < outputs.count && plan.index >= 1 ? outputs[plan.index - 1] : OutputParameters()
            let region = plan.region
            encoder.setViewport(MTLViewport(originX: Double(region.origin.x), originY: Double(region.origin.y), width: Double(region.size.width), height: Double(region.size.height), znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: region.origin.x, y: region.origin.y, width: region.size.width, height: region.size.height))
            let pattern = masterPattern != .off ? masterPattern : (fixture.testPattern != .off ? fixture.testPattern : plan.testPattern)
            let intensity = fixture.control == .blackout ? 0 : plan.intensity * fixture.intensity * master
            if pattern != .off {
                // whole region: the plain output pass draws the pattern
                guard offset + 256 <= uniforms.length else { return }
                (uniforms.contents() + offset).assumingMemoryBound(to: OutputUniforms.self).pointee = {
                    var o = OutputUniforms()
                    o.size = SIMD2(Float(region.size.width), Float(region.size.height))
                    o.pattern = UInt32(pattern.rawValue)
                    o.index = UInt32(plan.index)
                    return o
                }()
                encoder.setRenderPipelineState(context.outputPipeline)
                encoder.setFragmentBuffer(uniforms, offset: offset, index: 0)
                encoder.setFragmentTexture(canvas, index: 0)
                encoder.setFragmentSamplerState(context.linearSampler, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                offset += 256
                continue
            }
            encoder.setRenderPipelineState(context.mappedPipeline)
            encoder.setVertexSamplerState(context.linearSampler, index: 0)
            encoder.setFragmentSamplerState(context.linearSampler, index: 0)
            encoder.setFragmentTexture(canvas, index: 0)
            encoder.setFragmentTexture(plan.blendMap ?? canvas, index: 2)
            encoder.setVertexTexture(plan.warpField ?? canvas, index: 0)
            for slice in plan.slices {
                guard offset + 256 <= uniforms.length else { return }
                var u = MappedUniforms()
                u.size = SIMD2(Float(region.size.width), Float(region.size.height))
                u.intensity = intensity
                u.opacity = slice.opacity
                u.flags = (plan.warpField != nil ? 1 : 0) | (slice.mask != nil ? 2 : 0) | (fixture.raw ? 4 : 0) | (plan.blendMap == nil ? 8 : 0)
                (uniforms.contents() + offset).assumingMemoryBound(to: MappedUniforms.self).pointee = u
                encoder.setVertexBuffer(slice.vertices, offset: 0, index: 0)
                encoder.setVertexBuffer(uniforms, offset: offset, index: 1)
                encoder.setFragmentBuffer(uniforms, offset: offset, index: 1)
                encoder.setFragmentTexture(slice.mask ?? canvas, index: 1)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: slice.indexCount, indexType: .uint32, indexBuffer: slice.indices, indexBufferOffset: 0)
                offset += 256
            }
        }
    }
}
