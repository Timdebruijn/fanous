// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// MIDI Time Code: quarter-frame assembly and full-frame SysEx.
public struct MTCDecoder: Sendable {
    private var pieces: [UInt8?] = Array(repeating: nil, count: 8)

    public init() {}

    /// Feed the data byte of an F1 quarter-frame message. Returns the assembled
    /// timecode when piece 7 completes a sequence; it is the time at piece 0,
    /// so a chasing clock adds two frames.
    public mutating func quarterFrame(_ data: UInt8) -> Timecode? {
        let piece = Int(data >> 4)
        guard piece < 8 else { return nil }
        if piece == 0 { pieces = Array(repeating: nil, count: 8) }
        pieces[piece] = data & 0x0F
        guard piece == 7, pieces.allSatisfy({ $0 != nil }) else { return nil }
        let p = pieces.map { $0! }
        pieces = Array(repeating: nil, count: 8)  // a sequence yields one timecode
        return Timecode(
            hours: Int(p[6] | (p[7] & 0x1) << 4), minutes: Int(p[4] | (p[5] & 0x3) << 4),
            seconds: Int(p[2] | (p[3] & 0x3) << 4), frames: Int(p[0] | (p[1] & 0x1) << 4),
            rate: Self.rate(code: (p[7] >> 1) & 0x3))
    }

    /// F0 7F 7F 01 01 hh mm ss ff F7 (hh bits 5–6 = rate).
    public static func fullFrame(_ sysex: [UInt8]) -> Timecode? {
        guard sysex.count == 10, sysex[0] == 0xF0, sysex[1] == 0x7F, sysex[3] == 0x01, sysex[4] == 0x01, sysex[9] == 0xF7
        else { return nil }
        return Timecode(
            hours: Int(sysex[5] & 0x1F), minutes: Int(sysex[6]), seconds: Int(sysex[7]), frames: Int(sysex[8]),
            rate: rate(code: (sysex[5] >> 5) & 0x3))
    }

    static func rate(code: UInt8) -> TimecodeRate {
        switch code {
        case 0: .fps24
        case 1: .fps25
        case 2: .fps2997df
        default: .fps30
        }
    }
}
