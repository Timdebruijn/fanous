// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import simd

public struct LayerUniforms {
    public var transform: simd_float4x4
    public var intensity: Float
    public var kind: UInt32
    public var textureWidth: Float
    public var padding: Float = 0

    public init(transform: simd_float4x4, intensity: Float, kind: UInt32, textureWidth: Float) {
        self.transform = transform
        self.intensity = intensity
        self.kind = kind
        self.textureWidth = textureWidth
    }
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
    let layerPipeline: MTLRenderPipelineState
    let outputPipeline: MTLRenderPipelineState
    let linearSampler: MTLSamplerState
    let nearestSampler: MTLSamplerState

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.device = device
        self.queue = queue
        queue.label = "org.lanthorn.render"
        let options = MTLCompileOptions()
        options.mathMode = .fast
        do {
            library = try device.makeLibrary(source: ShaderSource.metal, options: options)
        } catch {
            throw RenderError.shader("\(error)")
        }
        let layer = MTLRenderPipelineDescriptor()
        layer.label = "layer"
        layer.vertexFunction = library.makeFunction(name: "layer_vertex")
        layer.fragmentFunction = library.makeFunction(name: "layer_fragment")
        layer.colorAttachments[0].pixelFormat = Self.canvasFormat
        layer.colorAttachments[0].isBlendingEnabled = true
        layer.colorAttachments[0].rgbBlendOperation = .add
        layer.colorAttachments[0].alphaBlendOperation = .add
        layer.colorAttachments[0].sourceRGBBlendFactor = .one
        layer.colorAttachments[0].sourceAlphaBlendFactor = .one
        layer.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        layer.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let output = MTLRenderPipelineDescriptor()
        output.label = "output"
        output.vertexFunction = library.makeFunction(name: "output_vertex")
        output.fragmentFunction = library.makeFunction(name: "output_fragment")
        output.colorAttachments[0].pixelFormat = Self.outputFormat
        do {
            layerPipeline = try device.makeRenderPipelineState(descriptor: layer)
            outputPipeline = try device.makeRenderPipelineState(descriptor: output)
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
