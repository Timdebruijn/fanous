// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import CHap
import Foundation
import Metal
import Testing

@testable import FanousEngine

/// HAP movies whose width or height is no multiple of 4, as a third-party encoder writes them (B295): the track says w x h,
/// each texture holds ceil(w/4) x ceil(h/4) blocks of a pattern frame drawn at the padded size.
@Suite(.serialized, .cleansTempFiles) struct HAPBlockSizeTests {
    /// The DXT formats in each codec's frame, in texture order. HapR carries BC3 bytes as stand-in BC7 blocks: the
    /// engine has no BC7 compressor, and the upload is checked byte for byte, which needs no meaningful picture.
    static let textures: [String: [(DXTCompressor.Format, HapTextureFormat)]] = [
        "Hap1": [(.bc1, HapTextureFormat_RGB_DXT1)],
        "Hap5": [(.bc3, HapTextureFormat_RGBA_DXT5)],
        "HapY": [(.ycocgDXT5, HapTextureFormat_YCoCg_DXT5)],
        "HapA": [(.bc4, HapTextureFormat_A_RGTC1)],
        "HapM": [(.ycocgDXT5, HapTextureFormat_YCoCg_DXT5), (.bc4, HapTextureFormat_A_RGTC1)],
        "HapR": [(.bc3, HapTextureFormat_RGBA_BPTC_UNORM)],
    ]

    /// Writes `frames` frames whose blocks cover `encoded` (default: `size` rounded up to whole blocks) into a track that
    /// says `size`; returns frame 1's texture bytes.
    static func writeMovie(to url: URL, codec: String, size: (Int, Int), encoded: (Int, Int)? = nil, frames: Int = 2) async throws -> [[UInt8]] {
        let (ew, eh) = encoded ?? ((size.0 + 3) / 4 * 4, (size.1 + 3) / 4 * 4)
        let layout = try #require(textures[codec])
        return try await offPool {
            var description: CMFormatDescription?
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: makeFourCC(codec), width: Int32(size.0), height: Int32(size.1), extensions: nil,
                formatDescriptionOut: &description)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: description!)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            var bgra = [UInt8](repeating: 0, count: ew * eh * 4)
            var kept: [[UInt8]] = []
            for frame in 0..<frames {
                PatternFrames.fill(bgra: &bgra, width: ew, height: eh, bytesPerRow: ew * 4, frame: frame)
                let dxt = layout.map { format, _ in
                    var out = [UInt8](repeating: 0, count: DXTCompressor.compressedSize(width: ew, height: eh, format: format))
                    DXTCompressor.compress(bgra: bgra, width: ew, height: eh, bytesPerRow: ew * 4, format: format, output: &out)
                    return out
                }
                if frame == 1 { kept = dxt }
                var lengths = dxt.map { UInt($0.count) }
                var formats = layout.map { $0.1.rawValue }
                var compressors = [UInt32](repeating: HapCompressorSnappy.rawValue, count: dxt.count)
                var chunks = [UInt32](repeating: 1, count: dxt.count)
                var encodedFrame = [UInt8](repeating: 0, count: Int(HapMaxEncodedLength(UInt32(dxt.count), &lengths, &formats, &chunks)))
                var used: UInt = 0
                let joined = dxt.flatMap { $0 }
                let result: UInt32 = joined.withUnsafeBytes { base in
                    var offset = 0
                    var inputs: [UnsafeRawPointer?] = dxt.map { bytes in defer { offset += bytes.count }; return UnsafeRawPointer(base.baseAddress! + offset) }
                    return HapEncode(UInt32(dxt.count), &inputs, &lengths, &formats, &compressors, &chunks, &encodedFrame, UInt(encodedFrame.count), &used)
                }
                guard result == HapResult_No_Error.rawValue else { throw HAPError.encode(result) }
                let sample = try MovieWriter.sampleBuffer(
                    bytes: encodedFrame[0..<Int(used)], format: description!, time: CMTime(value: Int64(frame), timescale: 10), duration: CMTime(value: 1, timescale: 10))
                while !input.isReadyForMoreMediaData { usleep(500) }
                guard input.append(sample) else { throw MovieWriter.WriterError.failed("append") }
            }
            input.markAsFinished()
            try writer.finishBlocking()
            return kept
        }
    }

    @Test(arguments: ["Hap1", "Hap5", "HapY", "HapA", "HapM", "HapR"], [(66, 120), (64, 122), (62, 121)])  // width, height, both short of a block
    func oddSizedFramesDecodeToTheirBlocks(codec: String, size: (Int, Int)) async throws {
        let url = try tempDir("fanous-hap-sizes").appending(path: "\(codec)-\(size.0)x\(size.1).mov")
        let written = try await Self.writeMovie(to: url, codec: codec, size: size)
        let source = try await MovieSource.open(url: url, device: try #require(MTLCreateSystemDefaultDevice()), poolSize: 1)
        let frame = DecodedFrame(poolIndex: 0)
        try source.decode(frame: 1, into: frame)
        let textures = [frame.texture0, frame.texture1].prefix(written.count)
        #expect(textures.map { $0?.bytes() ?? [] } == written, "\(codec) \(size): every texture holds the blocks the file carries")
        if codec != "HapA" && codec != "HapR" {  // a picture to look at: frame 1's bar starts at x = 8
            #expect(try patternBarX(frame, size: size) == 8, "\(codec) \(size): frame 1 as drawn on stage")
        }
    }

    /// A frame smaller than its track (64x120 blocks in a 64x122 track, like 1920x1080 in 1920x1082): Metal would read 31
    /// block rows from a decode of 30, past the end of the buffer for the 16-byte formats.
    @Test(arguments: ["Hap1", "HapY", "HapM"])
    func aFrameShortOfItsTrackIsRefused(codec: String) async throws {
        let url = try tempDir("fanous-hap-sizes").appending(path: "\(codec)-short.mov")
        _ = try await Self.writeMovie(to: url, codec: codec, size: (64, 122), encoded: (64, 120))
        let source = try await MovieSource.open(url: url, device: try #require(MTLCreateSystemDefaultDevice()), poolSize: 1)
        let frame = DecodedFrame(poolIndex: 0)
        #expect(throws: HAPError.self) { try source.decode(frame: 1, into: frame) }
        #expect(frame.texture0 == nil, "nothing uploaded")
    }
}
