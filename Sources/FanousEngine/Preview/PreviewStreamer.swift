// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import FanousCore
import Logging
import Metal
import Synchronization
import VideoToolbox

/// Canvas preview for browsers (DESIGN.md §11.3, ADR-0014): every N-th compositor tick the canvas (or one output,
/// or one layer alone) is drawn through the output pass into a small BGRA `CVPixelBuffer` from a Metal-compatible pool (no
/// readback), encoded on the preview queue as H.264 (Baseline, no B-frames, 1 s GOP) for WebCodecs, or as
/// JPEG at 5 fps for clients without WebCodecs. One encoder, shared by every subscriber.
/// One streamer per (target, size class): `PreviewHub`.
public final class PreviewStreamer: @unchecked Sendable {
    public struct Subscriber: Sendable {
        public var connection: StateServer.Connection
        public var stream: UInt32
        public var jpeg: Bool
    }

    public let width: Int
    public let height: Int
    public let fps: Double
    /// The canvas this streamer shows ("canvas:<id>" targets); output streamers sample canvas 1 here and the others
    /// through `tap`'s lookup.
    public var canvasID = 1
    /// When set, the preview shows this output (post-warp/blend) instead of the canvas; compiled for the preview size.
    nonisolated(unsafe) public var outputSet: OutputSet?
    /// Target "layer:<n>": the 0-based layer this preview shows alone (`showLayer`); nil = canvas or output.
    public private(set) var layer: Int?
    private weak var layerCompositor: Compositor?
    private let layerPass = MTLRenderPassDescriptor()
    private var layerUniforms: MTLBuffer?
    private var layerRing = 0
    private let parameters: TripleBuffer<ParameterSnapshotSlot>
    private let mappedUniforms: MTLBuffer
    private let context: MetalContext
    private let logger: Logger
    private let queue = DispatchQueue(label: "org.fanous.preview", qos: .utility)
    private let subscribers = Mutex<[Subscriber]>([])
    private var pool: CVPixelBufferPool?
    private var textureCache: CVMetalTextureCache?
    /// Preview queue: the H.264 session, made on the first H.264 consumer and released with the last (B66).
    private var session: VTCompressionSession?
    /// Preview queue: a session is being made (`ensureSession`).
    private var creating = false
    /// Preview queue: creations started, so a late "not ready" timer names only its own.
    private var creations = 0
    /// Preview queue: the last attempt failed; frames do not retry it, a new H.264 subscriber does.
    private var sessionFailed = false
    private let uniforms: MTLBuffer
    private let pass = MTLRenderPassDescriptor()
    private var tickCounter = 0
    private let everyNth: Int
    /// Tap interval while only JPEG consumers (5 fps) are listening: the GPU copy is throttled too, not just the encode.
    private let jpegEveryNth: Int
    private var avcC: [UInt8] = []
    private var lastJPEG = 0.0
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    public let framesIn = Atomic<Int>(0)
    public let framesOut = Atomic<Int>(0)
    public let skipped = Atomic<Int>(0)
    /// The latest JPEG (bytes, width, height) for CITP streaming frames; produced at 5 fps while anyone wants it.
    public let latestJPEG = Mutex<([UInt8], Int, Int)?>(nil)
    /// Set by the CITP server while a console streams; nil = only WebSocket JPEG subscribers count.
    nonisolated(unsafe) public var externalJPEGWanted: (@Sendable () -> Bool)?
    /// Tests: every delivered H.264 access unit with the current avcC.
    nonisolated(unsafe) var onFrame: (([UInt8], [UInt8]) -> Void)?
    /// Tests: encode even without subscribers.
    nonisolated(unsafe) var alwaysEncode = false

