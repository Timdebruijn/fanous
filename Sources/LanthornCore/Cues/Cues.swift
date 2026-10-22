// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

public struct CueValue: Codable, Equatable, Sendable {
    public var fixture: FixtureRef
    public var parameter: ParameterID
    public var raw: UInt16
    public var fadeTime: Double?

    public init(fixture: FixtureRef, parameter: ParameterID, raw: UInt16, fadeTime: Double? = nil) {
        self.fixture = fixture
        self.parameter = parameter
        self.raw = raw
        self.fadeTime = fadeTime
    }
}

public struct Cue: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var number: Double
    public var name: String
    public var fadeTime: Double
    public var values: [CueValue]
    public var timecodeTrigger: Timecode?
    public var followTime: Double?

    public init(
        id: UUID = UUID(), number: Double, name: String = "", fadeTime: Double = 0, values: [CueValue] = [],
        timecodeTrigger: Timecode? = nil, followTime: Double? = nil
    ) {
        self.id = id
        self.number = number
        self.name = name
        self.fadeTime = fadeTime
        self.values = values
        self.timecodeTrigger = timecodeTrigger
        self.followTime = followTime
    }
}

public struct CueList: Codable, Equatable, Sendable {
    public private(set) var cues: [Cue]

    public init(cues: [Cue] = []) { self.cues = cues.sorted { $0.number < $1.number } }

    public mutating func insert(_ cue: Cue) {
        cues.removeAll { $0.id == cue.id || $0.number == cue.number }
        cues.append(cue)
        cues.sort { $0.number < $1.number }
    }

    public mutating func remove(id: UUID) { cues.removeAll { $0.id == id } }

    public func index(ofNumber number: Double) -> Int? { cues.firstIndex { $0.number == number } }
}

public struct CueOutput: Equatable, Sendable {
    public var fixture: FixtureRef
    public var parameter: ParameterID
    public var raw: UInt16
}

/// Go/back/goto with per-cue fades, timecode triggers and follows (DESIGN.md §15.2).
/// Pure: feed it the clock, read `tick` output into the resolver as the cue source.
public struct CueEngine: Sendable {
    struct Key: Hashable, Sendable {
        let fixture: FixtureRef
        let parameter: ParameterID
    }

    struct Fade: Sendable {
        var from: Double
        var to: Double
        var start: TimeInterval
        var duration: Double
    }

    public private(set) var list: CueList
    public private(set) var currentIndex: Int?
    private var held: [Key: UInt16] = [:]
    private var fades: [Key: Fade] = [:]
    private var follow: (index: Int, fireAt: TimeInterval)?
    private var lastTimecodeFrame: Int?

    public init(list: CueList) { self.list = list }

    public mutating func replace(list: CueList) {
        self.list = list
        if let index = currentIndex, index >= list.cues.count { currentIndex = nil }
    }

    public var current: Cue? { currentIndex.map { list.cues[$0] } }
    public var next: Cue? {
        let index = (currentIndex ?? -1) + 1
        return index < list.cues.count ? list.cues[index] : nil
    }

    public mutating func go(at time: TimeInterval) {
        let index = (currentIndex ?? -1) + 1
        guard index < list.cues.count else { return }
        fire(index: index, at: time)
    }

    public mutating func back(at time: TimeInterval) {
        guard let index = currentIndex, index > 0 else { return }
        fire(index: index - 1, at: time)
    }

    public mutating func goto(number: Double, at time: TimeInterval) {
        guard let index = list.index(ofNumber: number) else { return }
        fire(index: index, at: time)
    }

    /// Fires every cue whose trigger lies in (previous, current]. A jump backwards re-arms.
    public mutating func timecode(_ timecode: Timecode, at time: TimeInterval) {
        let frame = timecode.frameCount
        defer { lastTimecodeFrame = frame }
        guard let last = lastTimecodeFrame, frame > last, frame - last < timecode.rate.nominalFrames * 5 else { return }
        for (index, cue) in list.cues.enumerated() {
            guard let trigger = cue.timecodeTrigger else { continue }
            let triggerFrame = trigger.frameCount
            if triggerFrame > last && triggerFrame <= frame { fire(index: index, at: time) }
        }
    }

    private mutating func fire(index: Int, at time: TimeInterval) {
        let cue = list.cues[index]
        currentIndex = index
        for value in cue.values {
            let key = Key(fixture: value.fixture, parameter: value.parameter)
            let spec = ChannelMap.spec(value.parameter)
            let duration = value.fadeTime ?? cue.fadeTime
            let from = Double(currentRaw(key, at: time) ?? spec.defaultRaw)
            if spec.isContinuous && duration > 0 {
                fades[key] = Fade(from: from, to: Double(spec.clamped(value.raw)), start: time, duration: duration)
            } else {
                fades[key] = nil
                held[key] = spec.clamped(value.raw)
            }
        }
        follow = cue.followTime.map { (index + 1, time + $0) }
    }

    private func currentRaw(_ key: Key, at time: TimeInterval) -> UInt16? {
        if let fade = fades[key] { return UInt16(fade.value(at: time).rounded()) }
        return held[key]
    }

    /// Advances fades and follows; returns every value the cue list currently asserts.
    public mutating func tick(at time: TimeInterval) -> [CueOutput] {
        if let follow, time >= follow.fireAt {
            self.follow = nil
            if follow.index < list.cues.count { fire(index: follow.index, at: time) }
        }
        for (key, fade) in fades where time >= fade.start + fade.duration {
            held[key] = UInt16(fade.to.rounded())
            fades[key] = nil
        }
        var outputs = held.map { CueOutput(fixture: $0.key.fixture, parameter: $0.key.parameter, raw: $0.value) }
        for (key, fade) in fades {
            outputs.append(CueOutput(fixture: key.fixture, parameter: key.parameter, raw: UInt16(fade.value(at: time).rounded())))
        }
        return outputs.sorted { "\($0.fixture) \($0.parameter)" < "\($1.fixture) \($1.parameter)" }
    }

    public var isFading: Bool { !fades.isEmpty }
}

extension CueEngine.Fade {
    func value(at time: TimeInterval) -> Double {
        guard duration > 0 else { return to }
        let progress = min(1, max(0, (time - start) / duration))
        return from + (to - from) * progress
    }
}
