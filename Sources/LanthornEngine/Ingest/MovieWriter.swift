// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import CoreMedia
import Foundation

/// Writes a QuickTime movie: ProRes through AVFoundation's hardware encoder,
/// HAP through `HAPEncoder` and AVAssetWriter sample passthrough.
public final class MovieWriter {
    public enum Codec: Sendable, Equatable {
        case proRes422HQ
        case proRes422
        case proRes4444
        case hap(HAPEncoder.Variant)

        public var name: String {
            switch self {
            case .proRes422HQ: "prores422hq"
            case .proRes422: "prores422"
            case .proRes4444: "prores4444"
            case .hap(let variant): variant.rawValue.lowercased()
            }
        }
    }

    public enum WriterError: Error { case notReady, failed(String) }

    public let width: Int
    public let height: Int
    public let fps: Int32
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var hap: HAPEncoder?
    private let hapFormat: CMFormatDescription?
    private var frame: Int64 = 0

    public init(url: URL, width: Int, height: Int, fps: Int32, codec: Codec) throws {
        self.width = width
        self.height = height
        self.fps = fps
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        switch codec {
        case .hap(let variant):
            var description: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: variant.fourCC, width: Int32(width), height: Int32(height),
                extensions: nil, formatDescriptionOut: &description)
            guard status == noErr, let description else { throw WriterError.failed("format description \(status)") }
            hapFormat = description
            hap = HAPEncoder(variant: variant, width: width, height: height)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: description)
            adaptor = nil
        default:
            let codecType: AVVideoCodecType =
                switch codec {
                case .proRes422HQ: .proRes422HQ
                case .proRes422: .proRes422
                default: .proRes4444
                }
            hapFormat = nil
            input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [AVVideoCodecKey: codecType, AVVideoWidthKey: width, AVVideoHeightKey: height])
            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                ])
        }
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw WriterError.failed("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else { throw WriterError.failed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
    }

    /// A BGRA pixel buffer from `pixelBufferPool` (ProRes) or any BGRA buffer (HAP).
    public var pixelBufferPool: CVPixelBufferPool? { adaptor?.pixelBufferPool }

    public func append(_ pixelBuffer: CVPixelBuffer) throws {
        while !input.isReadyForMoreMediaData { usleep(500) }
        let time = CMTime(value: frame, timescale: fps)
        if let adaptor {
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw WriterError.failed(writer.error?.localizedDescription ?? "append")
            }
        } else if var encoder = hap, let hapFormat {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            let bytes = try encoder.encode(bgra: base, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer))
            hap = encoder
            let sample = try Self.sampleBuffer(bytes: bytes, format: hapFormat, time: time, duration: CMTime(value: 1, timescale: fps))
            guard input.append(sample) else { throw WriterError.failed(writer.error?.localizedDescription ?? "append (HAP passthrough)") }
        }
        frame += 1
    }

    public func finish() throws {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw WriterError.failed(writer.error?.localizedDescription ?? "finishWriting \(writer.status.rawValue)") }
    }

    static func sampleBuffer(bytes: ArraySlice<UInt8>, format: CMFormatDescription, time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw WriterError.failed("block buffer \(status)") }
        status = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        guard status == noErr else { throw WriterError.failed("block copy \(status)") }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw WriterError.failed("sample buffer \(status)") }
        return sample
    }
}

/// Synthetic benchmark content: animated gradient, a moving bar and a 16-bit
/// binary frame counter (32 px squares, top-left) so decoded frames are identifiable.
public enum PatternFrames {
    public static func fill(bgra: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, frame: Int) {
        let barX = (frame * 8) % max(1, width - 16)
        for y in 0..<height {
            let row = bgra + y * bytesPerRow
            let green = UInt8(y * 255 / max(1, height - 1))
            for x in 0..<width {
                let p = row + x * 4
                var r = UInt8((x * 255 / max(1, width - 1) + frame * 2) & 255)
                var g = green
                var b: UInt8 = 128
                if x >= barX && x < barX + 16 { r = 255; g = 255; b = 255 }
                if y < 32 && x < 32 * 16 {
                    let bit = 15 - x / 32
                    let on = (frame >> bit) & 1 == 1
                    r = on ? 255 : 0; g = r; b = r
                }
                p[0] = b; p[1] = g; p[2] = r; p[3] = 255
            }
        }
    }

    /// Reads the counter back from a BGRA frame (tests and the decode spike).
    public static func counter(bgra: UnsafePointer<UInt8>, bytesPerRow: Int) -> Int {
        var value = 0
        for i in 0..<16 {
            let p = bgra + 16 * bytesPerRow + (i * 32 + 16) * 4
            if p[2] > 127 { value |= 1 << (15 - i) }
        }
        return value
    }
}
