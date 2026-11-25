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

    /// B291: one corrupted frame, 01:00:01:10 read as 01:00:05:10 (bit 18, seconds +4), neither moves the chase nor fires
    /// the 01:00:05:00 cue early. One flipped bit leaves the word with odd parity; two (bit 4 is a user bit) keep it even,
    /// so only the continuity check stands between that frame and the chase.
    @Test(arguments: [[18], [18, 4]]) func aCorruptedFrameNeverMovesTheChaseOrFiresACue(flipped: [Int]) {
        let start = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, rate: .fps25)
        let frames = Self.frames(from: start, count: 150)  // 6 s
        var decoder = LTCDecoder(sampleRate: 48_000)
        let decoded = decoder.process(LTCEncoder.samples(frames: frames, sampleRate: 48_000, flipping: [35: flipped])).map(\.timecode)
        for (a, b) in zip(decoded, decoded.dropFirst()) {
            #expect(b.frameCount == a.frameCount + 1 || (a == frames[34] && b == frames[36]), "\(a) → \(b)")
        }
        #expect(decoded.contains(frames[34]) && decoded.contains(frames[36]) && !decoded.contains(frames[35]), "only the corrupted frame is missing")
        let trigger = Timecode(hours: 1, minutes: 0, seconds: 5, frames: 0, rate: .fps25)
        var cues = CueEngine(list: CueList(cues: [Cue(number: 1, timecodeTrigger: trigger)]))
        let firedAt = decoded.first { cues.timecode($0, at: 0); return cues.current != nil }
        #expect(firedAt == trigger, "fired at \(String(describing: firedAt))")
    }

    /// B291: a word with odd parity (the polarity correction bit wrong) never starts the chase.
    @Test func wordsWithOddParityNeverLock() {
        let frames = Self.frames(from: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, rate: .fps25), count: 50)
        var decoder = LTCDecoder(sampleRate: 48_000)
        let flipped = Dictionary(uniqueKeysWithValues: frames.indices.map { ($0, [4]) })
        #expect(decoder.process(LTCEncoder.samples(frames: frames, sampleRate: 48_000, flipping: flipped)).isEmpty)
    }

    /// B291: a decoder started at 25 fps (as `LTCInput` starts it) on a sender that runs, stops for half a second and
    /// starts again elsewhere reads every frame at the sender's rate, never at the 25 fps fallback.
    @Test(arguments: [TimecodeRate.fps30, .fps2997ndf, .fps2997df]) func aRestartedSenderKeepsItsRate(rate: TimecodeRate) {
        let first = Self.frames(from: Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, rate: rate), count: 60)
        let second = Self.frames(from: Timecode(hours: 10, minutes: 0, seconds: 30, frames: 0, rate: rate), count: 60)
        let samples = LTCEncoder.samples(frames: first, sampleRate: 48_000) + [Float](repeating: 0, count: 24_000)
            + LTCEncoder.samples(frames: second, sampleRate: 48_000)
        var decoder = LTCDecoder(sampleRate: 48_000, nominalFrameRate: 25)
        let decoded = decoder.process(samples).map(\.timecode)
        let wrong = decoded.filter { $0.rate != rate }
        #expect(wrong.isEmpty, "\(wrong.count) frames at another rate, first \(String(describing: wrong.first))")
        let chased = decoded.filter { second.contains($0) }
        // every frame but its first, held until the next continues it, and its last, whose sync word no transition ends
        #expect(chased.count == 58 && chased.first == second[1], "\(chased.count) frames of the second run, from \(String(describing: chased.first))")
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
