// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import Foundation
import FanousCore
import Metal
import simd

/// Uniforms of the mapped output pass; layout matches `MappedUniforms` in Shaders.swift.
struct MappedUniforms {
    var size: SIMD2<Float> = .zero
    var intensity: Float = 1
    var opacity: Float = 1
    var flags: UInt32 = 0
    var pattern: UInt32 = 0
    var index: UInt32 = 0
    /// Content only: the canvas sample's factor, before the blend map and lift (`OutputPass.contentScale`).
    var scale: Float = 1
    /// Per-output colour: gain r, g, b and the black offset (`OutputPlan.color`).
    var color: SIMD4<Float> = SIMD4(1, 1, 1, 0)
}

/// One slice ready to draw: tessellated mesh and an optional mask texture.
public final class SlicePlan: @unchecked Sendable {
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int
    let mask: MTLTexture?
    let opacity: Float
    /// Canvas id the slice samples (DESIGN.md §9.1).
    let canvas: Int
    init(vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int, mask: MTLTexture?, opacity: Float, canvas: Int = 1) {
        self.canvas = canvas
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
    /// Colour gain r, g, b and the black offset (`OutputConfig.color`).
    let color: SIMD4<Float>
    let blendMap: MTLTexture?
    let warpField: MTLTexture?
    let slices: [SlicePlan]
    /// The whole output (unit quad) tessellated like a slice: test patterns are drawn through it, so they follow the warp.
    let patternMesh: SlicePlan
    /// Canvas copies (by canvas id) taken when the Output fixture's Control engaged Freeze; the content pass samples them
    /// instead of the live canvases. Only touched by the one thread that renders this plan's set.
    nonisolated(unsafe) var held: [Int: MTLTexture] = [:]
    /// The Master intensity `held` was drawn with (the canvas carries it); same thread as `held`.
    nonisolated(unsafe) var heldMaster: Float = 1

    init(
        id: Int, index: Int, region: MTLRegion, intensity: Float, testPattern: TestPattern, color: SIMD4<Float>, blendMap: MTLTexture?, warpField: MTLTexture?,
        slices: [SlicePlan], patternMesh: SlicePlan
    ) {
        self.patternMesh = patternMesh
        self.color = color
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
    /// The set this one replaces, whose Freeze holds its plans take over (`OutputPass.adopt`, B111). Set by the creator
    /// before the swap; afterwards only the thread that renders this set touches it, and that thread clears it.
    nonisolated(unsafe) var previous: OutputSet?
    public init(plans: [OutputPlan], previous: OutputSet? = nil) {
        self.plans = plans
        self.previous = previous
    }
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
            blendMap = try texture(.rgba16Float, width: w, height: h, bytesPerPixel: 8, label: "blend \(config.id)") { map.withUnsafeBytes { $0.baseAddress! } }
        }
        var warpField: MTLTexture? = nil
        if !config.warp.isIdentity {
            let cols = max(2, w / Self.fieldDivisor), rows = max(2, h / Self.fieldDivisor)
            let field = WarpMath.field(config.warp, cols: cols, rows: rows)
            warpField = try texture(.rg32Float, width: cols, height: rows, bytesPerPixel: 8, label: "warp \(config.id)") { field.withUnsafeBytes { $0.baseAddress! } }
        }
        var slices: [SlicePlan] = []
        let full = SliceMesh.build(SliceConfig(id: 0), subdivisions: Self.sliceSubdivisions)
        guard let fullVertices = device.makeBuffer(bytes: full.vertices, length: full.vertices.count * MemoryLayout<SliceMesh.Vertex>.stride, options: .storageModeShared),
            let fullIndices = device.makeBuffer(bytes: full.indices, length: full.indices.count * 4, options: .storageModeShared)
        else { throw RenderError.pipeline("pattern mesh \(config.id)") }
        let patternMesh = SlicePlan(vertices: fullVertices, indices: fullIndices, indexCount: full.indices.count, mask: nil, opacity: 1)
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
            slices.append(SlicePlan(vertices: vertexBuffer, indices: indexBuffer, indexCount: indices.count, mask: mask, opacity: Float(slice.opacity), canvas: slice.canvas))
        }
        let gain = config.color.gain.count == 3 ? config.color.gain.map(Float.init) : [1, 1, 1]
        return OutputPlan(
            id: config.id, index: index, region: region, intensity: Float(config.intensity), testPattern: TestPattern(rawValue: config.testPattern) ?? .off,
            color: SIMD4(gain[0], gain[1], gain[2], Float(config.color.black)), blendMap: blendMap, warpField: warpField, slices: slices, patternMesh: patternMesh)
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
    static func fixture(for plan: OutputPlan, in outputs: [OutputParameters]) -> OutputParameters {
        plan.index - 1 < outputs.count && plan.index >= 1 ? outputs[plan.index - 1] : OutputParameters()
    }

