// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import CoreVideo
import FanousCore
import Foundation
import ImageIO
import Metal
import QuartzCore
import Synchronization

/// Live per-layer thumbnails (DESIGN.md §11.3, B29). Every 250 ms, only while a `thumbs` subscriber or a CITP layer
/// stream wants them, `Compositor.drawThumbnails` draws each visible layer alone into its 160-px cell of one atlas on
/// the tick's command buffer (right after the canvas pass); the atlas is copied into a pooled BGRA pixel buffer (no
/// readback) and on this streamer's own utility queue one JPEG per layer is cut from its cell. A frame goes out only
/// when a layer's JPEG changed (a still layer costs one frame); a new subscriber, or one whose frame was dropped, gets
/// the whole set with the next pass. One producer for all; while a set is being encoded the next pass is skipped.
public final class ThumbnailStreamer: @unchecked Sendable {
    struct Thumb: Equatable {
        var jpeg: [UInt8]
        var width: Int
        var height: Int
    }

    struct Subscriber {
        var connection: StateServer.Connection
        var stream: UInt32
        var key: Key { Key(connection: ObjectIdentifier(connection), stream: stream) }
    }

    struct Key: Hashable {
        var connection: ObjectIdentifier
        var stream: UInt32
    }

    private let context: MetalContext
    private weak var compositor: Compositor?
    private let queue = DispatchQueue(label: "org.fanous.preview.thumbnails", qos: .utility)
    private let subscribers = Mutex<[Subscriber]>([])
    /// Per layer (0-based) for CITP: the latest JPEG, black at the layer's cell size while it shows nothing.
    private let latest = Mutex<[Thumb]>([])
    /// Set by the CITP server: true while a console streams a layer.
    nonisolated(unsafe) public var externalWanted: (@Sendable () -> Bool)?
    /// Tests: produce without subscribers.
    nonisolated(unsafe) var alwaysEncode = false
    /// Atlas passes drawn (`/metrics` `preview.thumbnailPasses`): stays put while nobody watches.
    public let passes = Atomic<Int>(0)
    public let skipped = Atomic<Int>(0)
    /// Microseconds the last set took to encode (all its JPEGs), `/metrics` `preview.thumbnailEncodeMs`.
    public let encodeMicros = Atomic<Int>(0)
    /// A set is on its way to (or being cut on) the queue: the next pass is skipped, so buffers never pile up.
    private let encoding = Atomic<Bool>(false)
    /// Tests: every published set (nil = the layer shows nothing).
    nonisolated(unsafe) var onPublish: (([Thumb?]) -> Void)?

    // render thread
    private let atlasPass = MTLRenderPassDescriptor()
    private let copyPass = MTLRenderPassDescriptor()
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var atlasTexture: MTLTexture?
    private let textureCache: CVMetalTextureCache
    /// The pass whose GPU work is committed but not yet booked (B109, the B105 pattern: `book` polls its status each
    /// tick instead of a completion handler). One entry: `encoding` already keeps one set in flight.
    private var pending: (buffer: MTLCommandBuffer, pixelBuffer: CVPixelBuffer, texture: CVMetalTexture, cells: [ThumbnailAtlas.Cell?], shapes: [(width: Int, height: Int)])?

    // thumbnail queue
    private var sent: [Thumb?] = []
    /// Subscribers that get the whole set with the next pass: new ones, and those a frame could not be queued for.
    private var stale = Set<Key>()
    private var black: [Int: Thumb] = [:]

