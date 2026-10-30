// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import CHap
import CoreVideo
import Foundation
import IOSurface
import Metal
import VideoToolbox

/// How the layer shader must read a frame's texture(s) (DESIGN.md §4.1, ADR-0005).
public enum SourcePixelKind: UInt32, Sendable {
    case rgba = 0  // stills, BC1/BC3 straight RGBA
    case v216 = 1  // packed 16-bit 4:2:2 (Cb Y0 Cr Y1) as rgba16Unorm at half width, or 8-bit `2vuy` as rgba8Unorm at half width
    case y416 = 2  // packed 16-bit 4:4:4:4 (A Y Cb Cr) as rgba16Unorm
    case hapYCoCg = 3  // HAP Q: scaled YCoCg in a BC3 texture
    case hapAlphaOnly = 4  // BC4 alpha
    case hapYCoCgAlpha = 5  // HAP Q Alpha: BC3 YCoCg + BC4 alpha
    case planarYCbCr = 6  // bi-planar (Y plane r16 or r8, CbCr rg16 or rg8; 4:2:2, 4:4:4 or 4:2:0 (`420v`)), incl. Apple's lossless-compressed variants
    case planarYCbCrA = 7  // as 6 plus an alpha plane (r16)
    case yuy2 = 8  // 8-bit packed 4:2:2 `yuvs` (Y0 Cb Y1 Cr) as rgba8Unorm at half width: `.v216` with the pairs swapped
}

public enum MovieError: Error, CustomStringConvertible {
    case noVideoTrack
    case unsupportedCodec(FourCharCode)
    case decoder(OSStatus)
    case unexpectedPixelFormat(OSType)
    case noSample

    public var description: String {
        switch self {
        case .noVideoTrack: "no video track"
        case .unsupportedCodec(let c): "unsupported codec \(fourCCString(c))"
        case .decoder(let s): "VideoToolbox error \(s)"
        case .unexpectedPixelFormat(let f): "unexpected pixel format \(fourCCString(f))"
        case .noSample: "no sample"
        }
    }
}

/// One slot of a layer's frame ring. Reused forever: no allocation after warm-up.
public final class DecodedFrame {
    public let poolIndex: Int
    public var frameIndex = -1
    public var kind: SourcePixelKind = .rgba
    public var texture0: MTLTexture?
    public var texture1: MTLTexture?
    public var texture2: MTLTexture?
    /// Keeps a VideoToolbox IOSurface alive while the GPU may read it.
    public var pixelBuffer: CVPixelBuffer?
    /// Texture-cache wrappers must outlive the Metal textures they back.
    var metalTextures: (CVMetalTexture?, CVMetalTexture?, CVMetalTexture?) = (nil, nil, nil)
    public var decodeNanos: UInt64 = 0
    /// Row 0 is the bottom of the picture (Syphon surfaces); sampled flipped, see `Compositor.uvRect`.
    public var bottomUp = false

    public init(poolIndex: Int) { self.poolIndex = poolIndex }

    func clear() {
        frameIndex = -1
        texture0 = nil
        texture1 = nil
        texture2 = nil
        pixelBuffer = nil
        metalTextures = (nil, nil, nil)
        bottomUp = false
    }
}

public struct MovieInfo: Sendable {
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let frameCount: Int
    public let codec: FourCharCode
    public var isHAP: Bool { MovieSource.hapCodecs[codec] != nil }
    public var codecName: String { fourCCString(codec) }
}

