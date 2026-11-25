// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

public struct LTCFrame: Equatable, Sendable {
    public let timecode: Timecode
    /// Sample index (since the decoder was created) of the last sync-word transition.
    public let endSampleIndex: Int64
    public let measuredFrameRate: Double
}

/// SMPTE 12M linear timecode decoder for forward-running audio.
/// Biphase mark: every bit cell starts with a transition, a 1 has one more at mid-cell.
/// ponytail: fixed hysteresis threshold, no AGC; real-world captures in Phase 7 decide if that is needed.
public struct LTCDecoder: Sendable {
    public static let syncWord: UInt16 = 0xBFFC  // bits 64…79 in transmission order: 0011 1111 1111 1101

    public let sampleRate: Double
    private var polarityHigh = false
    private var sampleIndex: Int64 = 0
    private var lastTransition: Int64 = -1
    private var bitPeriod: Double
    private var halfPending = false
    private var register: UInt128 = 0
    private var lastSyncIndex: Int64 = -1
    private var frameRates: [Double] = []
    /// B291: the last frame's rate, kept when a dropout or a restarted sender empties the average.
    private var lastRate: TimecodeRate?
    /// B291: the address the next frame should carry, and a frame that did not, held until the next one continues it.
    private var expected: Timecode?
    private var held: Timecode?
    private let threshold: Float = 0.1

    public init(sampleRate: Double, nominalFrameRate: Double = 25) {
        self.sampleRate = sampleRate
        self.bitPeriod = sampleRate / (nominalFrameRate * 80)
    }

    public mutating func process(_ samples: [Float]) -> [LTCFrame] {
        var frames: [LTCFrame] = []
        for sample in samples {
            let crossed = polarityHigh ? sample < -threshold : sample > threshold
            if crossed {
                polarityHigh.toggle()
                if let frame = transition(at: sampleIndex) { frames.append(frame) }
            }
            sampleIndex += 1
        }
        return frames
    }

    private mutating func transition(at index: Int64) -> LTCFrame? {
        defer { lastTransition = index }
        guard lastTransition >= 0 else { return nil }
        let interval = Double(index - lastTransition)
        if interval < 0.75 * bitPeriod {
            if halfPending {
                halfPending = false
                bitPeriod += (2 * interval - bitPeriod) / 16
                return push(bit: 1, at: index)
            }
            halfPending = true
            return nil
        }
        halfPending = false
        bitPeriod += (min(interval, 2 * bitPeriod) - bitPeriod) / 16  // a gap (silence, a restarted sender) moves it by a sixteenth at most (B291)
        return push(bit: 0, at: index)
    }

    private mutating func push(bit: UInt128, at index: Int64) -> LTCFrame? {
        register = (register >> 1) | (bit << 79)
        guard UInt16(truncatingIfNeeded: register >> 64) == Self.syncWord else { return nil }
        defer { lastSyncIndex = index }
        if lastSyncIndex >= 0 {
            let fps = sampleRate / Double(index - lastSyncIndex)
            // an interval that is no frame at any rate (a dropout, a restarted sender) starts the average again (B291)
            if TimecodeRate.detect(framesPerSecond: fps, dropFrame: false) == nil {
                frameRates.removeAll(keepingCapacity: true)
            } else {
                frameRates.append(fps)
                if frameRates.count > 8 { frameRates.removeFirst() }
            }
        }
        let measured = frameRates.isEmpty ? sampleRate / bitPeriod / 80 : frameRates.reduce(0, +) / Double(frameRates.count)
        func field(_ from: Int, _ count: Int) -> Int { Int((register >> UInt128(from)) & ((1 << UInt128(count)) - 1)) }
        let dropFrame = field(10, 1) == 1
        // with no intervals to average, the last rate (under this frame's drop-frame flag) goes before the bit-period guess
        let remembered = lastRate.flatMap { TimecodeRate.detect(framesPerSecond: $0.exactFrameRate, dropFrame: dropFrame) }
        let rate = (frameRates.isEmpty ? remembered : nil) ?? TimecodeRate.detect(framesPerSecond: measured, dropFrame: dropFrame) ?? remembered
            ?? (dropFrame ? .fps2997df : .fps25)
        lastRate = rate
        let timecode = Timecode(
            hours: field(48, 4) + 10 * field(56, 2), minutes: field(32, 4) + 10 * field(40, 3),
            seconds: field(16, 4) + 10 * field(24, 3), frames: field(0, 4) + 10 * field(8, 2), rate: rate)
        guard believe(timecode, parityEven: register.nonzeroBitCount % 2 == 0) else { return nil }
        return LTCFrame(timecode: timecode, endSampleIndex: index, measuredFrameRate: measured)
    }