    public init(context: MetalContext, compositor: Compositor) throws {
        self.context = context
        self.compositor = compositor
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, context.device, nil, &cache) == kCVReturnSuccess, let cache else { throw RenderError.pipeline("thumbnail texture cache") }
        textureCache = cache
        atlasPass.colorAttachments[0].loadAction = .clear
        atlasPass.colorAttachments[0].storeAction = .store
        atlasPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        copyPass.colorAttachments[0].loadAction = .dontCare
        copyPass.colorAttachments[0].storeAction = .store
    }

    // MARK: Subscribers

    public var hasSubscribers: Bool { subscribers.withLock { !$0.isEmpty } }
    public var wantsFrames: Bool { alwaysEncode || hasSubscribers || externalWanted?() == true }
    /// Compositor thread: thumbnails are wanted and this tick is a pass tick (the compositor needs pixels only then).
    var wantsPass: Bool { wantsFrames && isPassTick && !encoding.load(ordering: .relaxed) }

    private var isPassTick: Bool {
        guard let compositor else { return false }
        return compositor.ticks.load(ordering: .relaxed) % ThumbnailAtlas.everyNth(fps: compositor.fps) == 0
    }

    /// Adds a subscriber; it gets the whole current set with the next pass (later frames only carry changes).
    /// `announce` (the `sub` reply) runs under the lock a pass reads the subscribers with: it is queued before the
    /// first frame, and any reader of the subscribers sees the subscriber once the reply is queued (B94). `announce`
    /// must not call back into this streamer: the Mutex is not recursive, so a `hasSubscribers` call in it deadlocks.
    func subscribe(connection: StateServer.Connection, stream: UInt32, announce: () -> Void = {}) {
        let subscriber = Subscriber(connection: connection, stream: stream)
        subscribers.withLock {
            announce()
            $0.append(subscriber)
        }
        queue.async { [self] in stale.insert(subscriber.key) }
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

    /// `PreviewHub.tap`, after the canvas pass: on pass ticks while wanted, the atlas pass and its copy into a pixel buffer.
    func tap(commandBuffer: MTLCommandBuffer) {
        guard let compositor, wantsPass else { return }
        guard !encoding.load(ordering: .relaxed) else {
            skipped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let canvases = compositor.thumbnailCanvases()
        let shapes = canvases.map { (width: $0.width, height: $0.height) }
        guard let layout = ThumbnailAtlas.layout(canvases.map { $0.visible ? ($0.width, $0.height) : nil }) else {
            // nothing visible: no GPU work, every layer reported empty
            encoding.store(true, ordering: .relaxed)
            queue.async { [self] in
                publish(Array(repeating: nil, count: canvases.count), shapes: shapes)
                encoding.store(false, ordering: .relaxed)
            }
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
        var uniforms = OutputUniforms()
        uniforms.size = SIMD2(Float(poolSize.width), Float(poolSize.height))
        encoder.setRenderPipelineState(context.outputPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OutputUniforms>.stride, index: 0)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        passes.wrappingAdd(1, ordering: .relaxed)
        encoding.store(true, ordering: .relaxed)
        pending = (commandBuffer, pixelBuffer, cvTexture, layout.cells, shapes)
    }

    /// `PreviewHub.book`, every tick (also while `encoding` keeps the tap from being called): a finished pass goes to
    /// the thumbnail queue; a failed one is dropped.
    func book() {
        guard let pass = pending, pass.buffer.status == .completed || pass.buffer.status == .error else { return }
        pending = nil
        guard pass.buffer.status == .completed else {
            encoding.store(false, ordering: .relaxed)
            return
        }
        nonisolated(unsafe) let pixelBuffer = pass.pixelBuffer  // the queue is its only user from here on
        let (cells, shapes) = (pass.cells, pass.shapes)
        queue.async { [self] in
            encode(pixelBuffer, cells: cells, shapes: shapes)
            encoding.store(false, ordering: .relaxed)
        }
    }

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
            guard CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary, attributes as CFDictionary, &made) == kCVReturnSuccess else { return nil }
            pool = made
            poolSize = size
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        var texture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, .bgra8Unorm, poolSize.width, poolSize.height, 0, &texture) == kCVReturnSuccess, let texture
        else { return nil }
        return (buffer, texture)
    }

    // MARK: Thumbnail queue

    private func encode(_ pixelBuffer: CVPixelBuffer, cells: [ThumbnailAtlas.Cell?], shapes: [(width: Int, height: Int)]) {
        let start = CACurrentMediaTime()
        // one copy of the atlas into a CGImage (the GPU is done with it), then each cell cropped and encoded by ImageIO
        // (the caller clears `encoding` after this returns, also on this early return)
        guard let atlas = Self.image(of: pixelBuffer) else {
            skipped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let thumbs = cells.map { cell -> Thumb? in
            guard let cell, let image = atlas.cropping(to: CGRect(x: cell.x, y: cell.y, width: cell.width, height: cell.height)) else { return nil }
            return Self.jpeg(image).map { Thumb(jpeg: $0, width: cell.width, height: cell.height) }
        }
        encodeMicros.store(Int((CACurrentMediaTime() - start) * 1e6), ordering: .relaxed)
        publish(thumbs, shapes: shapes)
    }

    /// The BGRA pixel buffer as a CGImage (one copy of its bytes), rows top-down like the atlas.
    static func image(of pixelBuffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer), rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let provider = CGDataProvider(data: Data(bytes: base, count: rowBytes * height) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }

    static func jpeg(_ image: CGImage) -> [UInt8]? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? [UInt8](data as Data) : nil
    }

    /// A black JPEG of a layer's cell size (CITP frames of a layer that shows nothing), made once per size.
    private func black(_ shape: (width: Int, height: Int)) -> Thumb {
        let size = ThumbnailAtlas.cellSize(canvas: shape)
        if let made = black[size.height] { return made }
        let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.setFillColor(gray: 0, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let made = Thumb(jpeg: context?.makeImage().flatMap(Self.jpeg) ?? [], width: size.width, height: size.height)
        black[size.height] = made
        return made
    }

    /// Sends each subscriber the layers whose thumbnail changed since the last set (a layer that went dark: an empty
    /// frame), or the whole set when it is stale; a frame that cannot be queued makes its subscriber stale.
    private func publish(_ thumbs: [Thumb?], shapes: [(width: Int, height: Int)]) {
        let citp = thumbs.indices.map { thumbs[$0] ?? black(shapes[$0]) }
        latest.withLock { $0 = citp }
        onPublish?(thumbs)
        let subs = subscribers.withLock { $0 }
        stale.formIntersection(subs.map(\.key))
        for s in subs {
            let whole = stale.contains(s.key)
            // ponytail: a stale subscriber gets layers 1…n in fixed order every pass; a whole set larger than the
            // 256 KB send queue (32 layers on a portrait canvas) never gets the high layers through. Upgrade: stop at
            // the first refused frame and remember per subscriber where to resume.
            var delivered = true
            for (i, thumb) in thumbs.enumerated() where whole || i >= sent.count || sent[i] != thumb {
                let payload = ThumbnailAtlas.frame(layer: i + 1, width: thumb?.width ?? 0, height: thumb?.height ?? 0, jpeg: thumb?.jpeg ?? [])
                if !s.connection.send(stream: s.stream, kind: .jpeg, payload: payload) { delivered = false }
            }
            if delivered { stale.remove(s.key) } else { stale.insert(s.key) }
        }
        sent = thumbs
    }
}