    /// Output Control = Freeze: keeps a copy of the canvases its slices use from the moment Freeze engaged, released
    /// when it ends. `canvas` looks a canvas up by id (nil: it does not render); `master` is the Master intensity those
    /// canvases were drawn with. At Master 0 they are black and carry no picture: the plan stays live (black at 0) and
    /// holds the first canvas drawn above 0. Call before the output render encoder is created.
    static func holdFrozen(_ set: OutputSet, canvas: (Int) -> MTLTexture?, outputs: [OutputParameters], master: Float, buffer: MTLCommandBuffer) {
        adopt(set, canvas: canvas, outputs: outputs)
        for plan in set.plans {
            guard fixture(for: plan, in: outputs).control == .freeze else {
                if !plan.held.isEmpty { plan.held = [:] }
                continue
            }
            guard plan.held.isEmpty, master > 0 else { continue }
            var held: [Int: MTLTexture] = [:]
            for slice in plan.slices where held[slice.canvas] == nil {
                guard let source = canvas(slice.canvas) else { continue }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat, width: source.width, height: source.height, mipmapped: false)
                descriptor.usage = .shaderRead
                descriptor.storageMode = .private
                guard let copy = buffer.device.makeTexture(descriptor: descriptor), let blit = buffer.makeBlitCommandEncoder() else { continue }
                copy.label = "frozen output \(plan.id) canvas \(slice.canvas)"
                blit.copy(from: source, to: copy)
                blit.endEncoding()
                held[slice.canvas] = copy
            }
            plan.held = held
            plan.heldMaster = master
        }
    }

    /// An edit recompiles the plans while Freeze is engaged (B111): once, on the thread that renders `set`, each frozen
    /// plan takes the hold of the plan with its id in the set it replaced, if the held copies still match the canvases (a
    /// canvas resize blanks the outputs anyway, B59); then the replaced set is released. Not on MainActor: `held` is
    /// written by the render thread while the edit runs.
    static func adopt(_ set: OutputSet, canvas: (Int) -> MTLTexture?, outputs: [OutputParameters]) {
        guard let previous = set.previous else { return }
        set.previous = nil
        for plan in set.plans where plan.held.isEmpty && fixture(for: plan, in: outputs).control == .freeze {
            guard let old = previous.plans.first(where: { $0.id == plan.id }),
                old.held.allSatisfy({ id, held in canvas(id).map { $0.width == held.width && $0.height == held.height } ?? false })
            else { continue }
            (plan.held, plan.heldMaster) = (old.held, old.heldMaster)
        }
    }

    /// A content slice's canvas sample factor (B100). A live canvas already carries the Master (each layer is drawn with
    /// it): 1. A held one (`heldMaster`: the Master it was drawn with) follows the Master since, on the sample, so the
    /// black lift after it stays at the output's level; one held at 0 is black.
    static func contentScale(master: Float, heldMaster: Float?) -> Float {
        guard let heldMaster else { return 1 }
        return heldMaster > 0 ? master / heldMaster : 0
    }

    /// `canvas` looks a canvas up by id; canvas 1 always renders. A slice whose canvas does not render stays black.
    static func draw(
        _ set: OutputSet, canvas lookup: (Int) -> MTLTexture?, encoder: MTLRenderCommandEncoder, context: MetalContext, uniforms: MTLBuffer,
        master: Float, masterPattern: TestPattern, outputs: [OutputParameters]
    ) {
        // bound to texture slots the shader does not sample in this draw (patterns, no blend map, no warp, no mask)
        guard let canvas = lookup(1) else { return }
        var offset = 0
        for plan in set.plans {
            let fixture = fixture(for: plan, in: outputs)
            let region = plan.region
            encoder.setViewport(MTLViewport(originX: Double(region.origin.x), originY: Double(region.origin.y), width: Double(region.size.width), height: Double(region.size.height), znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: region.origin.x, y: region.origin.y, width: region.size.width, height: region.size.height))
            let pattern = masterPattern != .off ? masterPattern : (fixture.testPattern != .off ? fixture.testPattern : plan.testPattern)
            let level = fixture.control == .blackout ? 0 : plan.intensity * fixture.intensity
            // the Master once (B100): a pattern takes it here; the canvas already carries it (each layer is drawn with it, as
            // the canvas preview, Syphon and CITP show), so content keeps the output's level and the black lift stays while
            // the Master moves. Master 0 or Blackout is black at once, lift included: a secondary display draws the last
            // completed canvas, a tick behind
            let intensity = level * master
            let content = master <= 0 ? 0 : level
            if pattern != .off {
                // through the warp (and blend map) like the content, so a grid can be aligned on the surface; Freeze holds
                // the canvases, not the pattern: the pattern stays live and the held frame returns when it is switched off
                guard offset + 256 <= uniforms.length else { return }
                let mesh = plan.patternMesh
                var u = MappedUniforms()
                u.size = SIMD2(Float(region.size.width), Float(region.size.height))
                u.intensity = intensity
                u.flags = (plan.warpField != nil ? 1 : 0) | (fixture.raw ? 4 : 0) | (plan.blendMap == nil ? 8 : 0)
                u.pattern = UInt32(pattern.rawValue)
                u.index = UInt32(plan.index)
                u.color = plan.color
                (uniforms.contents() + offset).assumingMemoryBound(to: MappedUniforms.self).pointee = u
                encoder.setRenderPipelineState(context.mappedPipeline)
                encoder.setVertexSamplerState(context.linearSampler, index: 0)
                encoder.setFragmentSamplerState(context.linearSampler, index: 0)
                encoder.setFragmentTexture(canvas, index: 0)
                encoder.setFragmentTexture(canvas, index: 1)
                encoder.setFragmentTexture(plan.blendMap ?? canvas, index: 2)
                encoder.setVertexTexture(plan.warpField ?? canvas, index: 0)
                encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
                encoder.setVertexBuffer(uniforms, offset: offset, index: 1)
                encoder.setFragmentBuffer(uniforms, offset: offset, index: 1)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
                offset += 256
                continue
            }
            encoder.setRenderPipelineState(context.mappedPipeline)
            encoder.setVertexSamplerState(context.linearSampler, index: 0)
            encoder.setFragmentSamplerState(context.linearSampler, index: 0)
            encoder.setFragmentTexture(plan.blendMap ?? canvas, index: 2)
            encoder.setVertexTexture(plan.warpField ?? canvas, index: 0)
            for slice in plan.slices {
                guard offset + 256 <= uniforms.length else { return }
                let frozen = fixture.control == .freeze ? plan.held[slice.canvas] : nil
                guard let source = frozen ?? lookup(slice.canvas) else { continue }  // removed canvas: black (the coordinator logs it)
                encoder.setFragmentTexture(source, index: 0)
                var u = MappedUniforms()
                u.size = SIMD2(Float(region.size.width), Float(region.size.height))
                u.intensity = content
                u.scale = contentScale(master: master, heldMaster: frozen == nil ? nil : plan.heldMaster)
                u.opacity = slice.opacity
                u.color = plan.color
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
