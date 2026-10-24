// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import LanthornCore
import Logging
import Metal
import Synchronization
import VideoToolbox

/// Canvas preview for browsers (DESIGN.md §11.3, ADR-0014): every N-th compositor tick the canvas is
/// drawn through the output pass into a small BGRA `CVPixelBuffer` from a Metal-compatible pool (no
/// readback), encoded on the preview queue as H.264 (Baseline, no B-frames, 1 s GOP) for WebCodecs, or as
/// JPEG at 5 fps for clients without WebCodecs. One encoder, shared by every subscriber.
/// ponytail: one size for all subscribers (the first one's); per-(target,size) encoders when a show needs them.
public final class PreviewStreamer: @unchecked Sendable {
    public struct Subscriber: Sendable {
        public var connection: StateServer.Connection
        public var stream: UInt32
        public var jpeg: Bool
    }

    public let width: Int
    public let height: Int
    public let fps: Double
    /// When set, the preview shows this output (post-warp/blend) instead of the canvas; compiled for the preview size.
    nonisolated(unsafe) public var outputSet: OutputSet?
    private let parameters: TripleBuffer<ParameterSnapshotSlot>
    private let mappedUniforms: MTLBuffer
    private let context: MetalContext
    private let logger: Logger
    private let queue = DispatchQueue(label: "org.lanthorn.preview", qos: .utility)
    private let subscribers = Mutex<[Subscriber]>([])
    private var pool: CVPixelBufferPool?
    private var textureCache: CVMetalTextureCache?
    private var session: VTCompressionSession?
    private let uniforms: MTLBuffer
    private let pass = MTLRenderPassDescriptor()
    private var tickCounter = 0
    private let everyNth: Int
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
        try makeSession()
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    // MARK: Subscribers

    public var hasSubscribers: Bool { subscribers.withLock { !$0.isEmpty } }

    /// Adds a subscriber; H.264 clients get the `stream` description (avcC) right away when one exists.
    public func subscribe(_ subscriber: Subscriber) {
        subscribers.withLock { $0.append(subscriber) }
        if !subscriber.jpeg {
            queue.async { [self] in if !avcC.isEmpty { sendDescription(to: [subscriber]) } }
        }
    }

    public func unsubscribe(connection: StateServer.Connection, stream: UInt32) {
        subscribers.withLock { $0.removeAll { $0.connection === connection && $0.stream == stream } }
    }

    public func remove(connection: StateServer.Connection) {
        subscribers.withLock { $0.removeAll { $0.connection === connection } }
    }

    // MARK: Compositor thread

    /// `Compositor.previewTap`: encodes the downscale into the tick's command buffer when a frame is due.
    public func tap(canvas: MTLTexture, commandBuffer: MTLCommandBuffer, target: Double) {
        tickCounter &+= 1
        guard tickCounter % everyNth == 0, hasSubscribers || alwaysEncode || externalJPEGWanted?() == true, let pool, let textureCache else { return }
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
                set, canvas: canvas, encoder: encoder, context: context, uniforms: mappedUniforms,
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

    private func makeSession() throws {
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
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 1_500_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, target: Double) {
        let (h264, jpeg) = subscribers.withLock { subs in (subs.filter { !$0.jpeg }, subs.filter { $0.jpeg }) }
        if !jpeg.isEmpty || externalJPEGWanted?() == true, target - lastJPEG >= 0.2 {
            lastJPEG = target
            if let data = ciContext.jpegRepresentation(of: CIImage(cvPixelBuffer: pixelBuffer), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]) {
                let bytes = Array(data)
                latestJPEG.withLock { $0 = (bytes, width, height) }
                for s in jpeg { _ = s.connection.send(stream: s.stream, kind: .jpeg, payload: bytes) }
            }
        }
        guard !h264.isEmpty || alwaysEncode, let session else { return }
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
            "t": "stream", "codec": "avc1.42E01E", "description": .string(Data(avcC).base64EncodedString()),
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
