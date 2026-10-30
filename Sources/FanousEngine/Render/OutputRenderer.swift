// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import Foundation
import FanousCore
import Logging
import Metal
import simd
import Synchronization

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
    /// The Keystone homography after the warp (`ParameterSnapshotSlot.keystones`); the identity in raw.
    var keystone = matrix_identity_float3x3
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

/// What a mapping preset changes on an output (DESIGN.md §9.10 item 3): its warp field and slices, masks included.
struct PresetGeometry {
    let warpField: MTLTexture?
    let slices: [SlicePlan]
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
    /// The output's mapping presets by number, each through the compile cache; the blend map, colour and region are the
    /// output's own, shared by every preset.
    let presets: [Int: PresetGeometry]
    /// Every canvas the edited mapping or a preset samples: what Freeze holds, so a preset change while frozen keeps the frame.
    let canvases: [Int]
    /// Canvas copies (by canvas id) taken when the Output fixture's Control engaged Freeze; the content pass samples them
    /// instead of the live canvases. Only touched by the one thread that renders this plan's set.
    nonisolated(unsafe) var held: [Int: MTLTexture] = [:]
    /// The Master intensity `held` was drawn with (the canvas carries it); same thread as `held`.
    nonisolated(unsafe) var heldMaster: Float = 1

    init(
        id: Int, index: Int, region: MTLRegion, intensity: Float, testPattern: TestPattern, color: SIMD4<Float>, blendMap: MTLTexture?, warpField: MTLTexture?,
        slices: [SlicePlan], patternMesh: SlicePlan, presets: [Int: PresetGeometry] = [:]
    ) {
        self.patternMesh = patternMesh
        self.presets = presets
        var canvases: [Int] = []
        for slice in slices + presets.values.flatMap(\.slices) where !canvases.contains(slice.canvas) { canvases.append(slice.canvas) }
        self.canvases = canvases
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

    /// What to draw for `preset` (the snapshot's `presets`): that preset's geometry, else (0, or a number this output
    /// does not have) the edited mapping. No allocation: a dictionary lookup and a struct of references.
    func geometry(_ preset: UInt8) -> PresetGeometry { presets[Int(preset)] ?? PresetGeometry(warpField: warpField, slices: slices) }
}

/// The plans of one display, swapped into the compositor as one reference.
public final class OutputSet: @unchecked Sendable {
    public let plans: [OutputPlan]
    /// The set this one replaces, whose Freeze holds its plans take over (`OutputPass.adopt`, B111); the thread that
    /// renders this set takes and clears it. Pass `holdSource` of the replaced set, so the chain stays one set long.
    let previous: Mutex<OutputSet?>
    public init(plans: [OutputPlan], previous: OutputSet? = nil) {
        self.plans = plans
        self.previous = Mutex(previous)
    }

    /// Where a set replacing this one takes its holds from: the set this one replaces while this one has not rendered
    /// (it holds nothing yet, and drops out instead of keeping every later edit's set alive), else this one.
    public var holdSource: OutputSet { previous.withLock { $0 } ?? self }
}

/// Compiles `OutputConfig` into textures and meshes (edit-time cost only, DESIGN.md §9.2–9.4). Keep one per caller:
/// its cache (§9.10 item 0) makes a recompile rebuild only the textures and slice meshes whose settings or size changed.
public final class OutputCompiler: @unchecked Sendable {
    public static let sliceSubdivisions = 64
    public static let fieldDivisor = 4
    private let device: MTLDevice

