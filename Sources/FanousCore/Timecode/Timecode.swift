// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

public enum TimecodeRate: String, Codable, Sendable, CaseIterable {
    case fps24, fps25, fps2997df, fps2997ndf, fps30

    public var nominalFrames: Int {
        switch self {
        case .fps24: 24
        case .fps25: 25
        case .fps2997df, .fps2997ndf, .fps30: 30
        }
    }

    public var isDropFrame: Bool { self == .fps2997df }

    public var exactFrameRate: Double {
        switch self {
        case .fps24: 24
        case .fps25: 25
        case .fps2997df, .fps2997ndf: 30000.0 / 1001.0
        case .fps30: 30
        }
    }

    public var label: String {
        switch self {
        case .fps24: "24"
        case .fps25: "25"
        case .fps2997df: "29.97 DF"
        case .fps2997ndf: "29.97 NDF"
        case .fps30: "30"
        }
    }

    /// Nearest standard rate to a measured frame rate (within 1 %), honouring the drop-frame flag.
    public static func detect(framesPerSecond: Double, dropFrame: Bool) -> TimecodeRate? {
        let candidates: [TimecodeRate] = [.fps24, .fps25, .fps2997ndf, .fps30]
        guard let best = candidates.min(by: { abs($0.exactFrameRate - framesPerSecond) < abs($1.exactFrameRate - framesPerSecond) }),
            abs(best.exactFrameRate - framesPerSecond) <= best.exactFrameRate * 0.01
        else { return nil }
        if dropFrame && (best == .fps2997ndf || best == .fps30) { return .fps2997df }
        return best
    }
}

public struct Timecode: Hashable, Codable, Sendable, CustomStringConvertible {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int
    public var rate: TimecodeRate

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int, rate: TimecodeRate) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.rate = rate
    }

    public init(frameCount: Int, rate: TimecodeRate) {
        let fps = rate.nominalFrames
        var count = max(0, frameCount)
        if rate.isDropFrame {
            let dropped = 2
            let per10Minutes = fps * 600 - dropped * 9
            let perMinute = fps * 60 - dropped
            let blocks = count / per10Minutes
            let remainder = count % per10Minutes
            count += dropped * 9 * blocks
            if remainder > dropped { count += dropped * ((remainder - dropped) / perMinute) }
        }
        frames = count % fps
        seconds = count / fps % 60
        minutes = count / (fps * 60) % 60
        hours = count / (fps * 3600) % 24
        self.rate = rate
    }

    /// Frames since 00:00:00:00, accounting for dropped frame numbers.
    public var frameCount: Int {
        let fps = rate.nominalFrames
        var count = ((hours * 3600 + minutes * 60 + seconds) * fps) + frames
        if rate.isDropFrame {
            let totalMinutes = hours * 60 + minutes
            count -= 2 * (totalMinutes - totalMinutes / 10)
        }
        return count
    }

    public var secondsValue: Double { Double(frameCount) / rate.exactFrameRate }

    public var description: String {
        String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, rate.isDropFrame ? ";" : ":", frames)
    }
}