    public init(context: MetalContext, width: Int, height: Int, fps: Double, canvasFPS: Double, parameters: TripleBuffer<ParameterSnapshotSlot>, logger: Logger) throws {
        self.context = context
        self.parameters = parameters
        guard let mapped = context.device.makeBuffer(length: Compositor.mappedUniformsLength, options: .storageModeShared) else { throw RenderError.pipeline("preview mapped uniforms") }
        mappedUniforms = mapped
        self.width = width & ~1
        self.height = height & ~1
        self.fps = fps
        self.logger = logger
        everyNth = max(1, Int((canvasFPS / fps).rounded()))
        jpegEveryNth = max(1, Int((canvasFPS / 5).rounded()))
        guard let uniforms = context.device.makeBuffer(length: 256, options: .storageModeShared) else { throw RenderError.pipeline("preview uniforms") }
        self.uniforms = uniforms
        uniforms.contents().assumingMemoryBound(to: OutputUniforms.self).pointee = {
            var o = OutputUniforms()
            o.size = SIMD2(Float(self.width), Float(self.height))
            return o
        }()
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: self.width, kCVPixelBufferHeightKey: self.height,
            kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool
        else { throw RenderError.pipeline("preview pixel buffer pool") }
        self.pool = pool
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, context.device, nil, &cache) == kCVReturnSuccess, let cache else { throw RenderError.pipeline("preview texture cache") }
        textureCache = cache
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    /// Shows layer `index` (0-based) alone instead of the canvas: each preview frame `Compositor.drawLayer` renders it
    /// into a canvas-format texture at the preview size, which then goes through the same downscale and encode as the
    /// canvas. Called before the streamer is published (the hub's `configure`).
    public func showLayer(_ index: Int, of compositor: Compositor) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.canvasFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = context.device.makeTexture(descriptor: descriptor),
            let uniforms = context.device.makeBuffer(length: Compositor.uniformStride * 6, options: .storageModeShared)
        else { throw RenderError.pipeline("layer preview texture") }
        texture.label = "layer preview"
        layerPass.colorAttachments[0].texture = texture
        layerPass.colorAttachments[0].loadAction = .clear
        layerPass.colorAttachments[0].storeAction = .store
        layerPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        layerUniforms = uniforms
        layerCompositor = compositor
        layer = index
    }

    /// The layer picture of the last preview frame (tests).
    var layerTexture: MTLTexture? { layerPass.colorAttachments[0].texture }

    // MARK: Subscribers

    public var hasSubscribers: Bool { subscribers.withLock { !$0.isEmpty } }
    var subscriberList: [Subscriber] { subscribers.withLock { $0 } }
    private var wantsH264: Bool { alwaysEncode || subscribers.withLock { $0.contains { !$0.jpeg } } }
    /// Anyone who needs canvas frames: a WebSocket subscriber or a CITP console that streams.
    public var wantsFrames: Bool { alwaysEncode || hasSubscribers || externalJPEGWanted?() == true }

    /// Adds a subscriber; H.264 clients get the `stream` description (avcC) right away when one exists, else with the
    /// first frame of the session their subscription starts making.
    public func subscribe(_ subscriber: Subscriber) {
        subscribers.withLock { $0.append(subscriber) }
        if !subscriber.jpeg {
            queue.async { [self] in
                sessionFailed = false  // a new viewer tries again
                ensureSession()
                if session != nil, !avcC.isEmpty { sendDescription(to: [subscriber]) }
            }
        }
    }

    public func unsubscribe(connection: StateServer.Connection, stream: UInt32) {
        subscribers.withLock { $0.removeAll { $0.connection === connection && $0.stream == stream } }
        queue.async { [self] in releaseSessionIfUnwanted() }
    }

    public func remove(connection: StateServer.Connection) {
        subscribers.withLock { $0.removeAll { $0.connection === connection } }
        queue.async { [self] in releaseSessionIfUnwanted() }
    }

    // MARK: Compositor thread

    /// `Compositor.previewTap`: encodes the downscale into the tick's command buffer when a frame is due.
    /// `canvases` looks up the other canvases of this tick (outputs whose slices use them).
    public func tap(canvas: MTLTexture, commandBuffer: MTLCommandBuffer, target: Double, canvases: ((Int) -> MTLTexture?)? = nil) {
        tickCounter &+= 1
        guard wantsFrames, tickCounter % (wantsH264 ? everyNth : jpegEveryNth) == 0, let pool, let textureCache else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else {
            skipped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture) == kCVReturnSuccess,
            let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture)
        else {
            skipped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        var canvas = canvas
        if let layer {
            guard let compositor = layerCompositor, let layerUniforms, let layerTexture,
                compositor.drawLayer(layer, into: layerPass, uniforms: layerUniforms, ring: layerRing, commandBuffer: commandBuffer)
            else {
                skipped.wrappingAdd(1, ordering: .relaxed)
                return
            }
            layerRing = (layerRing + 1) % 3
            canvas = layerTexture
        }
        pass.colorAttachments[0].texture = texture
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            skipped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        encoder.label = "preview"
        if let set = outputSet {
            // same thread as the compositor tick, so reading the parameter slot here is the reader's own slot
            let snapshot = parameters.read()
            OutputPass.draw(
                set, canvas: { $0 == canvasID ? canvas : canvases?($0) }, encoder: encoder, context: context, uniforms: mappedUniforms,
                master: snapshot.masterControl == .blackout ? 0 : snapshot.master, masterPattern: snapshot.testPattern, outputs: snapshot.outputs)
        } else {
            encoder.setRenderPipelineState(context.outputPipeline)
            encoder.setFragmentBuffer(uniforms, offset: 0, index: 0)
            encoder.setFragmentTexture(canvas, index: 0)
            encoder.setFragmentSamplerState(context.linearSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        framesIn.wrappingAdd(1, ordering: .relaxed)
        let keep = cvTexture  // the CVMetalTexture must outlive the GPU work
        commandBuffer.addCompletedHandler { [self] buffer in
            _ = keep
            guard buffer.status == .completed else { return }
            queue.async { [self] in encode(pixelBuffer, target: target) }
        }
    }

    // MARK: Preview queue

    /// Tests: the H.264 session exists.
    var hasEncoder: Bool { queue.sync { session != nil } }

    /// Preview queue: starts making the H.264 session, off this queue. B66: on CI's macOS VM `VTCompressionSessionCreate`
    /// sometimes never returned when it ran in `init` at engine start; made here it holds neither engine start nor
    /// this streamer's JPEG frames, and H.264 frames are skipped until it is in.
    private func ensureSession() {
        guard session == nil, !creating, wantsH264 else { return }
        creating = true
        creations &+= 1
        let mine = creations
        let started = Date()
        let (width, height, fps, queue) = (width, height, fps, queue)
        let size = "\(width)x\(height)"
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, creating, creations == mine else { return }
            logger.warning("preview encoder not ready after 5 s", metadata: ["size": "\(size)"])
        }
        // the streamer is not captured: a create that never returns pins one thread, not the streamer's buffers
        DispatchQueue.global(qos: .utility).async { [weak self] in
            nonisolated(unsafe) let result = Result { try Self.makeSession(width: width, height: height, fps: fps) }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            guard self != nil else {
                if case .success(let made) = result { VTCompressionSessionInvalidate(made) }
                return
            }
            queue.async { [weak self] in
                guard let self else {
                    if case .success(let made) = result { VTCompressionSessionInvalidate(made) }
                    return
                }
                creating = false
                switch result {
                case .success(let made) where wantsH264:
                    session = made
                    // a frame of a released session can deliver after the release and leave its avcC here; this
                    // session's parameter sets may be byte-identical, so without a reset no description would go out
                    avcC = []
                    logger.info("preview encoder ready", metadata: ["size": "\(size)", "ms": "\(ms)"])
                case .success(let made):
                    VTCompressionSessionInvalidate(made)  // its viewers left meanwhile
                case .failure(let error):
                    // viewers fall back to JPEG when no `stream` description arrives (Preview.svelte)
                    sessionFailed = true
                    logger.warning("preview encoder failed", metadata: ["size": "\(size)", "ms": "\(ms)", "error": "\(error)"])
                }
            }
        }
    }

    /// Preview queue: the session, or nil while there is none (this frame has no H.264; a missing one is started).
    private func readySession() -> VTCompressionSession? {
        if !sessionFailed { ensureSession() }
        return session
    }

    /// Preview queue: the last H.264 viewer left, so the session goes (the canvas streamer lives as long as the engine).
    private func releaseSessionIfUnwanted() {
        guard let session, !wantsH264 else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
        avcC = []  // the next session's first frame sends its description
        logger.info("preview encoder released", metadata: ["size": "\(width)x\(height)"])
    }

    /// Any thread.
    private static func makeSession(width: Int, height: Int, fps: Double) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw RenderError.pipeline("VTCompressionSession \(status)") }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Int(fps) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
        // 1.5 Mbit/s at 640×360 (DESIGN.md §11.3); the other size classes in proportion to their pixels, 0.5–4 Mbit/s
        let bitRate = min(4_000_000, max(500_000, 1_500_000 * width * height / (640 * 360)))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, target: Double) {
        let (h264, jpeg) = subscribers.withLock { subs in (subs.filter { !$0.jpeg }, subs.filter { $0.jpeg }) }
        if !jpeg.isEmpty || externalJPEGWanted?() == true, target - lastJPEG >= 0.18 {  // taps come every 0.2 s when only JPEG listens
            lastJPEG = target
            if let data = ciContext.jpegRepresentation(of: CIImage(cvPixelBuffer: pixelBuffer), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]) {
                let bytes = Array(data)
                latestJPEG.withLock { $0 = (bytes, width, height) }
                for s in jpeg { _ = s.connection.send(stream: s.stream, kind: .jpeg, payload: bytes) }
            }
        }
        guard !h264.isEmpty || alwaysEncode, let session = readySession() else { return }
        let pts = CMTime(value: Int64(target * 1_000_000), timescale: 1_000_000)
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid, frameProperties: nil, infoFlagsOut: nil) {
            [self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else {
                skipped.wrappingAdd(1, ordering: .relaxed)
                return
            }
            deliver(sampleBuffer, target: target)
        }
        if status != noErr { skipped.wrappingAdd(1, ordering: .relaxed) }
    }

    /// Output callback (VideoToolbox's own thread): avcC on change, then the access unit as a binary frame.
    private func deliver(_ sampleBuffer: CMSampleBuffer, target: Double) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer), let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let record = Self.avcC(from: format)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var payload = [UInt8](repeating: 0, count: 9)
        payload[0] = key ? 1 : 0
        let micros = UInt64(max(0, target * 1_000_000))
        for i in 0..<8 { payload[1 + i] = UInt8((micros >> (8 * (7 - i))) & 0xFF) }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        payload.reserveCapacity(9 + length)
        payload.append(contentsOf: [UInt8](repeating: 0, count: length))
        payload.withUnsafeMutableBufferPointer { CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: $0.baseAddress! + 9) }
        queue.async { [self] in
            let subs = subscribers.withLock { $0.filter { !$0.jpeg } }
            if !record.isEmpty, record != avcC {
                avcC = record
                sendDescription(to: subs)
            }
            framesOut.wrappingAdd(1, ordering: .relaxed)
            onFrame?(payload, avcC)
            for s in subs { _ = s.connection.send(stream: s.stream, kind: .h264, payload: payload) }
        }
    }

    private func sendDescription(to subs: [Subscriber]) {
        let message: JSONValue = [
            // profile, constraints and level as encoded (the larger size classes are above level 3.0)
            "t": "stream", "codec": .string(String(format: "avc1.%02X%02X%02X", avcC[1], avcC[2], avcC[3])), "description": .string(Data(avcC).base64EncodedString()),
            "w": .number(Double(width)), "h": .number(Double(height)), "fps": .number(fps),
        ]
        for s in subs {
            var object = message.object ?? [:]
            object["id"] = .number(Double(s.stream))
            _ = s.connection.send(text: JSONValue.encodeCompact(.object(object)), droppable: false)
        }
    }

    /// AVCDecoderConfigurationRecord from the H.264 parameter sets (one SPS, one PPS).
    static func avcC(from format: CMFormatDescription) -> [UInt8] {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr,
            count >= 2
        else { return [] }
        var sets: [[UInt8]] = []
        for i in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                let pointer
            else { return [] }
            sets.append(Array(UnsafeBufferPointer(start: pointer, count: size)))
        }
        let sps = sets[0], pps = sets[1]
        guard sps.count >= 4 else { return [] }
        var record: [UInt8] = [1, sps[1], sps[2], sps[3], 0xFF, 0xE1, UInt8(sps.count >> 8), UInt8(sps.count & 0xFF)]
        record += sps
        record += [1, UInt8(pps.count >> 8), UInt8(pps.count & 0xFF)]
        record += pps
        return record
    }
}

extension JSONValue {
    /// One-line JSON for protocol messages built outside the store.
    static func encodeCompact(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