/// Random-access demux (AVSampleCursor) + decode (VideoToolbox for ProRes,
/// hap.c for HAP) into Metal textures without copies (ADR-0004, ADR-0005).
/// One instance per layer; used from that layer's decode thread only.
public final class MovieSource: @unchecked Sendable {
    static let proResCodecs: Set<FourCharCode> = ["apch", "apcn", "apcs", "apco", "ap4h", "ap4x"].map(makeFourCC).reduce(into: []) { $0.insert($1) }
    static let hapCodecs: [FourCharCode: (format0: MTLPixelFormat, format1: MTLPixelFormat?, kind: SourcePixelKind)] = [
        makeFourCC("Hap1"): (.bc1_rgba, nil, .rgba),
        makeFourCC("Hap5"): (.bc3_rgba, nil, .rgba),
        makeFourCC("HapY"): (.bc3_rgba, nil, .hapYCoCg),
        makeFourCC("HapM"): (.bc3_rgba, .bc4_rUnorm, .hapYCoCgAlpha),
        makeFourCC("HapA"): (.bc4_rUnorm, nil, .hapAlphaOnly),
        makeFourCC("HapR"): (.bc7_rgbaUnorm, nil, .rgba),
    ]

    public let url: URL
    public let info: MovieInfo
    public private(set) var kind: SourcePixelKind

    private let device: MTLDevice
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let formatDescription: CMFormatDescription
    private let generator: AVSampleBufferGenerator
    private var cursor: AVSampleCursor
    private var cursorIndex = 0

    private var session: VTDecompressionSession?
    private var surfaceTextures: [IOSurfaceID: (MTLTexture, MTLTexture?)] = [:]
    private var textureCache: CVMetalTextureCache?

    private var hapStaging: [UInt8] = []
    private var hapOutput: [UInt8] = []
    private var hapTextures0: [MTLTexture] = []
    private var hapTextures1: [MTLTexture] = []

