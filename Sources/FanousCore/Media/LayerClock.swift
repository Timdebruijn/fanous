// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

extension PlayMode {
    public var isReverse: Bool { self == .loopReverse || self == .onceHoldReverse || self == .onceBlackReverse }
    public var endsBlack: Bool { self == .onceBlack || self == .onceBlackReverse }
}

/// Playback position of one layer, in media frames (DESIGN.md §4.2). Pure and
/// allocation-free: the compositor calls `advance` once per tick.
public struct LayerClock: Sendable, Equatable {
    public var position: Double = 0
    /// +1 or −1; bounce flips it.
    public var direction: Double = 1
    public var finished = false

    public init() {}

    /// Jumps to the start of the range for `mode` (the end for reverse modes).
    public mutating func retrigger(mode: PlayMode, inFrame: Int, outFrame: Int, frameCount: Int) {
        let (lo, hi) = Self.range(inFrame, outFrame, frameCount)
        position = mode.isReverse ? hi : lo
        direction = 1
        finished = false
    }

    /// Advances by `dt` seconds and returns the frame to show; nil means black
    /// (a once-then-black mode that has finished, or an empty file).
    public mutating func advance(
        dt: Double, fps: Double, speed: Double, mode: PlayMode, inFrame: Int, outFrame: Int, frameCount: Int
    ) -> Int? {
        guard frameCount > 0, fps > 0 else { return nil }
        let (lo, hi) = Self.range(inFrame, outFrame, frameCount)
        if hi <= lo {
            position = lo
            return Int(lo)
        }
        switch mode {
        case .freeze, .scrub, .timecode:
            position = min(hi, max(lo, position))
            return Int(position)
        default:
            break
        }
        if finished { return mode.endsBlack ? nil : Int(position) }
        let span = hi - lo + 1
        let step = dt * fps * speed / 100 * (mode.isReverse ? -1 : 1) * direction
        var next = position + step
        switch mode {
        case .loopForward, .loopReverse:
            next = lo + (next - lo).truncatingRemainder(dividingBy: span)
            if next < lo { next += span }
        case .bounce:
            if next > hi {
                next = 2 * hi - next
                direction = -direction
            } else if next < lo {
                next = 2 * lo - next
                direction = -direction
            }
            next = min(hi, max(lo, next))
        default:  // once modes
            if next > hi {
                next = hi
                finished = true
            } else if next < lo {
                next = lo
                finished = true
            }
        }
        position = next
        if finished && mode.endsBlack { return nil }
        return Int(min(hi, max(lo, next)))
    }

    static func range(_ inFrame: Int, _ outFrame: Int, _ frameCount: Int) -> (Double, Double) {
        let last = frameCount - 1
        let lo = max(0, min(inFrame, last))
        let hi = max(lo, min(outFrame, last))
        return (Double(lo), Double(hi))
    }
}
