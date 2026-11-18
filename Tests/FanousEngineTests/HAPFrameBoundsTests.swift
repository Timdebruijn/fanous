// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CHap
import Foundation
import Testing

@testable import FanousEngine

/// A HAP frame comes from a file, so hap.c must refuse a corrupt one instead of reading outside the sample (B265).
/// Each input sits in an allocation of exactly its size, so AddressSanitizer
/// (`swift test --sanitize=address --filter HAPFrameBoundsTests`) sees a read one byte past it.
@Suite struct HAPFrameBoundsTests {
    static let outputBytes = 1 << 20

    /// `HapDecode` over the frame (texture `index`) in an exact-size allocation; the result code.
    static func decode(_ frame: [UInt8], index: UInt32 = 0, output: UnsafeMutableRawPointer? = nil) -> UInt32 {
        let input = UnsafeMutableRawPointer.allocate(byteCount: max(frame.count, 1), alignment: 16)
        defer { input.deallocate() }
        frame.withUnsafeBytes { if let base = $0.baseAddress { input.copyMemory(from: base, byteCount: frame.count) } }
        let out = output ?? UnsafeMutableRawPointer.allocate(byteCount: outputBytes, alignment: 16)
        defer { if output == nil { out.deallocate() } }
        var used: UInt = 0, format: UInt32 = 0, count: UInt32 = 0
        let counted = HapGetFrameTextureCount(input, UInt(frame.count), &count)
        guard counted == HapResult_No_Error.rawValue else { return counted }
        return HapDecode(input, UInt(frame.count), index, { function, context, count, _ in
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

    @Test(arguments: [
        ("chunk offset beyond the section", chunked(compressors: [none, none], sizes: le32(8) + le32(8), offsets: le32(0) + le32(64), data: data)),
        ("chunk size beyond the section", chunked(compressors: [none, none], sizes: le32(8) + le32(4096), data: data)),
        ("chunk offset plus size wraps", chunked(compressors: [none, none], sizes: le32(8) + le32(0x20), offsets: le32(0) + le32(0xFFFF_FFF0), data: data)),
        ("container length 0xFFFFFFF8", chunked(compressors: [none], sizes: le32(16), data: unknownSection, containerLength: 0xFFFF_FFF8)),
        ("container length 0xFFFFFFFF", chunked(compressors: [none], sizes: le32(16), data: unknownSection, containerLength: 0xFFFF_FFFF)),
        ("chunk count larger than the size table", chunked(compressors: [none, none, none, none], sizes: [8, 0, 0], data: [])),
        // a snappy stream of a 16-byte literal, in a top section whose length wraps the header sum
        ("snappy section length 0xFFFFFFF8", section(0xBB, [0x10, 0x3C] + data, eightByte: true, length: 0xFFFF_FFF8)),
    ])
    func aCorruptFrameIsRefused(_ name: String, _ frame: [UInt8]) {
        #expect(Self.decode(frame) == HapResult_Bad_Frame.rawValue, "\(name)")
    }

    /// Valid frames of every kind the engine writes or reads: the encoder's four variants (four snappy chunks), one
    /// unchunked snappy frame, a two-texture HapM-style frame, and the hand-built chunked frame with an offset table.
    /// Each comes with the texture bytes it must decode to, one array per texture.
    static func validFrames() throws -> [(frame: [UInt8], textures: [[UInt8]])] {
        let side = 32
        var bgra = [UInt8](repeating: 0, count: side * side * 4)
        for i in bgra.indices { bgra[i] = UInt8(truncatingIfNeeded: i * 7 ^ i >> 5) }
        var frames = try HAPEncoder.Variant.allCases.map { variant in
            var encoder = HAPEncoder(variant: variant, width: side, height: side)
            var texture = [UInt8](repeating: 0, count: DXTCompressor.compressedSize(width: side, height: side, format: variant.dxt))
            texture.withUnsafeMutableBufferPointer {
                DXTCompressor.compress(bgra: bgra, width: side, height: side, bytesPerRow: side * 4, format: variant.dxt, output: $0.baseAddress!)
            }
            return (frame: Array(try encoder.encode(bgra: bgra, bytesPerRow: side * 4)), textures: [texture])
        }
        let dxt = [UInt8](bgra[0..<(side * side / 2)])  // a DXT1-sized texture's worth of bytes
        for (count, chunks) in [(1, UInt32(1)), (2, UInt32(2))] {
            var output = [UInt8](repeating: 0, count: 64 * 1024)
            var used: UInt = 0
            let status: UInt32 = dxt.withUnsafeBufferPointer { input in
                var inputs = [UnsafeRawPointer?](repeating: UnsafeRawPointer(input.baseAddress!), count: count)
                var lengths = [UInt](repeating: UInt(input.count), count: count)
                var formats = [UInt32(HapTextureFormat_YCoCg_DXT5.rawValue), UInt32(HapTextureFormat_A_RGTC1.rawValue)].prefix(count).map { $0 }
                var compressors = [UInt32](repeating: UInt32(HapCompressorSnappy.rawValue), count: count)
                var chunkCounts = [UInt32](repeating: chunks, count: count)
                return HapEncode(UInt32(count), &inputs, &lengths, &formats, &compressors, &chunkCounts, &output, UInt(output.count), &used)
            }
            try #require(status == HapResult_No_Error.rawValue)
            frames.append((frame: Array(output[0..<Int(used)]), textures: Array(repeating: dxt, count: count)))
        }
        frames.append((
            frame: chunked(compressors: [none, none], sizes: le32(8) + le32(8), offsets: le32(8) + le32(0), data: data),
            textures: [Array(data[8...] + data[..<8])]
        ))
        return frames
    }

    /// The checks change nothing for a valid frame: every kind decodes byte for byte to its texture.
    @Test func validFramesDecodeToTheirTextures() throws {
        let output = UnsafeMutableRawPointer.allocate(byteCount: Self.outputBytes, alignment: 16)
        defer { output.deallocate() }
        for (frame, textures) in try Self.validFrames() {
            for (index, texture) in textures.enumerated() {
                #expect(Self.decode(frame, index: UInt32(index), output: output) == HapResult_No_Error.rawValue)
                #expect(Array(UnsafeRawBufferPointer(start: output, count: texture.count)) == texture)
            }
        }
    }

    /// Fixed-seed fuzz: random byte flips and truncations over valid frames. Only "returns, no crash" is asserted.
    @Test func randomFlipsAndTruncationsNeverReadOutsideTheFrame() throws {
        let output = UnsafeMutableRawPointer.allocate(byteCount: Self.outputBytes, alignment: 16)
        defer { output.deallocate() }
        let frames = try Self.validFrames().map(\.frame)
        var state: UInt64 = 0x2026_1118
        func next() -> Int {  // SplitMix64
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ z >> 30) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ z >> 27) &* 0x94D0_49BB_1331_11EB
            return Int(truncatingIfNeeded: (z ^ z >> 31) >> 1)
        }
        for round in 0..<4000 {
            var frame = frames[round % frames.count]
            for _ in 0...(next() % 4) {
                // header bytes are where lengths live: aim half the flips at the first 48 bytes
                let span = next() % 2 == 0 ? min(48, frame.count) : frame.count
                frame[next() % span] = UInt8(truncatingIfNeeded: next())
            }
            if next() % 4 == 0 { frame.removeLast(next() % frame.count) }
            _ = Self.decode(frame, index: UInt32(next() % 2), output: output)
        }
    }
}
