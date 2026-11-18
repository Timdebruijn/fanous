// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CHap
import CSnappy
import Darwin
import Foundation
import Testing

@testable import FanousEngine

/// A HAP frame comes from a file, so hap.c must refuse a corrupt one instead of reading outside the sample (B265).
/// The input and the output each end flush against a `PROT_NONE` page, so any read or write past the end of either
/// faults in the normal suite. A read before the start, or of the wrong bytes inside the buffer, is not caught here.
@Suite struct HAPFrameBoundsTests {
    /// A buffer whose usable bytes end right before a `PROT_NONE` page.
    final class Guarded {
        let base: UnsafeMutableRawPointer, capacity: Int, mapped: Int

        init(capacity: Int = 64 * 1024) {
            let page = Int(getpagesize())
            self.capacity = (capacity + page - 1) / page * page
            mapped = self.capacity + page
            let pointer = mmap(nil, mapped, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
            precondition(pointer != MAP_FAILED, "mmap failed")
            base = pointer!
            precondition(mprotect(base + self.capacity, page, PROT_NONE) == 0, "mprotect failed")
        }

        deinit { munmap(base, mapped) }

        /// The last `count` bytes before the guard page.
        func tail(_ count: Int) -> UnsafeMutableRawPointer { base + (capacity - count) }
    }

    /// `HapDecode` of texture `index` into an output of exactly `outputBytes`; the result code.
    static func decode(_ frame: [UInt8], index: UInt32 = 0, outputBytes: Int, input: Guarded, output: Guarded) -> UInt32 {
        let source = input.tail(frame.count), out = output.tail(outputBytes)
        frame.withUnsafeBytes { if let base = $0.baseAddress { source.copyMemory(from: base, byteCount: frame.count) } }
        var used: UInt = 0, format: UInt32 = 0, count: UInt32 = 0
        let counted = HapGetFrameTextureCount(source, UInt(frame.count), &count)
        guard counted == HapResult_No_Error.rawValue else { return counted }
        return HapDecode(source, UInt(frame.count), index, { function, context, count, _ in
            for i in 0..<count { function?(context, i) }
        }, nil, out, UInt(outputBytes), &used, &format)
    }

    static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }

    /// A section: a four-byte header, or an eight-byte one when asked or when the body needs it. `length` overrides
    /// the length written in the header (the body stays as it is).
    static func section(_ type: UInt8, _ body: [UInt8], eightByte: Bool = false, length: UInt32? = nil) -> [UInt8] {
        let written = length ?? UInt32(body.count)
        if eightByte || written > 0xFF_FFFF { return [0, 0, 0, type] + le32(written) + body }
        return [UInt8(written & 0xFF), UInt8(written >> 8 & 0xFF), UInt8(written >> 16 & 0xFF), type] + body
    }

    /// A chunked DXT1 frame (top section 0xCB) with uncompressed chunks, built by hand so every table can lie.
    static func chunked(
        compressors: [UInt8], sizes: [UInt8], offsets: [UInt8]? = nil, data: [UInt8], containerLength: UInt32? = nil
    ) -> [UInt8] {
        var tables = section(0x02, compressors) + section(0x03, sizes)
        if let offsets { tables += section(0x04, offsets) }
        return section(0xCB, section(0x01, tables, eightByte: containerLength != nil, length: containerLength) + data)
    }

    static let data = [UInt8](0..<16)
    static let none: UInt8 = 0x0A
    /// Frame data that reads as an unknown section claiming 4 bytes more than the frame has: a container whose
    /// length wraps the header sum walks on into it and past the end.
    static let unknownSection = [16, 0, 0, 0x7F] + [UInt8](repeating: 0, count: 12)

