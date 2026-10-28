// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreImage
import CoreVideo
import FanousCore
import Foundation
import Metal
import Synchronization

/// Live per-layer thumbnails (DESIGN.md §11.3, B29). Every 250 ms, only while a `thumbs` subscriber or a CITP layer
/// stream wants them, `Compositor.drawThumbnails` draws each visible layer alone into its 160-px cell of one atlas on
/// the tick's command buffer (right after the canvas pass); the atlas is copied into a pooled BGRA pixel buffer (no
/// readback) and on the preview queue one JPEG per layer is cut from its cell. A frame goes out only when a layer's
/// JPEG changed (a still layer costs one frame); a new subscriber gets the current set first. One producer for all.
public final class ThumbnailStreamer: @unchecked Sendable {
    struct Thumb: Equatable {
        var jpeg: [UInt8]
        var width: Int
        var height: Int
    }

    struct Subscriber {
        var connection: StateServer.Connection
        var stream: UInt32
    }

    private let context: MetalContext
    private weak var compositor: Compositor?
    private let queue = DispatchQueue(label: "org.fanous.preview.thumbnails", qos: .utility)
    private let subscribers = Mutex<[Subscriber]>([])
    /// Per layer (0-based) for CITP: the latest JPEG, black for a layer that shows nothing.
    private let latest = Mutex<[Thumb]>([])
    /// Set by the CITP server: true while a console streams a layer.
    nonisolated(unsafe) public var externalWanted: (@Sendable () -> Bool)?
    /// Tests: produce without subscribers.
    nonisolated(unsafe) var alwaysEncode = false
    /// Atlas passes drawn (`/metrics` `preview.thumbnailPasses`): stays put while nobody watches.
    public let passes = Atomic<Int>(0)
    public let skipped = Atomic<Int>(0)
    /// Tests: every published set (nil = the layer shows nothing).
    nonisolated(unsafe) var onPublish: (([Thumb?]) -> Void)?

    // render thread
    private var tickCounter = 0
    private let atlasPass = MTLRenderPassDescriptor()
    private let copyPass = MTLRenderPassDescriptor()
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private let textureCache: CVMetalTextureCache
    private let copyUniforms: MTLBuffer

