// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import LanthornCore
import Logging
import Metal
import QuartzCore
import simd
import Synchronization

/// Render-side state of one layer; touched only by the compositor thread.
public final class RenderLayer {
    public let index: Int  // 0-based layer slot
    public let source: MovieSource
    public let decoder: LayerDecoder
    public let ring: FrameRing
    var clock = LayerClock()
    var currentShown = -1
    var previousShown = -1
    var retriggerLatched = false
    var holdFrame: DecodedFrame?

    public init(index: Int, source: MovieSource, decoder: LayerDecoder, ring: FrameRing) {
        self.index = index
        self.source = source
        self.decoder = decoder
        self.ring = ring
    }

    /// Picks the ring frame for `index`, releasing frames that are no longer
    /// needed. The previously shown frame is kept one tick for the GPU.
    func select(index: Int, direction: Int) -> DecodedFrame? {
        let n = source.info.frameCount
        func behind(_ f: Int) -> Int { direction > 0 ? (index - f + n) % n : (f - index + n) % n }
        while ring.count > 1, let head = ring.peek(0), let next = ring.peek(1) {
            if head.frameIndex == previousShown || head.frameIndex == currentShown { break }
            if behind(next.frameIndex) <= behind(head.frameIndex) { ring.pop() } else { break }
        }
        guard ring.count > 0 else { return holdFrame }
        var best: DecodedFrame?
        for i in 0..<min(ring.count, 3) {
            guard let f = ring.peek(i) else { break }
            if best == nil || behind(f.frameIndex) < behind(best!.frameIndex) { best = f }
        }
        guard let best, behind(best.frameIndex) < ring.capacity + 2 else {
            ring.drain()  // everything buffered is on the wrong side of a seek
            return holdFrame
        }
        if best.frameIndex != currentShown {
            previousShown = currentShown
            currentShown = best.frameIndex
        }
        holdFrame = best
        return best
    }
}

/// Composites all layers of one canvas and, when a drawable is given, runs the
/// output pass (DESIGN.md §4.3–4.5). Allocation-free in steady state.
public final class Compositor: @unchecked Sendable {
    public let context: MetalContext
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let fps: Double
    public let metrics: MetricsRing
    public let parameters: TripleBuffer<ParameterSnapshotSlot>
    public private(set) var layers: [RenderLayer] = []

    private let canvases: [MTLTexture]
    private let canvasPasses: [MTLRenderPassDescriptor]
    private let outputPass = MTLRenderPassDescriptor()
    private let uniformBuffers: [MTLBuffer]
    private static let uniformStride = 256
    private let maxLayers: Int
    private var canvasIndex = 0
    private var lastTarget = 0.0
    private var lastSequence: UInt64 = 0
    private let logger: Logger
    public let ticks = Atomic<Int>(0)
    public let encoderFailures = Atomic<Int>(0)
    public let completed = Atomic<Int>(0)
    public let gpuErrors = Atomic<Int>(0)
    public let outputEncoderFailures = Atomic<Int>(0)
    nonisolated(unsafe) public var lastGPUError: String = ""

    public init(
        context: MetalContext, canvasWidth: Int, canvasHeight: Int, fps: Double, maxLayers: Int, metrics: MetricsRing,
        parameters: TripleBuffer<ParameterSnapshotSlot>, logger: Logger
    ) throws {
        self.context = context
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.fps = fps
        self.maxLayers = maxLayers
        self.metrics = metrics
        self.parameters = parameters
        self.logger = logger
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.canvasFormat, width: canvasWidth, height: canvasHeight, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        canvases = try (0..<3).map { i in
            guard let texture = context.device.makeTexture(descriptor: descriptor) else { throw RenderError.pipeline("canvas texture") }
            texture.label = "canvas \(i)"
            return texture
        }
        canvasPasses = canvases.map { texture in
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            return pass
        }
        outputPass.colorAttachments[0].loadAction = .dontCare
        outputPass.colorAttachments[0].storeAction = .store
        uniformBuffers = try (0..<3).map { _ in
            guard let buffer = context.device.makeBuffer(length: Self.uniformStride * maxLayers, options: .storageModeShared) else { throw RenderError.pipeline("uniforms") }
            return buffer
        }
    }

    public func setLayers(_ layers: [RenderLayer]) { self.layers = Array(layers.prefix(maxLayers)) }

    /// The canvas completed by the previous tick (for previews and other outputs).
    public var latestCanvas: MTLTexture { canvases[(canvasIndex + 2) % 3] }

