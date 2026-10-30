// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import simd

/// Mirrors `LayerUniforms` in Shaders.swift (natural alignment, 192 bytes).
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
    public var pad1: UInt32 = 0

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
    let generatorPipeline: MTLRenderPipelineState
    let linearSampler: MTLSamplerState
    let nearestSampler: MTLSamplerState

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
        for variant in 0..<4 {
            let layer = MTLRenderPipelineDescriptor()
            layer.label = "layer\(variant & 1 != 0 ? "+blur" : "")\(variant & 2 != 0 ? "+edge" : "")"
            let constants = MTLFunctionConstantValues()
            var hasBlur = variant & 1 != 0, hasEdge = variant & 2 != 0
            constants.setConstantValue(&hasBlur, type: .bool, index: 0)
            constants.setConstantValue(&hasEdge, type: .bool, index: 1)
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
        let output = MTLRenderPipelineDescriptor()
        output.label = "output"
        output.vertexFunction = library.makeFunction(name: "output_vertex")
        output.fragmentFunction = library.makeFunction(name: "output_fragment")
        output.colorAttachments[0].pixelFormat = Self.outputFormat
        let generator = MTLRenderPipelineDescriptor()
        generator.label = "generator"
        generator.vertexFunction = library.makeFunction(name: "output_vertex")
        generator.fragmentFunction = library.makeFunction(name: "generator_fragment")
        generator.colorAttachments[0].pixelFormat = .bgra8Unorm
        let mapped = MTLRenderPipelineDescriptor()
        mapped.label = "mapped output"
        mapped.vertexFunction = library.makeFunction(name: "mapped_vertex")
        mapped.fragmentFunction = library.makeFunction(name: "mapped_fragment")
        mapped.colorAttachments[0].pixelFormat = Self.outputFormat
        mapped.colorAttachments[0].isBlendingEnabled = true
        mapped.colorAttachments[0].rgbBlendOperation = .add
        mapped.colorAttachments[0].alphaBlendOperation = .add
        mapped.colorAttachments[0].sourceRGBBlendFactor = .one
        mapped.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        mapped.colorAttachments[0].sourceAlphaBlendFactor = .one
        mapped.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            layerPipelines = try layers.map { try device.makeRenderPipelineState(descriptor: $0) }
            outputPipeline = try device.makeRenderPipelineState(descriptor: output)
            mappedPipeline = try device.makeRenderPipelineState(descriptor: mapped)
            generatorPipeline = try device.makeRenderPipelineState(descriptor: generator)
        } catch {
            throw RenderError.pipeline("\(error)")
        }
        let linear = MTLSamplerDescriptor()
        linear.minFilter = .linear
        linear.magFilter = .linear
        linear.sAddressMode = .clampToEdge
        linear.tAddressMode = .clampToEdge
        let nearest = MTLSamplerDescriptor()
        nearest.minFilter = .nearest
        nearest.magFilter = .nearest
        nearest.sAddressMode = .clampToEdge
        nearest.tAddressMode = .clampToEdge
        guard let linearSampler = device.makeSamplerState(descriptor: linear), let nearestSampler = device.makeSamplerState(descriptor: nearest) else {
            throw RenderError.pipeline("samplers")
        }
        self.linearSampler = linearSampler
        self.nearestSampler = nearestSampler
    }

    public var deviceName: String { device.name }
}