    /// B291: a valid frame with the expected address is believed. Any other valid frame with even parity is held and
    /// believed when the next frame continues it (a start, or a jump of the sender), so one corrupted frame never moves the
    /// chase or fires a cue. Parity (SMPTE 12M: the polarity correction bit makes the count of ones in the 80-bit word even,
    /// wherever the rate puts that bit) is asked only of those two frames: a corrupted frame that still carries the
    /// expected address is harmless, and a generator that leaves the bit unset still chases once it is locked.
    private mutating func believe(_ timecode: Timecode, parityEven: Bool) -> Bool {
        func next(_ t: Timecode) -> Timecode { Timecode(frameCount: t.frameCount + 1, rate: t.rate) }
        let believed = timecode.isValid && (timecode == expected || (parityEven && held.map(next) == timecode))
        held = !believed && timecode.isValid && parityEven ? timecode : nil
        expected = believed ? next(timecode) : expected.map(next)
        return believed
    }
}

/// LTC generator (tests now, timecode output later).
public enum LTCEncoder {
    /// 80 bits in transmission order (user bits 0), the polarity correction bit set so the word has an even number of ones.
    public static func bits(for timecode: Timecode) -> [Bool] {
        var word = [Bool](repeating: false, count: 80)
        func set(_ value: Int, _ from: Int, _ count: Int) {
            for i in 0..<count { word[from + i] = (value >> i) & 1 == 1 }
        }
        set(timecode.frames % 10, 0, 4)
        set(timecode.frames / 10, 8, 2)
        word[10] = timecode.rate.isDropFrame
        set(timecode.seconds % 10, 16, 4)
        set(timecode.seconds / 10, 24, 3)
        set(timecode.minutes % 10, 32, 4)
        set(timecode.minutes / 10, 40, 3)
        set(timecode.hours % 10, 48, 4)
        set(timecode.hours / 10, 56, 2)
        let sync: [Bool] = [false, false, true, true, true, true, true, true, true, true, true, true, true, true, false, true]
        word.replaceSubrange(64..<80, with: sync)
        // the polarity correction bit: 27, but 59 at 25 fps (EBU), where 27 is a binary group flag
        if word.filter({ $0 }).count % 2 == 1 { word[timecode.rate == .fps25 ? 59 : 27] = true }
        return word
    }

    /// `flipping`: bits (0…79) to invert in the frame at that index, for corrupted words in tests.
    public static func samples(frames: [Timecode], sampleRate: Double, amplitude: Float = 0.8, flipping: [Int: [Int]] = [:]) -> [Float] {
        var out: [Float] = []
        var level = amplitude
        var position = 0.0  // in samples
        for (index, frame) in frames.enumerated() {
            let cell = sampleRate / frame.rate.exactFrameRate / 80
            var word = bits(for: frame)
            for bit in flipping[index] ?? [] { word[bit].toggle() }
            for bit in word {
                level = -level
                let mid = position + cell / 2
                let end = position + cell
                while Double(out.count) < mid { out.append(level) }
                if bit { level = -level }
                while Double(out.count) < end { out.append(level) }
                position = end
            }
        }
        return out
    }
}