    /// Each case with the output size its own tables claim, so the old code got past the output-size check.
    @Test(arguments: [
        ("chunk offset beyond the section", chunked(compressors: [none, none], sizes: le32(8) + le32(8), offsets: le32(0) + le32(64), data: data), 16),
        ("chunk size beyond the section", chunked(compressors: [none, none], sizes: le32(8) + le32(4096), data: data), 4104),
        ("chunk offset 4 GB past the frame data", chunked(compressors: [none, none], sizes: le32(8) + le32(0x20), offsets: le32(0) + le32(0xFFFF_FFF0), data: data), 40),
        ("container length 0xFFFFFFF8", chunked(compressors: [none], sizes: le32(16), data: unknownSection, containerLength: 0xFFFF_FFF8), 16),
        ("container length 0xFFFFFFFF", chunked(compressors: [none], sizes: le32(16), data: unknownSection, containerLength: 0xFFFF_FFFF), 16),
        ("chunk count larger than the size table", chunked(compressors: [none, none, none, none], sizes: [8, 0, 0], data: []), 16),
        // a snappy stream of a 16-byte literal, in a top section whose length wraps the header sum
        ("snappy section length 0xFFFFFFF8", section(0xBB, [0x10, 0x3C] + data, eightByte: true, length: 0xFFFF_FFF8), 16),
    ])
    func aCorruptFrameIsRefused(_ name: String, _ frame: [UInt8], _ outputBytes: Int) {
        #expect(Self.decode(frame, outputBytes: outputBytes, input: Guarded(), output: Guarded()) == HapResult_Bad_Frame.rawValue, "\(name)")
    }

    struct Sample {
        var name: String
        var frame: [UInt8]
        /// The top section's type byte: 0xC? chunked, 0xB? one snappy block, 0x0D two textures.
        var top: UInt8
        /// Chunks in the compressor table of a chunked single-texture frame.
        var chunks: Int?
        var textures: [[UInt8]]
    }

