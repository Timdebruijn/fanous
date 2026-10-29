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
    private let threshold: Float

    public init(sampleRate: Double, nominalFrameRate: Double = 25, threshold: Float = 0.1) {
        self.sampleRate = sampleRate
        self.bitPeriod = sampleRate / (nominalFrameRate * 80)
        self.threshold = threshold
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
        bitPeriod += (interval - bitPeriod) / 16
        return push(bit: 0, at: index)
    }

    private mutating func push(bit: UInt128, at index: Int64) -> LTCFrame? {
        register = (register >> 1) | (bit << 79)
        guard UInt16(truncatingIfNeeded: register >> 64) == Self.syncWord else { return nil }
        defer { lastSyncIndex = index }
        var measured = sampleRate / bitPeriod / 80
        if lastSyncIndex >= 0 {
            frameRates.append(sampleRate / Double(index - lastSyncIndex))
            if frameRates.count > 8 { frameRates.removeFirst() }
            measured = frameRates.reduce(0, +) / Double(frameRates.count)
        }
        func field(_ from: Int, _ count: Int) -> Int { Int((register >> UInt128(from)) & ((1 << UInt128(count)) - 1)) }
        let dropFrame = field(10, 1) == 1
        let rate = TimecodeRate.detect(framesPerSecond: measured, dropFrame: dropFrame) ?? (dropFrame ? .fps2997df : .fps25)
        let timecode = Timecode(
            hours: field(48, 4) + 10 * field(56, 2), minutes: field(32, 4) + 10 * field(40, 3),
            seconds: field(16, 4) + 10 * field(24, 3), frames: field(0, 4) + 10 * field(8, 2), rate: rate)
        return LTCFrame(timecode: timecode, endSampleIndex: index, measuredFrameRate: measured)
    }
}

/// LTC generator (tests now, timecode output later).
public enum LTCEncoder {
    /// 80 bits in transmission order, bit 27 set so the word has an even number of ones.
    public static func bits(for timecode: Timecode, userBits: UInt32 = 0) -> [Bool] {
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
        for (nibble, position) in [4, 12, 20, 28, 36, 44, 52, 60].enumerated() {
            set(Int(userBits >> (nibble * 4)) & 0xF, position, 4)
        }
        let sync: [Bool] = [false, false, true, true, true, true, true, true, true, true, true, true, true, true, false, true]
        word.replaceSubrange(64..<80, with: sync)
        if word.filter({ $0 }).count % 2 == 1 { word[27] = true }
        return word
    }

    public static func samples(frames: [Timecode], sampleRate: Double, amplitude: Float = 0.8) -> [Float] {
        var out: [Float] = []
        var level = amplitude
        var position = 0.0  // in samples
        for frame in frames {
            let cell = sampleRate / frame.rate.exactFrameRate / 80
            for bit in bits(for: frame) {
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
