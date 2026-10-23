// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreVideo
import Foundation
import simd
import LanthornEngine
import Logging
import Metal

/// Phase 2 spike (DESIGN.md §19): which pixel formats the hardware decoder
/// delivers, whether they are IOSurface-backed, and how long decodes take.
enum DecodeSpike {
    static func run(file: URL, frames: Int, logger: Logger) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MovieError.decoder(-1) }
        if CommandLine.arguments.contains("--native") { MovieSource.requestAlphaFor4444 = false }
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        Task.detached {
            do { box.source = try await MovieSource.open(url: file, device: device, poolSize: 4) } catch { box.error = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error { throw error }
        let source = box.source!
        print("file: \(file.lastPathComponent)")
        print("codec: \(source.info.codecName)  \(source.info.width)x\(source.info.height) @ \(source.info.frameRate) fps, \(source.info.frameCount) frames, HAP: \(source.info.isHAP)")
        let slot = DecodedFrame(poolIndex: 0)
        var nanos: [UInt64] = []
        var counterOK = 0
        let total = min(frames, source.info.frameCount)
        for index in 0..<total {
            try source.decode(frame: index, into: slot)
            nanos.append(slot.decodeNanos)
            if index == 0 {
                print("kind: \(slot.kind)  pixel format: \(fourCCString(source.lastPixelFormat))  IOSurface-backed: \(source.lastSurfaceBacked)")
                if let t = slot.texture0 { print("texture0: \(t.pixelFormat) \(t.width)x\(t.height) storage \(t.storageMode.rawValue)") }
                if let t = slot.texture1 { print("texture1: \(t.pixelFormat) \(t.width)x\(t.height)") }
            }
            if let counter = readCounter(slot, device: device), counter == index { counterOK += 1 }
        }
        // random access: last frame, then the first again
        try source.decode(frame: source.info.frameCount - 1, into: slot)
        let seekBack = slot.decodeNanos
        try source.decode(frame: 0, into: slot)
        let sorted = nanos.sorted()
        func ms(_ n: UInt64) -> String { String(format: "%.2f", Double(n) / 1e6) }
        print("decode ms: p50 \(ms(sorted[sorted.count / 2]))  p99 \(ms(sorted[Int(Double(sorted.count - 1) * 0.99)]))  max \(ms(sorted.last!))  seek-to-last \(ms(seekBack))")
        print("frame counter readback via GPU (ProRes luma plane / HAP luma): \(counterOK)/\(total) frames verified")
    }

    final class Box: @unchecked Sendable {
        var source: MovieSource?
        var error: Error?
    }

    /// Renders the decoded frame through the real layer pipeline into an 8-bit
    /// target and reads the 16-bit counter squares back: validates decode and
    /// shader conversion for every source kind (lossless-compressed planes included).
    static func readCounter(_ slot: DecodedFrame, device: MTLDevice) -> Int? {
        guard let texture0 = slot.texture0 else { return nil }
        let context = try? spikeContext(device)
        guard let context else { return nil }
        let width = texture0.width == slot.pixelBuffer.map({ CVPixelBufferGetWidth($0) / 2 }) ? texture0.width * 2 : texture0.width
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1024, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let buffer = device.makeBuffer(length: 256, options: .storageModeShared) else { return nil }
        // map the top-left 1024×64 pixels of the frame onto the whole target
        let scaleX = Float(width) / 1024, scaleY = Float(texture0.height) / 64
        var uniforms = LayerUniforms(transform: simd_float4x4(diagonal: SIMD4(scaleX, scaleY, 1, 1)), intensity: 1, kind: slot.kind.rawValue, textureWidth: Float(width))
        uniforms.transform.columns.3 = SIMD4(scaleX - 1, 1 - scaleY, 0, 1)
        memcpy(buffer.contents(), &uniforms, MemoryLayout<LayerUniforms>.size)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let commandBuffer = context.queue.makeCommandBuffer(), let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(context.spikePipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(texture0, index: 0)
        encoder.setFragmentTexture(slot.texture1 ?? texture0, index: 1)
        encoder.setFragmentTexture(slot.texture2 ?? texture0, index: 2)
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)
        encoder.setFragmentSamplerState(context.nearestSampler, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var row = [UInt8](repeating: 0, count: 1024 * 4)
        target.getBytes(&row, bytesPerRow: 1024 * 4, from: MTLRegionMake2D(0, 16, 1024, 1), mipmapLevel: 0)
        var value = 0
        for i in 0..<16 where row[(i * 32 + 16) * 4 + 1] > 127 { value |= 1 << (15 - i) }
        return value
    }

    nonisolated(unsafe) static var cachedContext: SpikeContext?

    final class SpikeContext {
        let queue: MTLCommandQueue
        let spikePipeline: MTLRenderPipelineState
        let linearSampler: MTLSamplerState
        let nearestSampler: MTLSamplerState
        init(queue: MTLCommandQueue, spikePipeline: MTLRenderPipelineState, linearSampler: MTLSamplerState, nearestSampler: MTLSamplerState) {
            self.queue = queue
            self.spikePipeline = spikePipeline
            self.linearSampler = linearSampler
            self.nearestSampler = nearestSampler
        }
    }

    static func spikeContext(_ device: MTLDevice) throws -> SpikeContext {
        if let cachedContext { return cachedContext }
        let library = try device.makeLibrary(source: ShaderSource.metal, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "layer_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "layer_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        let nearest = MTLSamplerDescriptor()
        let context = SpikeContext(
            queue: device.makeCommandQueue()!, spikePipeline: try device.makeRenderPipelineState(descriptor: descriptor),
            linearSampler: device.makeSamplerState(descriptor: sampler)!, nearestSampler: device.makeSamplerState(descriptor: nearest)!)
        cachedContext = context
        return context
    }
}
