// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousEngine

@Suite struct DXTCompressorTests {
    /// A 4×4 solid block must compress to equal endpoints and all-zero indices.
    @Test func solidBlockBC1() {
        var bgra = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for i in 0..<16 { bgra[i * 4] = 0; bgra[i * 4 + 1] = 128; bgra[i * 4 + 2] = 255; bgra[i * 4 + 3] = 255 }  // orange-ish
        var out = [UInt8](repeating: 0, count: 8)
        bgra.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                DXTCompressor.compress(bgra: input.baseAddress!, width: 4, height: 4, bytesPerRow: 16, format: .bc1, output: output.baseAddress!)
            }
        }
        let c0 = UInt16(out[0]) | UInt16(out[1]) << 8, c1 = UInt16(out[2]) | UInt16(out[3]) << 8
        #expect(c0 == c1)
        #expect(c0 == DXTCompressor.pack565(255, 128, 0))
        #expect(Array(out[4..<8]) == [0, 0, 0, 0])
    }

    @Test func gradientBlockUsesAllFourIndices() {
        var bgra = [UInt8](repeating: 255, count: 64)
        for i in 0..<16 { let v = UInt8(i * 17); bgra[i * 4] = v; bgra[i * 4 + 1] = v; bgra[i * 4 + 2] = v }
        var out = [UInt8](repeating: 0, count: 8)
        bgra.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                DXTCompressor.compress(bgra: input.baseAddress!, width: 4, height: 4, bytesPerRow: 16, format: .bc1, output: output.baseAddress!)
            }
        }
        let indices = UInt32(out[4]) | UInt32(out[5]) << 8 | UInt32(out[6]) << 16 | UInt32(out[7]) << 24
        let used = Set((0..<16).map { Int(indices >> (2 * $0)) & 3 })
        #expect(used.count == 4)
        #expect(indices & 3 == 1)  // darkest pixel → c1 (min)
        #expect((indices >> 30) & 3 == 0)  // brightest pixel → c0 (max)
    }

    @Test func ycocgBlockKeepsLumaInAlphaAndScaleInBlue() {
        var bgra = [UInt8](repeating: 255, count: 64)
        for i in 0..<16 { bgra[i * 4] = 40; bgra[i * 4 + 1] = 200; bgra[i * 4 + 2] = 120 }  // one colour: low chroma deviation → scale 2
        var out = [UInt8](repeating: 0, count: 16)
        bgra.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                DXTCompressor.compress(bgra: input.baseAddress!, width: 4, height: 4, bytesPerRow: 16, format: .ycocgDXT5, output: output.baseAddress!)
            }
        }
        let y = (120 + 2 * 200 + 40) / 4
        #expect(Int(out[0]) == y && Int(out[1]) == y)  // alpha endpoints = luma
        let c0 = UInt16(out[8]) | UInt16(out[9]) << 8
        let blue = Int(c0 & 31)
        #expect(blue == 1)  // scale 2 → blue bits 1 (|Co| = 40, |Cg| = 60 → below 64)
        #expect(DXTCompressor.compressedSize(width: 1920, height: 1080, format: .ycocgDXT5) == 1920 * 1080)
        #expect(DXTCompressor.compressedSize(width: 1920, height: 1080, format: .bc1) == 1920 * 1080 / 2)
    }

    @Test func patternCounterRoundTrips() {
        let width = 1024, height = 64
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        for frame in [0, 1, 255, 4660, 65535] {
            bgra.withUnsafeMutableBufferPointer { PatternFrames.fill(bgra: $0.baseAddress!, width: width, height: height, bytesPerRow: width * 4, frame: frame) }
            let read = bgra.withUnsafeBufferPointer { PatternFrames.counter(bgra: $0.baseAddress!, bytesPerRow: width * 4) }
            #expect(read == frame)
        }
    }
}