    /// Valid frames of every kind the decoder takes, from a picture that compresses (a flat half and a gradient), so
    /// the encoder chunks with snappy instead of storing the texture uncompressed: the encoder's four variants (four
    /// chunks), one chunk, one top-level snappy block, two textures, and a hand-built frame with an offset table.
    static func validFrames() throws -> [Sample] {
        let side = 64
        var bgra = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let v = UInt8(x < side / 2 ? 0 : (x - side / 2) * 8)
                let pixel: [UInt8] = x < side / 2 ? [40, 80, 120, 255] : [v, v / 2, 255 - v, v]
                for c in 0..<4 { bgra[(y * side + x) * 4 + c] = pixel[c] }
            }
        }
        func dxt(_ format: DXTCompressor.Format) -> [UInt8] {
            var texture = [UInt8](repeating: 0, count: DXTCompressor.compressedSize(width: side, height: side, format: format))
            texture.withUnsafeMutableBufferPointer {
                DXTCompressor.compress(bgra: bgra, width: side, height: side, bytesPerRow: side * 4, format: format, output: $0.baseAddress!)
            }
            return texture
        }
        func hapEncode(_ textures: [[UInt8]], _ formats: [HapTextureFormat], chunks: UInt32) throws -> [UInt8] {
            var output = [UInt8](repeating: 0, count: 64 * 1024)
            var used: UInt = 0
            var inputs = textures.map { UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: $0.count, alignment: 16)) as UnsafeRawPointer? }
            defer { for p in inputs { UnsafeMutableRawPointer(mutating: p!).deallocate() } }
            for (i, texture) in textures.enumerated() { UnsafeMutableRawPointer(mutating: inputs[i]!).copyMemory(from: texture, byteCount: texture.count) }
            var lengths = textures.map { UInt($0.count) }
            var formatValues = formats.map { UInt32($0.rawValue) }
            var compressors = [UInt32](repeating: UInt32(HapCompressorSnappy.rawValue), count: textures.count)
            var chunkCounts = [UInt32](repeating: chunks, count: textures.count)
            let status = HapEncode(UInt32(textures.count), &inputs, &lengths, &formatValues, &compressors, &chunkCounts, &output, UInt(output.count), &used)
            try #require(status == HapResult_No_Error.rawValue)
            return Array(output[0..<Int(used)])
        }
        let tops: [HAPEncoder.Variant: UInt8] = [.hap: 0xCB, .hapAlpha: 0xCE, .hapQ: 0xCF, .hapAlphaOnly: 0xC1]
        var samples = try HAPEncoder.Variant.allCases.map { variant in
            var encoder = HAPEncoder(variant: variant, width: side, height: side)
            let frame = Array(try encoder.encode(bgra: bgra, bytesPerRow: side * 4))
            return Sample(name: variant.rawValue, frame: frame, top: tops[variant]!, chunks: Int(HAPEncoder.chunkCount), textures: [dxt(variant.dxt)])
        }
        let bc1 = dxt(.bc1)
        samples.append(Sample(name: "one chunk", frame: try hapEncode([bc1], [HapTextureFormat_RGB_DXT1], chunks: 1), top: 0xCB, chunks: 1, textures: [bc1]))
        var packed = [UInt8](repeating: 0, count: snappy_max_compressed_length(bc1.count))
        var packedLength = packed.count
        let packStatus = bc1.withUnsafeBytes { source in
            packed.withUnsafeMutableBytes { out in
                snappy_compress(source.bindMemory(to: CChar.self).baseAddress, source.count, out.bindMemory(to: CChar.self).baseAddress, &packedLength)
            }
        }
        try #require(packStatus == SNAPPY_OK)
        samples.append(Sample(name: "top-level snappy", frame: section(0xBB, Array(packed[0..<packedLength])), top: 0xBB, textures: [bc1]))
        let ycocg = dxt(.ycocgDXT5), alpha = dxt(.bc4)
        samples.append(Sample(
            name: "two textures", frame: try hapEncode([ycocg, alpha], [HapTextureFormat_YCoCg_DXT5, HapTextureFormat_A_RGTC1], chunks: 2), top: 0x0D,
            textures: [ycocg, alpha]))
        samples.append(Sample(
            name: "offset table", frame: chunked(compressors: [none, none], sizes: le32(8) + le32(8), offsets: le32(8) + le32(0), data: data), top: 0xCB,
            chunks: 2, textures: [Array(data[8...] + data[..<8])]))
        return samples
    }

    /// The corpus stays what it says: a picture that stops compressing would turn the chunked frames into
    /// uncompressed ones (0xA?) and the decode paths above would go untested.
    @Test func theCorpusCoversEveryDecodePath() throws {
        for sample in try Self.validFrames() {
            #expect(sample.frame[3] == sample.top, "\(sample.name): top section type")
            if let chunks = sample.chunks {
                // top header, container header, then the compressor table: its length is the chunk count
                #expect(sample.frame[7] == 0x01 && sample.frame[11] == 0x02 && Int(sample.frame[8]) == chunks, "\(sample.name): \(chunks) chunks")
                if sample.name != "offset table" {
                    #expect(sample.frame[12..<(12 + chunks)].contains(0x0B), "\(sample.name): a snappy chunk")
                }
            }
            if sample.top == 0x0D {
                let first = Int(sample.frame[4]) | Int(sample.frame[5]) << 8 | Int(sample.frame[6]) << 16
                #expect(sample.frame[7] == 0xCF && sample.frame[4 + 4 + first + 3] == 0xC1, "\(sample.name): two chunked textures")
            }
        }
    }

    /// The checks change nothing for a valid frame: every kind decodes byte for byte to its texture.
    @Test func validFramesDecodeToTheirTextures() throws {
        let input = Guarded(), output = Guarded()
        for sample in try Self.validFrames() {
            for (index, texture) in sample.textures.enumerated() {
                let result = Self.decode(sample.frame, index: UInt32(index), outputBytes: texture.count, input: input, output: output)
                #expect(result == HapResult_No_Error.rawValue, "\(sample.name)")
                #expect(Array(UnsafeRawBufferPointer(start: output.tail(texture.count), count: texture.count)) == texture, "\(sample.name)")
            }
        }
    }

    /// Fixed-seed fuzz: random byte flips and truncations over valid frames, a third of the rounds aimed at the
    /// decode-instruction tables. Only "returns, no fault" is asserted.
    @Test func randomFlipsAndTruncationsNeverReadOutsideTheFrame() throws {
        let input = Guarded(), output = Guarded()
        let samples = try Self.validFrames()
        var state: UInt64 = 0x2026_1118
        func next() -> Int {  // SplitMix64
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ z >> 30) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ z >> 27) &* 0x94D0_49BB_1331_11EB
            return Int(truncatingIfNeeded: (z ^ z >> 31) >> 1)
        }
        for round in 0..<4000 {
            let sample = samples[round % samples.count]
            var frame = sample.frame
            // the tables: the decode-instructions container's body (chunked single-texture frames only)
            let tables = sample.chunks.map { _ in 8..<min(frame.count, 8 + Int(frame[4])) }
            let aimed = tables != nil && round % 3 == 0
            for _ in 0...(next() % 4) {
                let span = aimed ? tables! : next() % 2 == 0 ? 0..<min(48, frame.count) : 0..<frame.count
                frame[span.lowerBound + next() % span.count] = UInt8(truncatingIfNeeded: next())
            }
            if next() % 4 == 0 { frame.removeLast(next() % frame.count) }
            let index = next() % sample.textures.count
            _ = Self.decode(frame, index: UInt32(index), outputBytes: sample.textures[index].count, input: input, output: output)
        }
    }
}