    // preview queue
    private var sent: [Thumb?] = []
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private lazy var black: Thumb = {
        let image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: ThumbnailAtlas.cellWidth, height: 90))
        return Thumb(jpeg: jpeg(image) ?? [], width: ThumbnailAtlas.cellWidth, height: 90)
    }()

    public init(context: MetalContext, compositor: Compositor) throws {
        self.context = context
        self.compositor = compositor
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, context.device, nil, &cache) == kCVReturnSuccess, let cache else { throw RenderError.pipeline("thumbnail texture cache") }
        textureCache = cache
        guard let uniforms = context.device.makeBuffer(length: 256, options: .storageModeShared) else { throw RenderError.pipeline("thumbnail uniforms") }
        copyUniforms = uniforms
        atlasPass.colorAttachments[0].loadAction = .clear
        atlasPass.colorAttachments[0].storeAction = .store
        atlasPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        copyPass.colorAttachments[0].loadAction = .dontCare
        copyPass.colorAttachments[0].storeAction = .store
    }

    // MARK: Subscribers

    public var hasSubscribers: Bool { subscribers.withLock { !$0.isEmpty } }
    public var wantsFrames: Bool { alwaysEncode || hasSubscribers || externalWanted?() == true }

    /// Adds a subscriber; it gets the current thumbnails right away (later frames only carry changes).
    func subscribe(connection: StateServer.Connection, stream: UInt32) {
        let subscriber = Subscriber(connection: connection, stream: stream)
        subscribers.withLock { $0.append(subscriber) }
        queue.async { [self] in
            for (i, thumb) in sent.enumerated() { send(i, thumb, to: [subscriber]) }
        }
    }

    func unsubscribe(connection: StateServer.Connection, stream: UInt32) {
        subscribers.withLock { $0.removeAll { $0.connection === connection && $0.stream == stream } }
    }

    func remove(connection: StateServer.Connection) {
        subscribers.withLock { $0.removeAll { $0.connection === connection } }
    }

    /// CITP streaming frame of layer `index` (0-based): its latest JPEG (black while it shows nothing), nil before the
    /// first atlas pass or beyond the render layers.
    public func jpeg(layer index: Int) -> ([UInt8], Int, Int)? {
        latest.withLock { index >= 0 && index < $0.count ? ($0[index].jpeg, $0[index].width, $0[index].height) : nil }
    }

    // MARK: Compositor thread

    /// `PreviewHub.tap`, after the canvas pass: every 250 ms while wanted, the atlas pass and its copy into a pixel buffer.
    func tap(commandBuffer: MTLCommandBuffer) {
        guard let compositor else { return }
        tickCounter &+= 1
        guard wantsFrames, tickCounter % ThumbnailAtlas.everyNth(fps: compositor.fps) == 0 else { return }
        let canvases = compositor.thumbnailCanvases()
        guard let layout = ThumbnailAtlas.layout(canvases) else {
            // nothing visible: no GPU work, every layer reported empty
            queue.async { [self] in publish(Array(repeating: nil, count: canvases.count)) }
            return
        }
        guard let (pixelBuffer, cvTexture) = pixelBuffer(width: layout.width, height: layout.height), let target = CVMetalTextureGetTexture(cvTexture),
            let atlas = atlas(width: poolSize.width, height: poolSize.height)
        else {
            skipped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        atlasPass.colorAttachments[0].texture = atlas
        guard compositor.drawThumbnails(layout.cells, into: atlasPass, commandBuffer: commandBuffer) else {
            skipped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        copyPass.colorAttachments[0].texture = target
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: copyPass) else {
            skipped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        encoder.label = "thumbnail copy"
        encoder.setRenderPipelineState(context.outputPipeline)
        encoder.setFragmentBuffer(copyUniforms, offset: 0, index: 0)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        passes.wrappingAdd(1, ordering: .relaxed)
        let cells = layout.cells
        commandBuffer.addCompletedHandler { [self] buffer in
            _ = cvTexture  // the CVMetalTexture must outlive the GPU work
            guard buffer.status == .completed else { return }
            queue.async { [self] in encode(pixelBuffer, cells: cells) }
        }
    }

    private var atlasTexture: MTLTexture?

    /// The atlas (canvas format: the layer pipelines draw into it) at the pool's size.
    private func atlas(width: Int, height: Int) -> MTLTexture? {
        if let atlasTexture, atlasTexture.width == width, atlasTexture.height == height { return atlasTexture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.canvasFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        atlasTexture = context.device.makeTexture(descriptor: descriptor)
        atlasTexture?.label = "thumbnail atlas"
        return atlasTexture
    }

    /// A pooled BGRA buffer at least `width` × `height` (the pool only grows, so a layer appearing on another canvas
    /// does not remake it back and forth) and its Metal view.
    private func pixelBuffer(width: Int, height: Int) -> (CVPixelBuffer, CVMetalTexture)? {
        if pool == nil || width > poolSize.width || height > poolSize.height {
            let size = (width: max(width, poolSize.width), height: max(height, poolSize.height))
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: size.width, kCVPixelBufferHeightKey: size.height,
                kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var made: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attributes as CFDictionary, &made) == kCVReturnSuccess else { return nil }
            pool = made
            poolSize = size
            copyUniforms.contents().assumingMemoryBound(to: OutputUniforms.self).pointee = {
                var o = OutputUniforms()
                o.size = SIMD2(Float(size.width), Float(size.height))
                return o
            }()
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        var texture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, .bgra8Unorm, poolSize.width, poolSize.height, 0, &texture) == kCVReturnSuccess, let texture
        else { return nil }
        return (buffer, texture)
    }

    // MARK: Preview queue

    private func encode(_ pixelBuffer: CVPixelBuffer, cells: [ThumbnailAtlas.Cell?]) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        publish(
            cells.map { cell in
                guard let cell else { return nil }
                // Core Image has its origin at the bottom left, the atlas at the top left
                let rect = CGRect(x: cell.x, y: height - cell.y - cell.height, width: cell.width, height: cell.height)
                return jpeg(image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY)))
                    .map { Thumb(jpeg: $0, width: cell.width, height: cell.height) }
            })
    }

    private func jpeg(_ image: CIImage) -> [UInt8]? {
        ciContext.jpegRepresentation(
            of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]
        ).map(Array.init)
    }

    /// Sends the layers whose thumbnail changed since the last set (a layer that went dark: an empty frame).
    private func publish(_ thumbs: [Thumb?]) {
        latest.withLock { $0 = thumbs.map { $0 ?? black } }
        onPublish?(thumbs)
        let subs = subscribers.withLock { $0 }
        for (i, thumb) in thumbs.enumerated() where i >= sent.count || sent[i] != thumb { send(i, thumb, to: subs) }
        sent = thumbs
    }

    private func send(_ index: Int, _ thumb: Thumb?, to subs: [Subscriber]) {
        guard !subs.isEmpty else { return }
        let payload = ThumbnailAtlas.frame(layer: index + 1, width: thumb?.width ?? 0, height: thumb?.height ?? 0, jpeg: thumb?.jpeg ?? [])
        for s in subs { _ = s.connection.send(stream: s.stream, kind: .jpeg, payload: payload) }
    }
}
