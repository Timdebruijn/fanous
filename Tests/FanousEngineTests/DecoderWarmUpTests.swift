// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreMedia
import Testing

@testable import FanousEngine

/// B389. Needs the ProRes encoder and decoder of a real Mac: not on the `--hosted` list. No test asks whether a decode
/// blocked: another test's loader may take the process past the mark while these run.
@Suite struct DecoderWarmUpTests {
    @Test(.offPool) func theSampleIsOneProRes422Frame() throws {
        let sample = try #require(DecoderWarmUp.sample(width: 1920, height: 1080))
        let description = try #require(CMSampleBufferGetFormatDescription(sample))
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_AppleProRes422)
        #expect(CMSampleBufferGetNumSamples(sample) == 1)
        #expect(CMVideoFormatDescriptionGetDimensions(description).width == 1920)
    }

    /// It holds every buffer it decodes and stops at the first one past the target.
    @Test(.offPool) func itHoldsDecodedFramesUpToTheTarget() {
        let target = 100_000_000
        let report = DecoderWarmUp.run(target: target, memory: 32_000_000_000)
        let frame = 1920 * 1080 * 4  // 4:2:2 at 16 bits, the least the hardware decoder's frame takes
        #expect(report.skipped == nil)
        #expect(report.heldBytes >= target)
        #expect(report.heldBytes < target + 2 * frame)
        #expect(report.longestDecode > 0)
        #expect(report.longestAtBytes < report.heldBytes)
        #expect(report.seconds > 0)
    }

    @Test func aTargetOfNothingDecodesNothing() {
        #expect(DecoderWarmUp.run(target: 0, memory: 32_000_000_000) == DecoderWarmUp.Report())
    }

    /// 1.5 GB held next to a show is too much of an 8 GB Mac: it says so and decodes nothing.
    @Test func aMacWithLittleMemoryIsLeftAlone() {
        let report = DecoderWarmUp.run(target: 100_000_000, memory: 8_000_000_000)
        #expect(report.skipped == "8 GB of memory")
        #expect(report.heldBytes == 0)
    }

    @Test func theTargetIsPastTheMarkMeasured() {
        #expect(DecoderWarmUp.target > 1_041_102_848)  // 272 buffers of 720p: the first run that blocked (B389)
    }
}
