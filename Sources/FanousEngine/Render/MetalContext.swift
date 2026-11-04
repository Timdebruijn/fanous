// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import simd

/// Mirrors `LayerUniforms` in Shaders.swift (natural alignment, 196 bytes, stride 208).
public struct LayerUniforms {
    public var transform: simd_float4x4 = matrix_identity_float4x4
    public var quadRect: SIMD4<Float> = SIMD4(-1, -1, 1, 1)
    public var uvRect: SIMD4<Float> = SIMD4(0, 0, 1, 1)
    public var colour: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    public var adjust: SIMD4<Float> = SIMD4(0, 1, 1, 0)
    public var effect1: SIMD4<Float> = .zero
    public var effect2: SIMD4<Float> = .zero
    public var texel: SIMD4<Float> = SIMD4(0, 0, 1, 0)
    public var kind: UInt32 = 0
    public var blend: UInt32 = 0
    public var master: Float = 1
    public var deep: UInt32 = 0  // 1 when the planes are 16-bit textures: video-range levels at 16-bit scale (B119)
    /// The mip level the blur taps read from the layer's scratch texture (B2); 0 for the source itself.
    public var lod: Float = 0

    public init() {}
}

/// Mirrors `OutputUniforms` in Shaders.swift.
public struct OutputUniforms {
    public var size: SIMD2<Float> = .zero
    public var pattern: UInt32 = 0
    public var index: UInt32 = 1
    public init() {}
}

public enum RenderError: Error, CustomStringConvertible {
    case noDevice
    case shader(String)
    case pipeline(String)

    public var description: String {
        switch self {
        case .noDevice: "no Metal device"
        case .shader(let s): "shader compile failed: \(s)"
        case .pipeline(let s): "pipeline failed: \(s)"
        }
    }
}

/// Device, queue, compiled shaders and pipeline states shared by all render threads.
public final class MetalContext: @unchecked Sendable {
    public static let canvasFormat: MTLPixelFormat = .rgba16Float
    public static let outputFormat: MTLPixelFormat = .bgra8Unorm

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let library: MTLLibrary
    /// Index = (blur ? 1 : 0) | (edge ? 2 : 0): the neighbourhood effects are function-constant specialisations.
    let layerPipelines: [MTLRenderPipelineState]
    let outputPipeline: MTLRenderPipelineState
    /// Slice mesh with warp, mask and blend map (DESIGN.md §9.5); slices alpha-blend over each other.
    let mappedPipeline: MTLRenderPipelineState
    /// The edit overlay's lines (DESIGN.md §9.10 item 4), opaque over the slices.
    let overlayPipeline: MTLRenderPipelineState
    let generatorPipeline: MTLRenderPipelineState
    /// Source conversion alone into a layer's scratch texture, before the canvas pass (DESIGN.md §4.3, B2).
    let convertPipeline: MTLRenderPipelineState
    /// One scratch mip level from the one above (B2).
    let downsamplePipeline: MTLComputePipelineState
    let linearSampler: MTLSamplerState
    let nearestSampler: MTLSamplerState
    /// Linear with a linear mip filter: the blur taps read the scratch texture at a level matched to the radius (B2).
    let mipSampler: MTLSamplerState

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.device = device
        self.queue = queue
        queue.label = "org.fanous.render"
        let options = MTLCompileOptions()
        options.mathMode = .fast
        do {
            library = try device.makeLibrary(source: ShaderSource.metal, options: options)
        } catch {
            throw RenderError.shader("\(error)")
        }
        var layers: [MTLRenderPipelineDescriptor] = []
        // bit 0 blur, bit 1 edge, bit 2 the draw reads its scratch texture (B2): eight pipelines, built once at start
        for variant in 0..<8 {
            let layer = MTLRenderPipelineDescriptor()
            layer.label = "layer\(variant & 1 != 0 ? "+blur" : "")\(variant & 2 != 0 ? "+edge" : "")\(variant & 4 != 0 ? "+scratch" : "")"
            let constants = MTLFunctionConstantValues()
            var hasBlur = variant & 1 != 0, hasEdge = variant & 2 != 0, tapsFromScratch = variant & 4 != 0
            constants.setConstantValue(&hasBlur, type: .bool, index: 0)
            constants.setConstantValue(&hasEdge, type: .bool, index: 1)
            constants.setConstantValue(&tapsFromScratch, type: .bool, index: 2)
            layer.vertexFunction = library.makeFunction(name: "layer_vertex")
            do {
                layer.fragmentFunction = try library.makeFunction(name: "layer_fragment", constantValues: constants)
            } catch {
                throw RenderError.shader("\(error)")
            }
            layer.colorAttachments[0].pixelFormat = Self.canvasFormat
            // blending happens in the fragment shader (framebuffer fetch), see Shaders.swift
            layer.colorAttachments[0].isBlendingEnabled = false
            layers.append(layer)
        }
        let describe = { [library] (label: String, vertex: String, fragment: String, format: MTLPixelFormat) in
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = label
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return descriptor
        }
        let output = describe("output", "output_vertex", "output_fragment", Self.outputFormat)
        let generator = describe("generator", "output_vertex", "generator_fragment", .bgra8Unorm)
        let mapped = describe("mapped output", "mapped_vertex", "mapped_fragment", Self.outputFormat)
        mapped.colorAttachments[0].isBlendingEnabled = true  // one, one-minus-source-alpha (add and one are the defaults)
        mapped.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        mapped.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let convert = describe("scratch convert", "output_vertex", "convert_fragment", Self.canvasFormat)
        let overlay = describe("edit overlay", "overlay_vertex", "overlay_fragment", Self.outputFormat)
        do {
            layerPipelines = try layers.map { try device.makeRenderPipelineState(descriptor: $0) }
            outputPipeline = try device.makeRenderPipelineState(descriptor: output)
            mappedPipeline = try device.makeRenderPipelineState(descriptor: mapped)
            overlayPipeline = try device.makeRenderPipelineState(descriptor: overlay)
            generatorPipeline = try device.makeRenderPipelineState(descriptor: generator)
            convertPipeline = try device.makeRenderPipelineState(descriptor: convert)
            guard let downsample = library.makeFunction(name: "downsample") else { throw RenderError.shader("downsample") }
            downsamplePipeline = try device.makeComputePipelineState(function: downsample)
        } catch {
            throw RenderError.pipeline("\(error)")
        }
        // both clamp to edge; nearest filtering is the default
        let linear = MTLSamplerDescriptor()
        linear.minFilter = .linear
        linear.magFilter = .linear
        let nearest = MTLSamplerDescriptor()
        let mip = MTLSamplerDescriptor()
        mip.minFilter = .linear
        mip.magFilter = .linear
        mip.mipFilter = .linear
        guard let linearSampler = device.makeSamplerState(descriptor: linear), let nearestSampler = device.makeSamplerState(descriptor: nearest),
            let mipSampler = device.makeSamplerState(descriptor: mip)
        else {
            throw RenderError.pipeline("samplers")
        }
        self.linearSampler = linearSampler
        self.nearestSampler = nearestSampler
        self.mipSampler = mipSampler
    }

    public var deviceName: String { device.name }
}
