// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreMedia
import Testing

@testable import FanousEngine

/// B389. Needs the ProRes encoder and decoder of a real Mac: not on the `--hosted` list.
@Suite struct DecoderWarmUpTests {
    @Test func theSampleIsOneProRes422Frame() throws {
        let sample = try #require(DecoderWarmUp.sample(width: 1920, height: 1080))
        let description = try #require(CMSampleBufferGetFormatDescription(sample))
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_AppleProRes422)
        #expect(CMSampleBufferGetNumSamples(sample) == 1)
        #expect(CMVideoFormatDescriptionGetDimensions(description).width == 1920)
    }

    /// Far below the mark where a decode blocks: it stops at the cap, having held every buffer it decoded.
    @Test func itHoldsDecodedFramesUpToTheCap() {
        let cap = 100_000_000
        let report = DecoderWarmUp.run(cap: cap)
        let frame = 1920 * 1080 * 4  // 4:2:2 at 16 bits, the least a frame takes
        #expect(report.heldBytes >= cap)
        #expect(report.heldBytes < cap + 2 * frame)  // it stopped at the first buffer past the cap
        #expect(report.blockedAtBytes == nil)
        #expect(report.longestDecode < DecoderWarmUp.blocked)
        #expect(report.seconds > 0)
    }

    @Test func aCapOfNothingDecodesNothing() {
        #expect(DecoderWarmUp.run(cap: 0).heldBytes == 0)
    }

    @Test func theCapIsBetweenOneAndAHalfAndFourGigabytes() {
        #expect((1_500_000_000...4_000_000_000).contains(DecoderWarmUp.cap))
    }
}