    /// One compositor tick. `target` is the target presentation time (host seconds).
    public func tick(target: Double, drawable: CAMetalDrawable?) {
        ticks.wrappingAdd(1, ordering: .relaxed)
        let cpuStart = CACurrentMediaTime()
        var record = FrameRecord()
        record.target = target
        let interval = 1 / fps
        let dt: Double
        if lastTarget > 0 {
            let ticks = ((target - lastTarget) / interval).rounded()
            record.missed = UInt16(max(0, min(65535, ticks - 1)))
            dt = target - lastTarget
        } else {
            dt = interval
        }
        lastTarget = target

        let snapshot = parameters.read()
        if snapshot.sequence != lastSequence {
            lastSequence = snapshot.sequence
            if snapshot.receivedAt > 0 { record.dmxToPhotonMicros = UInt32(max(0, min(4e9, (target - snapshot.receivedAt) * 1e6))) }
        }

        guard let commandBuffer = context.queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: canvasPasses[canvasIndex])
        else {
            encoderFailures.wrappingAdd(1, ordering: .relaxed)
            return
        }
        encoder.label = "canvas"
        encoder.setRenderPipelineState(context.layerPipeline)
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)
        encoder.setFragmentSamplerState(context.nearestSampler, index: 1)
        let uniforms = uniformBuffers[canvasIndex]
        let base = uniforms.contents()
        var drawn: UInt16 = 0
        var misses: UInt16 = 0
        for layer in layers {
            let p = layer.index < snapshot.layers.count ? snapshot.layers[layer.index] : LayerParameters()
            let info = layer.source.info
            let last = info.frameCount - 1
            let inFrame = Int((p.inPoint * Float(last)).rounded())
            let outFrame = Int((p.outPoint * Float(last)).rounded())
            if p.retrigger && !layer.retriggerLatched {
                layer.clock.retrigger(mode: p.playMode, inFrame: inFrame, outFrame: outFrame, frameCount: info.frameCount)
            }
            layer.retriggerLatched = p.retrigger
            let frameIndex = layer.clock.advance(
                dt: dt, fps: info.frameRate, speed: Double(p.speed) * 100, mode: p.playMode, inFrame: inFrame, outFrame: outFrame,
                frameCount: info.frameCount)
            let direction = (p.playMode.isReverse ? -1 : 1) * (layer.clock.direction < 0 ? -1 : 1)
            guard let frameIndex else { continue }
            layer.decoder.request(frame: frameIndex, direction: direction)
            guard p.intensity > 0 else { continue }
            guard let frame = layer.select(index: frameIndex, direction: direction), let texture0 = frame.texture0 else {
                misses += 1
                continue
            }
            let pointer = (base + layer.index * Self.uniformStride).assumingMemoryBound(to: LayerUniforms.self)
            pointer.pointee = LayerUniforms(
                transform: Self.transform(for: p, mediaWidth: info.width, mediaHeight: info.height, canvasWidth: canvasWidth, canvasHeight: canvasHeight),
                intensity: p.intensity * snapshot.master, kind: frame.kind.rawValue, textureWidth: Float(info.width))
            encoder.setVertexBuffer(uniforms, offset: layer.index * Self.uniformStride, index: 0)
            encoder.setFragmentBuffer(uniforms, offset: layer.index * Self.uniformStride, index: 0)
            encoder.setFragmentTexture(texture0, index: 0)
            encoder.setFragmentTexture(frame.texture1 ?? texture0, index: 1)
            encoder.setFragmentTexture(frame.texture2 ?? texture0, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            drawn += 1
        }
        encoder.endEncoding()

        if let drawable {
            outputPass.colorAttachments[0].texture = drawable.texture
            if let output = commandBuffer.makeRenderCommandEncoder(descriptor: outputPass) {
                output.label = "output"
                output.setRenderPipelineState(context.outputPipeline)
                output.setFragmentTexture(canvases[canvasIndex], index: 0)
                output.setFragmentSamplerState(context.linearSampler, index: 0)
                output.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                output.endEncoding()
            } else {
                outputEncoderFailures.wrappingAdd(1, ordering: .relaxed)
            }
            commandBuffer.present(drawable)
        }

        record.layersDrawn = drawn
        record.textureMisses = misses
        record.cpuMicros = UInt32((CACurrentMediaTime() - cpuStart) * 1e6)
        let slot = metrics.write(record)
        let metrics = self.metrics
        commandBuffer.addCompletedHandler { [self] buffer in
            completed.wrappingAdd(1, ordering: .relaxed)
            if buffer.status == .error {
                gpuErrors.wrappingAdd(1, ordering: .relaxed)
                lastGPUError = "\(buffer.error.map { "\($0)" } ?? "unknown")"
            }
            metrics.complete(slot: slot, gpuMicros: UInt32(max(0, (buffer.gpuEndTime - buffer.gpuStartTime) * 1e6)), late: buffer.gpuEndTime > target)
        }
        commandBuffer.commit()
        canvasIndex = (canvasIndex + 1) % 3
    }

    /// Unit quad → clip space: fit the media into the canvas, then scale, rotate (in pixel space) and translate.
    static func transform(for p: LayerParameters, mediaWidth: Int, mediaHeight: Int, canvasWidth: Int, canvasHeight: Int) -> simd_float4x4 {
        let mediaAspect = Float(mediaWidth) / Float(max(1, mediaHeight))
        let canvasAspect = Float(canvasWidth) / Float(max(1, canvasHeight))
        var fitW: Float = 1, fitH: Float = 1
        if mediaAspect > canvasAspect { fitH = canvasAspect / mediaAspect } else { fitW = mediaAspect / canvasAspect }
        let sx = fitW * p.scaleX, sy = fitH * p.scaleY
        let c = cos(p.rotationZ), s = sin(p.rotationZ)
        // rotation in pixel space: A⁻¹ R A with A = diag(aspect, 1)
        let r = simd_float4x4(
            SIMD4(c, s * canvasAspect, 0, 0), SIMD4(-s / canvasAspect, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
        let scale = simd_float4x4(diagonal: SIMD4(sx, sy, 1, 1))
        var translate = matrix_identity_float4x4
        translate.columns.3 = SIMD4(p.positionX * 2, p.positionY * 2, 0, 1)
        return translate * r * scale
    }
}