    /// What a texture or slice plan is made of; a changed region, display mode or drawable size gives new keys.
    enum Key: Hashable {
        case blend(BlendSettings, width: Int, height: Int)
        case warp(WarpSettings, cols: Int, rows: Int)
        case mask(MaskSettings, width: Int, height: Int)
        /// A slice's mesh buffers with its mask texture, which is also cached on its own: a moved slice keeps its raster.
        case slice(SliceConfig, width: Int, height: Int)
    }
    private struct Entry: @unchecked Sendable { weak var object: AnyObject? }  // textures and slice plans are immutable once compiled
    /// Held weakly: a texture or slice plan lives exactly as long as a plan holds it (every display's set, the set a frozen
    /// output still takes its hold from, B111, a preview's), so nothing in use is freed and one no plan uses goes when the
    /// set that held it is swapped out; its dead entry is dropped at the next compile. Edit-time only, never touched by the
    /// render thread; the lock is for the previews, which compile from the main actor, the network and a utility queue.
    private let cache = Mutex<[Key: Entry]>([:])
    /// Says once per output and preset number that a preset was skipped (it does not validate or compile).
    private let logger: Logger?
    private let reported = Mutex<Set<[Int]>>([])

    public init(device: MTLDevice, logger: Logger? = nil) {
        self.device = device
        self.logger = logger
    }

    /// Cache entries, a dead one until the next compile drops it (tests).
    var entries: Int { cache.withLock { $0.count } }

    /// The texture or slice plan for `key`: the one a live plan already holds, else `make`'s.
    private func cached<T: AnyObject>(_ key: Key, _ make: () throws -> T) rethrows -> T {
        if let hit = cache.withLock({ $0[key]?.object as? T }) { return hit }
        // ponytail: no lock over `make` (it would queue every preview compile behind the slowest): two threads missing one
        // key both build it, both correct, the later stays cached; track builds in flight per key if that waste shows
        let made = try make()
        cache.withLock { $0[key] = Entry(object: made) }
        return made
    }

    /// `drawable` is the size of the display's drawable in pixels; a nil region covers it entirely.
    public func compile(_ config: OutputConfig, index: Int, drawable: (width: Int, height: Int)) throws -> OutputPlan {
        cache.withLock { entries in entries = entries.filter { $0.value.object != nil } }
        let r = config.region ?? PixelRect(x: 0, y: 0, w: drawable.width, h: drawable.height)
        let x = min(max(0, r.x), max(0, drawable.width - 1)), y = min(max(0, r.y), max(0, drawable.height - 1))
        let w = max(1, min(r.w, drawable.width - x)), h = max(1, min(r.h, drawable.height - y))
        let region = MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0), size: MTLSize(width: w, height: h, depth: 1))

