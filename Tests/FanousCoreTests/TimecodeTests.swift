// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import FanousCore

@Suite struct TimecodeTests {
    @Test func nonDropFrameMath() {
        let tc = Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, rate: .fps25)
        #expect(tc.frameCount == 3723 * 25 + 4)
        #expect(Timecode(frameCount: tc.frameCount, rate: .fps25) == tc)
        #expect(tc.description == "01:02:03:04")
        #expect(abs(tc.secondsValue - 3723.16) < 0.001)
    }

    @Test func dropFrameMath() {
        #expect(Timecode(hours: 0, minutes: 1, seconds: 0, frames: 2, rate: .fps2997df).frameCount == 1800)
        #expect(Timecode(hours: 0, minutes: 0, seconds: 59, frames: 29, rate: .fps2997df).frameCount == 1799)
        #expect(Timecode(hours: 0, minutes: 10, seconds: 0, frames: 0, rate: .fps2997df).frameCount == 17982)
        #expect(Timecode(frameCount: 1800, rate: .fps2997df).description == "00:01:00;02")
        #expect(Timecode(frameCount: 17982, rate: .fps2997df).description == "00:10:00;00")
        #expect(Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, rate: .fps2997df).frameCount == 107892)
        for count in stride(from: 0, to: 200_000, by: 37) {
            let tc = Timecode(frameCount: count, rate: .fps2997df)
            #expect(tc.frameCount == count)
            #expect(!(tc.seconds == 0 && tc.minutes % 10 != 0 && tc.frames < 2), "dropped frame number \(tc)")
        }
    }

    @Test func rateDetection() {
        #expect(TimecodeRate.detect(framesPerSecond: 25.02, dropFrame: false) == .fps25)
        #expect(TimecodeRate.detect(framesPerSecond: 24, dropFrame: false) == .fps24)
        #expect(TimecodeRate.detect(framesPerSecond: 29.97, dropFrame: true) == .fps2997df)
        #expect(TimecodeRate.detect(framesPerSecond: 29.975, dropFrame: false) == .fps2997ndf)
        #expect(TimecodeRate.detect(framesPerSecond: 30.0, dropFrame: false) == .fps30)
        #expect(TimecodeRate.detect(framesPerSecond: 30.0, dropFrame: true) == .fps2997df)
        #expect(TimecodeRate.detect(framesPerSecond: 27, dropFrame: false) == nil)
    }

    @Test func mtcQuarterFramesAndFullFrame() {
        var decoder = MTCDecoder()
        let pieces: [UInt8] = [0x04, 0x10, 0x23, 0x30, 0x42, 0x50, 0x61, 0x72]  // 01:02:03:04 @ 25 fps
        for piece in pieces.dropLast() { #expect(decoder.quarterFrame(piece) == nil) }
        #expect(decoder.quarterFrame(pieces.last!) == Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, rate: .fps25))
        #expect(decoder.quarterFrame(0x72) == nil)  // piece 7 without a fresh sequence
        #expect(MTCDecoder.fullFrame([0xF0, 0x7F, 0x7F, 0x01, 0x01, 0x21, 0x02, 0x03, 0x04, 0xF7]) == Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, rate: .fps25))
        #expect(MTCDecoder.fullFrame([0xF0, 0x7F, 0x7F, 0x01, 0x01, 0x41, 0x02, 0x03, 0x04, 0xF7])?.rate == .fps2997df)
        #expect(MTCDecoder.fullFrame([0xF0, 0x7F]) == nil)
    }
}

@Suite struct LTCTests {
    static func frames(from start: Timecode, count: Int) -> [Timecode] {
        (0..<count).map { Timecode(frameCount: start.frameCount + $0, rate: start.rate) }
    }

    @Test func wordParityIsEven() {
        for tc in Self.frames(from: Timecode(hours: 23, minutes: 59, seconds: 58, frames: 0, rate: .fps25), count: 60) {
            #expect(LTCEncoder.bits(for: tc).filter { $0 }.count % 2 == 0)
        }
    }

    @Test func locksWithinTwoFramesAt25() {
        let start = Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, rate: .fps25)
        let frames = Self.frames(from: start, count: 30)
        var decoder = LTCDecoder(sampleRate: 48_000)
        let decoded = decoder.process(LTCEncoder.samples(frames: frames, sampleRate: 48_000))
        #expect(decoded.count >= 28)
        #expect(decoded.first!.timecode.frameCount - start.frameCount <= 2)
        for (a, b) in zip(decoded, decoded.dropFirst()) {
            #expect(b.timecode.frameCount == a.timecode.frameCount + 1)
        }
        #expect(decoded.last!.timecode.rate == .fps25)
        #expect(abs(decoded.last!.measuredFrameRate - 25) < 0.05)
        #expect(decoded.last!.timecode.hours == 10)
    }

    @Test func decodesDropFrameAcrossAMinuteBoundary() {
        let start = Timecode(hours: 0, minutes: 0, seconds: 59, frames: 20, rate: .fps2997df)
        let frames = Self.frames(from: start, count: 40)
        var decoder = LTCDecoder(sampleRate: 48_000, nominalFrameRate: 30)
        let decoded = decoder.process(LTCEncoder.samples(frames: frames, sampleRate: 48_000))
        #expect(decoded.count >= 38)
        #expect(decoded.last!.timecode.rate == .fps2997df)
        #expect(decoded.contains { $0.timecode.description == "00:01:00;02" })
        #expect(!decoded.contains { $0.timecode.description == "00:01:00;00" })
        #expect(abs(decoded.last!.measuredFrameRate - 29.97) < 0.05)
    }

    @Test func chunkedInputDecodesLikeWholeInput() {
        let frames = Self.frames(from: Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, rate: .fps30), count: 12)
        let samples = frames.flatMap { LTCEncoder.samples(frames: [$0], sampleRate: 44_100, amplitude: 0.3) }
        var whole = LTCDecoder(sampleRate: 44_100, nominalFrameRate: 30)
        let expected = whole.process(samples)
        var chunked = LTCDecoder(sampleRate: 44_100, nominalFrameRate: 30)
        var collected: [LTCFrame] = []
        for chunk in stride(from: 0, to: samples.count, by: 777) {
            collected += chunked.process(Array(samples[chunk..<min(samples.count, chunk + 777)]))
        }
        #expect(collected == expected)
        #expect(expected.count >= 10)
    }
}