    public static func open(url: URL, device: MTLDevice, poolSize: Int) async throws -> MovieSource {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MovieError.noVideoTrack }
        let (descriptions, frameRate, timeRange) = try await track.load(.formatDescriptions, .nominalFrameRate, .timeRange)
        guard let description = descriptions.first else { throw MovieError.noVideoTrack }
        return try MovieSource(url: url, device: device, poolSize: poolSize, asset: asset, track: track, description: description, frameRate: Double(frameRate), duration: timeRange.duration.seconds)
    }

    init(url: URL, device: MTLDevice, poolSize: Int, asset: AVAsset, track: AVAssetTrack, description: CMFormatDescription, frameRate: Double, duration: Double) throws {
        self.url = url
        self.device = device
        self.asset = asset
        self.track = track
        formatDescription = description
        let codec = CMFormatDescriptionGetMediaSubType(description)
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        info = MovieInfo(
            width: Int(dimensions.width), height: Int(dimensions.height), frameRate: frameRate,
            frameCount: max(1, Int((duration * frameRate).rounded())), codec: codec)
        guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { throw MovieError.noSample }
        self.cursor = cursor
        generator = AVSampleBufferGenerator(asset: asset, timebase: nil)

        if let hap = Self.hapCodecs[codec] {
            kind = hap.kind
            let maxBytes = DXTCompressor.compressedSize(width: info.width, height: info.height, format: .bc3)
            hapOutput = [UInt8](repeating: 0, count: maxBytes)
            hapTextures0 = try (0..<poolSize).map { _ in try Self.makeTexture(device, hap.format0, info.width, info.height) }
            if let format1 = hap.format1 {
                hapTextures1 = try (0..<poolSize).map { _ in try Self.makeTexture(device, format1, info.width, info.height) }
            }
        } else if Self.proResCodecs.contains(codec) {
            kind = .planarYCbCr  // refined after the first decoded frame
            var session: VTDecompressionSession?
            let specification: [CFString: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
            var attributes: [CFString: Any] = [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            // 4444 (XQ): the decoder's default (&sv4, bi-planar 4:4:4) drops alpha; ask for 4:4:4:4.
            if codec == makeFourCC("ap4h") || codec == makeFourCC("ap4x") {
                attributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_4444AYpCbCr16
            }
            let status = VTDecompressionSessionCreate(
                allocator: nil, formatDescription: description, decoderSpecification: specification as CFDictionary,
                imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
            guard status == noErr, let session else { throw MovieError.decoder(status) }
            self.session = session
            CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        } else {
            throw MovieError.unsupportedCodec(codec)
        }
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    static func makeTexture(_ device: MTLDevice, _ format: MTLPixelFormat, _ width: Int, _ height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw MovieError.decoder(-1) }
        return texture
    }

    /// Decodes frame `index` (0-based) into `slot`. Synchronous; call from the layer's decode thread.
    public func decode(frame index: Int, into slot: DecodedFrame) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        let sample = try sampleBuffer(at: index)
        slot.clear()
        slot.frameIndex = index
        if session != nil {
            try decodeProRes(sample, into: slot)
        } else {
            try decodeHAP(sample, into: slot)
        }
        slot.kind = kind
        slot.decodeNanos = DispatchTime.now().uptimeNanoseconds - start
    }

    private func sampleBuffer(at index: Int) throws -> CMSampleBuffer {
        let delta = index - cursorIndex
        if delta != 0 {
            let stepped = cursor.stepInDecodeOrder(byCount: Int64(delta))
            cursorIndex += Int(stepped)
            if stepped != Int64(delta) {  // clamped at an end: rebuild from the start
                guard let fresh = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { throw MovieError.noSample }
                cursor = fresh
                cursorIndex = Int(cursor.stepInDecodeOrder(byCount: Int64(index)))
            }
        }
        let request = AVSampleBufferRequest(start: cursor)
        request.direction = .forward
        request.maxSampleCount = 1
        return try generator.makeSampleBuffer(for: request)
    }

    // MARK: ProRes

    private final class Output { var buffer: CVPixelBuffer?; var status: OSStatus = noErr }

    private func decodeProRes(_ sample: CMSampleBuffer, into slot: DecodedFrame) throws {
        guard let session else { throw MovieError.decoder(-1) }
        let output = Output()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            output.status = status
            output.buffer = buffer
        }
        guard status == noErr, output.status == noErr, let buffer = output.buffer else {
            throw MovieError.decoder(status != noErr ? status : output.status)
        }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        slot.pixelBuffer = buffer
        let planes = CVPixelBufferGetPlaneCount(buffer)
        switch (format, planes) {
        case (kCVPixelFormatType_422YpCbCr16, _), (kCVPixelFormatType_4444AYpCbCr16, _):
            kind = format == kCVPixelFormatType_422YpCbCr16 ? .v216 : .y416
            guard let surface else { throw MovieError.unexpectedPixelFormat(format) }
            let id = IOSurfaceGetID(surface)
            if let cached = surfaceTextures[id] {
                slot.texture0 = cached.0
            } else {
                let width = kind == .v216 ? info.width / 2 : info.width
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: width, height: info.height, mipmapped: false)
                descriptor.usage = .shaderRead
                descriptor.storageMode = .shared
                guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
                    throw MovieError.unexpectedPixelFormat(format)
                }
                surfaceTextures[id] = (texture, nil)
                slot.texture0 = texture
            }
        case (_, 2), (_, 3):
            // Bi-planar YCbCr (sv22/sv44 and their lossless-compressed '&' variants): the texture cache
            // wraps each plane without a copy; chroma subsampling is irrelevant with normalized sampling.
            kind = planes == 3 ? .planarYCbCrA : .planarYCbCr
            guard let textureCache else { throw MovieError.unexpectedPixelFormat(format) }
            let sixteenBit = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) >= CVPixelBufferGetWidthOfPlane(buffer, 0) * 2
            var y: CVMetalTexture?, cbcr: CVMetalTexture?, alpha: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, sixteenBit ? .r16Unorm : .r8Unorm, CVPixelBufferGetWidthOfPlane(buffer, 0), CVPixelBufferGetHeightOfPlane(buffer, 0), 0, &y)
            CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, sixteenBit ? .rg16Unorm : .rg8Unorm, CVPixelBufferGetWidthOfPlane(buffer, 1), CVPixelBufferGetHeightOfPlane(buffer, 1), 1, &cbcr)
            if planes == 3 {
                CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, sixteenBit ? .r16Unorm : .r8Unorm, CVPixelBufferGetWidthOfPlane(buffer, 2), CVPixelBufferGetHeightOfPlane(buffer, 2), 2, &alpha)
            }
            guard let y, let cbcr, let t0 = CVMetalTextureGetTexture(y), let t1 = CVMetalTextureGetTexture(cbcr) else {
                throw MovieError.unexpectedPixelFormat(format)
            }
            slot.texture0 = t0
            slot.texture1 = t1
            slot.texture2 = alpha.flatMap(CVMetalTextureGetTexture)
            slot.metalTextures = (y, cbcr, alpha)
        default:
            throw MovieError.unexpectedPixelFormat(format)
        }
    }

    // MARK: HAP

    private static let decodeCallback: HapDecodeCallback = { function, context, count, _ in
        guard let function else { return }
        if count <= 1 {
            for i in 0..<count { function(context, i) }
        } else {
            DispatchQueue.concurrentPerform(iterations: Int(count)) { function(context, UInt32($0)) }
        }
    }

    /// Tests: always go through the staging copy (the contiguous block buffer path must give the same texture).
    var forceHAPStaging = false
    /// Frames decoded straight from the block buffer, without the staging copy (tests).
    private(set) var hapInPlaceFrames = 0

    private func decodeHAP(_ sample: CMSampleBuffer, into slot: DecodedFrame) throws {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw MovieError.noSample }
        let length = CMBlockBufferGetDataLength(block)
        // a contiguous block buffer (the normal case for a .mov sample) is decoded in place; otherwise copy it out
        var contiguousLength = 0
        var pointer: UnsafeMutablePointer<CChar>?
        let direct = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguousLength, totalLengthOut: nil, dataPointerOut: &pointer)
        if !forceHAPStaging, direct == noErr, contiguousLength == length, let pointer {
            try decodeHAP(UnsafeRawPointer(pointer), length: length, into: slot)
            hapInPlaceFrames += 1
            return
        }
        if hapStaging.count < length { hapStaging = [UInt8](repeating: 0, count: length) }
        let copyStatus = hapStaging.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard copyStatus == noErr else { throw MovieError.decoder(copyStatus) }
        try hapStaging.withUnsafeBytes { try decodeHAP($0.baseAddress!, length: length, into: slot) }
    }

    private func decodeHAP(_ input: UnsafeRawPointer, length: Int, into slot: DecodedFrame) throws {
        var textureCount: UInt32 = 0
        let countResult = HapGetFrameTextureCount(input, UInt(length), &textureCount)
        guard countResult == HapResult_No_Error.rawValue else { throw HAPError.decode(countResult) }
        for index in 0..<Int(textureCount) {
            var used: UInt = 0
            var format: UInt32 = 0
            let result: UInt32 = hapOutput.withUnsafeMutableBytes { output in
                HapDecode(input, UInt(length), UInt32(index), Self.decodeCallback, nil, output.baseAddress!, UInt(output.count), &used, &format)
            }
            guard result == HapResult_No_Error.rawValue else { throw HAPError.decode(result) }
            let blockBytes: Int
            switch format {
            case UInt32(HapTextureFormat_RGB_DXT1.rawValue), UInt32(HapTextureFormat_A_RGTC1.rawValue): blockBytes = 8
            case UInt32(HapTextureFormat_RGBA_DXT5.rawValue), UInt32(HapTextureFormat_YCoCg_DXT5.rawValue), UInt32(HapTextureFormat_RGBA_BPTC_UNORM.rawValue): blockBytes = 16
            default: throw HAPError.unsupportedTexture(format)
            }
            let pool = index == 0 ? hapTextures0 : hapTextures1
            guard slot.poolIndex < pool.count else { throw HAPError.unsupportedTexture(format) }
            let texture = pool[slot.poolIndex]
            hapOutput.withUnsafeBytes {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, info.width, info.height), mipmapLevel: 0, withBytes: $0.baseAddress!,
                    bytesPerRow: info.width / 4 * blockBytes)
            }
            if index == 0 { slot.texture0 = texture } else { slot.texture1 = texture }
        }
    }
}