        var blendMap: MTLTexture? = nil
        if !config.blend.isIdentity {
            blendMap = try cached(.blend(config.blend, width: w, height: h)) {
                let map = BlendMath.map(config.blend, width: w, height: h).map { Float16($0) }
                return try texture(.rgba16Float, width: w, height: h, bytesPerPixel: 8, label: "blend \(config.id)") { map.withUnsafeBytes { $0.baseAddress! } }
            }
        }
        // the whole output as a slice without a mask: canvas 1, opacity 1
        let patternMesh = try slicePlan(SliceConfig(id: 0), output: config.id, width: w, height: h)
        let edited = try geometry(config.warp, config.slices, output: config.id, width: w, height: h)
        // presets as a hand-edited or foreign file may have them (`ProjectDocument.load` cleans numbers and repeats): numbers
        // 1…255, the first of each number, and only one that validates as an edited mapping would and compiles. One that
        // does not is skipped and said once; it never fails the output
        var presets: [Int: PresetGeometry] = [:], seen = Set<Int>()
        for preset in config.presets where MappingPreset.numbers.contains(preset.number) && seen.insert(preset.number).inserted {
            do {
                let valid = try ProjectDocument.validated(preset)
                presets[preset.number] = try geometry(valid.warp, valid.slices, output: config.id, width: w, height: h)
            } catch {
                if reported.withLock({ $0.insert([config.id, preset.number]).inserted }) {
                    logger?.warning("mapping preset skipped", metadata: ["output": "\(config.id)", "preset": "\(preset.number)", "error": "\(error)"])
                }
            }
        }
        let gain = config.color.gain.count == 3 ? config.color.gain.map(Float.init) : [1, 1, 1]
        return OutputPlan(
            id: config.id, index: index, region: region, intensity: Float(config.intensity), testPattern: TestPattern(rawValue: config.testPattern) ?? .off,
            color: SIMD4(gain[0], gain[1], gain[2], Float(config.color.black)), blendMap: blendMap, warpField: edited.warpField, slices: edited.slices,
            patternMesh: patternMesh, presets: presets)
    }

    /// A mapping's warp field and slices on a w × h output: the edited one or a preset's, textures through the cache.
    private func geometry(_ warp: WarpSettings, _ configs: [SliceConfig], output id: Int, width w: Int, height h: Int) throws -> PresetGeometry {
        var warpField: MTLTexture? = nil
        if !warp.isIdentity {
            let cols = max(2, w / Self.fieldDivisor), rows = max(2, h / Self.fieldDivisor)
            warpField = try cached(.warp(warp, cols: cols, rows: rows)) {
                let field = WarpMath.field(warp, cols: cols, rows: rows)
                return try texture(.rg32Float, width: cols, height: rows, bytesPerPixel: 8, label: "warp \(id)") { field.withUnsafeBytes { $0.baseAddress! } }
            }
        }
        return PresetGeometry(warpField: warpField, slices: try configs.map { try slicePlan($0, output: id, width: w, height: h) })
    }

    /// A slice's tessellated mesh and mask texture on a w × h output, through the cache: a rebind (every drag step) builds
    /// only the slices that changed, the edited mapping's and every preset's.
    private func slicePlan(_ slice: SliceConfig, output id: Int, width w: Int, height h: Int) throws -> SlicePlan {
        try cached(.slice(slice, width: w, height: h)) {
            let (vertices, indices) = SliceMesh.build(slice, subdivisions: Self.sliceSubdivisions)
            guard !vertices.isEmpty,
                let vertexBuffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SliceMesh.Vertex>.stride, options: .storageModeShared),
                let indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared)
            else { throw RenderError.pipeline("slice mesh \(slice.id)") }
            vertexBuffer.label = "slice \(id).\(slice.id)"
            var mask: MTLTexture? = nil
            // keyed by the mask alone: moving the slice keeps its raster
            if let m = slice.mask, m.path.count >= 3 {
                mask = try cached(.mask(m, width: w, height: h)) {
                    if m.feather >= 2 {
                        // signed-distance feather on a coarser grid (the field is smooth); 1080p with an 8 px feather → 480×270
                        let raster = MaskMath.raster(m, width: w, height: h, step: min(4, Int(m.feather / 2)))
                        return try texture(.r8Unorm, width: raster.width, height: raster.height, bytesPerPixel: 1, label: "mask \(id).\(slice.id)") { raster.bytes.withUnsafeBytes { $0.baseAddress! } }
                    }
                    // hard edge: CoreGraphics fills the polygon pixel-exactly at full resolution
                    let raster = Self.fill(m.path, width: w, height: h)
                    return try texture(.r8Unorm, width: w, height: h, bytesPerPixel: 1, label: "mask \(id).\(slice.id)") { raster.withUnsafeBytes { $0.baseAddress! } }
                }
            }
            return SlicePlan(vertices: vertexBuffer, indices: indexBuffer, indexCount: indices.count, mask: mask, opacity: Float(slice.opacity), canvas: slice.canvas)
        }
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

    /// Output Control = Freeze: keeps a copy of the canvases its slices and presets use from the moment Freeze engaged, released
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
            for id in plan.canvases {
                guard let source = canvas(id) else { continue }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat, width: source.width, height: source.height, mipmapped: false)
                descriptor.usage = .shaderRead
                descriptor.storageMode = .private
                guard let copy = buffer.device.makeTexture(descriptor: descriptor), let blit = buffer.makeBlitCommandEncoder() else { continue }
                copy.label = "frozen output \(plan.id) canvas \(id)"
                blit.copy(from: source, to: copy)
                blit.endEncoding()
                held[id] = copy
            }
            plan.held = held
            plan.heldMaster = master
        }
    }

    /// An edit recompiles the plans while Freeze is engaged (B111): once, on the thread that renders `set`, each frozen
    /// plan takes the hold of the plan with its id in the set it replaced, if those copies cover the canvases its slices
    /// and presets sample at their sizes (a canvas resize blanks the outputs anyway, B59; otherwise it holds afresh); then the
    /// replaced set is released. Not on MainActor: `held` is written by the render thread while the edit runs.
    static func adopt(_ set: OutputSet, canvas: (Int) -> MTLTexture?, outputs: [OutputParameters]) {
        guard let previous = set.previous.withLock({ p -> OutputSet? in
            defer { p = nil }
            return p
        }) else { return }
        adopt(previous, canvas: canvas, outputs: outputs)  // a replaced set that never rendered takes its own first
        for plan in set.plans where plan.held.isEmpty && fixture(for: plan, in: outputs).control == .freeze {
            guard let old = previous.plans.first(where: { $0.id == plan.id }),
                plan.canvases.allSatisfy({ id in
                    guard let live = canvas(id) else { return true }  // not rendering: `holdFrozen` holds nothing of it either
                    return old.held[id].map { $0.width == live.width && $0.height == live.height } ?? false
                })
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
    /// `keystones` and `presets` (the mapping preset each output shows, 0 = as edited) by output index like `outputs`;
    /// the previews pass none: they show the mapping as edited (§9.10 item 3).
    static func draw(
        _ set: OutputSet, canvas lookup: (Int) -> MTLTexture?, encoder: MTLRenderCommandEncoder, context: MetalContext, uniforms: MTLBuffer,
        master: Float, masterPattern: TestPattern, outputs: [OutputParameters], keystones: [simd_float3x3], presets: [UInt8]
    ) {
        // bound to texture slots the shader does not sample in this draw (patterns, no blend map, no warp, no mask)
        guard let canvas = lookup(1) else { return }
        var offset = 0
        for plan in set.plans {
            let fixture = fixture(for: plan, in: outputs)
            // raw bypasses the keystone with the warp
            let keystone = !fixture.raw && plan.index >= 1 && plan.index - 1 < keystones.count ? keystones[plan.index - 1] : matrix_identity_float3x3
            // the preset's warp and slices; the blend map, colour and the keystone on top are the output's
            let geometry = plan.geometry(plan.index >= 1 && plan.index - 1 < presets.count ? presets[plan.index - 1] : 0)
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
                u.flags = (geometry.warpField != nil ? 1 : 0) | (fixture.raw ? 4 : 0) | (plan.blendMap == nil ? 8 : 0)
                u.pattern = UInt32(pattern.rawValue)
                u.index = UInt32(plan.index)
                u.color = plan.color
                u.keystone = keystone
                (uniforms.contents() + offset).assumingMemoryBound(to: MappedUniforms.self).pointee = u
                encoder.setRenderPipelineState(context.mappedPipeline)
                encoder.setVertexSamplerState(context.linearSampler, index: 0)
                encoder.setFragmentSamplerState(context.linearSampler, index: 0)
                encoder.setFragmentTexture(canvas, index: 0)
                encoder.setFragmentTexture(canvas, index: 1)
                encoder.setFragmentTexture(plan.blendMap ?? canvas, index: 2)
                encoder.setVertexTexture(geometry.warpField ?? canvas, index: 0)
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
            encoder.setVertexTexture(geometry.warpField ?? canvas, index: 0)
            for slice in geometry.slices {
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
                u.keystone = keystone
                u.flags = (geometry.warpField != nil ? 1 : 0) | (slice.mask != nil ? 2 : 0) | (fixture.raw ? 4 : 0) | (plan.blendMap == nil ? 8 : 0)
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
