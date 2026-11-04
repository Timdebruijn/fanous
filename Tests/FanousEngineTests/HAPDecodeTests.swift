// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import Testing

@testable import FanousEngine

/// HAP frames are decoded straight from the sample's block buffer; the staging-copy fallback must give the same texture.
@Suite(.serialized, .cleansTempFiles) struct HAPDecodeTests {
    @Test func decodingInPlaceMatchesTheStagingCopy() async throws {
        let directory = try tempDir("fanous-ingest-tests")
        let url = directory.appending(path: "clip.mov")
        try await writePatternMovie(to: url, size: (320, 176), fps: 10, frames: 4, codec: .hap(.hap))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try await MovieSource.open(url: url, device: device, poolSize: 2)
        let direct = DecodedFrame(poolIndex: 0), staged = DecodedFrame(poolIndex: 1)
        try source.decode(frame: 2, into: direct)
        #expect(source.hapInPlaceFrames == 1, "the contiguous block buffer was decoded without a copy")
        source.forceHAPStaging = true
        try source.decode(frame: 2, into: staged)
        let a = try #require(direct.texture0), b = try #require(staged.texture0)
        func bytes(_ texture: MTLTexture) -> [UInt8] {
            let blocks = texture.width / 4 * texture.height / 4
            var out = [UInt8](repeating: 0, count: blocks * 8)  // DXT1 (Hap1); a larger format fails the size check below
            let rowBytes = texture.width / 4 * 8
            texture.getBytes(&out, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            return out
        }
        #expect(source.info.codecName == "Hap1")
        let first = bytes(a)
        #expect(first == bytes(b), "same decoded texture either way")
        #expect(first.contains { $0 != 0 }, "and it is not empty")
        #expect(source.hapInPlaceFrames == 1)
        #expect(direct.frameIndex == 2 && staged.frameIndex == 2)
    }
}
