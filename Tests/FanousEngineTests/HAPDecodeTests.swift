// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import Testing

@testable import FanousEngine

/// HAP frames are decoded straight from the sample's block buffer; the staging-copy fallback must give the same texture.
@Suite(.cleansTempFiles) struct HAPDecodeTests {
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
        #expect(source.hapInPlaceFrames == 1, "the staged decode took the copy")
        let a = try #require(direct.texture0), b = try #require(staged.texture0)
        #expect(source.info.codecName == "Hap1")
        #expect(a.bytes() == b.bytes(), "same decoded texture either way")
        #expect(try patternBarX(direct, size: (320, 176)) == 16, "and it is frame 2: its bar at x = 16")
    }
}
