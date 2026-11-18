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
    /// Set by `retrigger`: the next `advance` shows the first frame instead of one tick past it (B372).
    var triggered = false

    public init() {}

    /// How far before a frame's start the shown frame turns over, in frames (B372): frame k shows from position
    /// k − 11/24 to k + 13/24. Not 0 (the floor): at matched rates the position lands on a whole frame every tick and
    /// noise picks between two frames. Not 1/2 (the nearest frame): at a half rate (25p on 50 Hz, half speed) it lands
    /// on a half frame every other tick. 11/24 stays 1/24 frame clear of every position a trigger leads to at the rate
    /// ratios with a denominator dividing 8 or 12 (1, 1/2, 1/3, 1/4, 1/8, 5/6 for 50p on 60 Hz, 5/12 for 25p on 60 Hz)
    /// and 0.058 frame clear at 2/5 (24p on 60 Hz).
    static let lead = 11.0 / 24

    /// The frame shown at `position` in `lo…hi`; from `hi` + 13/24 on (a loop's last 11/24 frame) it is `lo` again.
    public func frame(lo: Int, hi: Int) -> Int {
        let f = (position + Self.lead).rounded(.down)
        return f > Double(hi) ? lo : max(lo, Int(f))
    }

    /// Jumps to the start of the range for `mode` (the end for reverse modes).
    public mutating func retrigger(mode: PlayMode, inFrame: Int, outFrame: Int, frameCount: Int) {
        let (lo, hi) = Self.range(inFrame, outFrame, frameCount)
        position = mode.isReverse ? hi : lo
        direction = 1
        finished = false
        triggered = true
    }

    /// Advances by `dt` seconds and returns the frame to show; nil means black
    /// (a once-then-black mode that has finished, or an empty file).
    public mutating func advance(
        dt: Double, fps: Double, speed: Double, mode: PlayMode, inFrame: Int, outFrame: Int, frameCount: Int
    ) -> Int? {
        let first = triggered
        triggered = false
        guard frameCount > 0, fps > 0 else { return nil }
        let (lo, hi) = Self.range(inFrame, outFrame, frameCount)
        if hi <= lo {
            position = lo
            return Int(lo)
        }
        switch mode {
        case .freeze, .scrub, .timecode:
            position = min(hi, max(lo, position))
            return frame(lo: Int(lo), hi: Int(hi))
        default:
            break
        }
        if finished { return mode.endsBlack ? nil : frame(lo: Int(lo), hi: Int(hi)) }
        if first { return frame(lo: Int(lo), hi: Int(hi)) }
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
        default:  // once modes: the end frame shows for its whole frame, as every other frame
            if next + Self.lead >= hi + 1 {
                next = hi
                finished = true
            } else if next + Self.lead < lo {
                next = lo
                finished = true
            }
        }
        position = next
        if finished && mode.endsBlack { return nil }
        return frame(lo: Int(lo), hi: Int(hi))
    }

    static func range(_ inFrame: Int, _ outFrame: Int, _ frameCount: Int) -> (Double, Double) {
        let last = frameCount - 1
        let lo = max(0, min(inFrame, last))
        let hi = max(lo, min(outFrame, last))
        return (Double(lo), Double(hi))
    }
}
