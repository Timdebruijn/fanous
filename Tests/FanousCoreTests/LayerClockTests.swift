// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import FanousCore

@Suite struct LayerClockTests {
    func run(_ clock: inout LayerClock, ticks: Int, dt: Double = 1.0 / 60, fps: Double = 30, speed: Double = 100, mode: PlayMode, inFrame: Int = 0, outFrame: Int = 999, count: Int = 100) -> [Int?] {
        (0..<ticks).map { _ in clock.advance(dt: dt, fps: fps, speed: speed, mode: mode, inFrame: inFrame, outFrame: outFrame, frameCount: count) }
    }

    @Test func loopsForwardAtNativeRate() {
        var clock = LayerClock()
        let frames = run(&clock, ticks: 240, mode: .loopForward)  // 4 s at 30 fps media = 120 frames → wraps once
        #expect(frames[0] == 0)
        #expect(frames[119] == 59 || frames[119] == 60)
        #expect(frames[239]! < 100)
        #expect(frames.compactMap { $0 }.max()! == 99)
    }

    @Test func speedAndInOutPoints() {
        var clock = LayerClock()
        let frames = run(&clock, ticks: 60, speed: 200, mode: .loopForward, inFrame: 10, outFrame: 19)
        #expect(frames.allSatisfy { (10...19).contains($0!) })
        #expect(frames[59]! >= 10)
        var slow = LayerClock()
        let slowFrames = run(&slow, ticks: 60, speed: 50, mode: .loopForward)
        #expect(slowFrames[59] == 15)
    }

    @Test func onceHoldAndOnceBlack() {
        var hold = LayerClock()
        let held = run(&hold, ticks: 400, mode: .onceHold)
        #expect(held.last! == 99)
        #expect(hold.finished)
        var black = LayerClock()
        let blacked = run(&black, ticks: 400, mode: .onceBlack)
        #expect(blacked.last! == nil)
        #expect(blacked[100]! == 50)
    }

    @Test func reverseAndBounce() {
        var reverse = LayerClock()
        reverse.retrigger(mode: .loopReverse, inFrame: 0, outFrame: 999, frameCount: 100)
        let frames = run(&reverse, ticks: 10, mode: .loopReverse)
        #expect(frames[0] == 99, "the trigger's tick shows the first frame")
        #expect(frames[9]! < 98)
        var bounce = LayerClock()
        let bounced = run(&bounce, ticks: 600, mode: .bounce, count: 50)
        #expect(bounced.compactMap { $0 }.max()! == 49)
        #expect(bounced.compactMap { $0 }.min()! == 0)
        #expect(bounced[299]! < 49)
    }

    @Test func freezeHoldsAndRetriggerRestarts() {
        var clock = LayerClock()
        _ = run(&clock, ticks: 30, mode: .loopForward)
        let frozen = run(&clock, ticks: 30, mode: .freeze)
        #expect(Set(frozen.compactMap { $0 }).count == 1)
        clock.retrigger(mode: .loopForward, inFrame: 5, outFrame: 50, frameCount: 100)
        #expect(clock.position == 5)
        var empty = LayerClock()
        let nothing = empty.advance(dt: 1, fps: 30, speed: 100, mode: .loopForward, inFrame: 0, outFrame: 10, frameCount: 0)
        #expect(nothing == nil)
    }

    // B372: the frame shown is the frame the clock is on, at every rate a show uses, with tick targets that jitter

    /// SplitMix64: the same jitter on every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// The frames a layer shows on `ticks` ticks of a canvas at `hz` from a trigger, with the compositor's `dt` (target
    /// minus last target), each target up to ±`jitter` s off its ideal host time three days after boot.
    func shown(
        fps: Double, hz: Double, speed: Double = 100, jitter: Double = 0, mode: PlayMode = .loopForward, inFrame: Int = 0,
        outFrame: Int = .max, count: Int = 1_000_000, ticks: Int = 3600
    ) -> [Int?] {
        var clock = LayerClock()
        clock.retrigger(mode: mode, inFrame: inFrame, outFrame: outFrame, frameCount: count)
        var rng = Seeded(state: 372)
        let t0 = 259_200.0
        var last = t0 - 1 / hz
        return (0..<ticks).map { k in
            let target = t0 + Double(k) / hz + (jitter > 0 ? Double.random(in: -jitter...jitter, using: &rng) : 0)
            defer { last = target }
            return clock.advance(
                dt: target - last, fps: fps, speed: speed, mode: mode, inFrame: inFrame, outFrame: outFrame, frameCount: count)
        }
    }

    /// How many ticks each frame shows, in order (the last run is cut off by the end of the sequence and left out).
    func holds(_ frames: [Int?]) -> [Int] {
        var runs: [Int] = []
        var count = 0
        for (i, f) in frames.enumerated() {
            if i > 0 && f != frames[i - 1] {
                runs.append(count)
                count = 0
            }
            count += 1
        }
        return runs
    }

    static let jitters: [Double] = [0, 1e-6, 200e-6]

    static let cadences: [(Double, Double, Double, Int, Int, [Int], [Int])] = [
        // fps, hz, speed, frames per tick p/q, the holds of frame 0 and of every frame after it
        (60.0, 60.0, 100.0, 1, 1, [1], [1]),  // matched: main repeated 899 and skipped 899 of 3600 with ±1 µs
        (50, 50, 100, 1, 1, [1], [1]),
        (60000 / 1001, 60000 / 1001, 100, 1, 1, [1], [1]),
        (60, 60, 0, 0, 1, [], []),  // speed 0: frame 0 throughout
        (25, 50, 100, 1, 2, [2], [2]),  // 2-2-2-2, not 1-3
        (30, 60, 100, 1, 2, [2], [2]),
        (60, 60, 50, 1, 2, [2], [2]),
        (60, 60, 25, 1, 4, [3], [4]),  // the first frame shows from its own start: 13/24 of a frame
        (25, 50, 25, 1, 8, [5], [8]),
        (24, 60, 100, 2, 5, [2], [2, 3]),  // 3-2 pulldown
        (25, 60, 100, 5, 12, [2], [2, 3]),
        (50, 60, 100, 5, 6, [1], [1, 2]),
        (60, 60, 200, 2, 1, [1], [1]),
        (25, 60, 300, 5, 4, [1], [1]),
    ]

    @Test func cadenceFollowsTheClock() {
        for (fps, hz, speed, p, q, first, rest) in Self.cadences {
            cadence(fps: fps, hz: hz, speed: speed, p: p, q: q, first: first, rest: rest)
        }
    }

    func cadence(fps: Double, hz: Double, speed: Double, p: Int, q: Int, first: [Int], rest: [Int]) {
        // frame k·p/q + 11/24 rounded down, in whole numbers: what the clock's position says at an ideal tick k
        let expected = (0..<3600).map { k in (24 * p * k + 11 * q) / (24 * q) }
        for jitter in Self.jitters {
            let frames = shown(fps: fps, hz: hz, speed: speed, jitter: jitter)
            #expect(frames == expected, "\(fps) on \(hz) Hz at \(speed) %, ±\(jitter) s")
        }
        let runs = holds(expected)
        #expect(Array(runs.prefix(1)) == first, "\(fps) on \(hz) Hz at \(speed) %")
        #expect(Set(runs.dropFirst()) == Set(rest), "\(fps) on \(hz) Hz at \(speed) %")
        if rest == [2, 3] { #expect(zip(runs.dropFirst(), runs.dropFirst(2)).allSatisfy { $0 + $1 <= 5 }, "never 3-3: \(runs)") }
    }

    @Test func aRateMismatchSkipsOnlyWhatTheRatesDiffer() {
        // 60p on 59.94 Hz: one frame more per 1000 ticks (16.7 s); 59.94p on 60 Hz: one frame less. The position drifts
        // through each boundary at 1/1000 frame per tick, so target jitter of more than about 1/1000 frame (17 µs) can
        // add a repeat-and-skip at a crossing; the engine's targets are whole periods of the mach clock (`PacedThread`).
        for (fps, hz, step) in [(60.0, 60000 / 1001.0, 2), (60000 / 1001.0, 60.0, 0)] {
            for jitter in [0, 1e-6] {
                let frames = shown(fps: fps, hz: hz, jitter: jitter, ticks: 4000).map { $0! }
                let steps = zip(frames, frames.dropFirst()).map { $1 - $0 }
                let odd = steps.indices.filter { steps[$0] != 1 }
                #expect(odd.allSatisfy { steps[$0] == step }, "\(fps) on \(hz): \(odd.map { steps[$0] })")
                #expect((3...4).contains(odd.count))
                #expect(zip(odd, odd.dropFirst()).allSatisfy { $1 - $0 >= 990 }, "\(odd)")
            }
        }
    }

    @Test func loopsWrapOnTheClockWithInAndOutPoints() {
        for jitter in Self.jitters {
            let forward = shown(fps: 60, hz: 60, jitter: jitter, inFrame: 10, outFrame: 19, count: 100, ticks: 200)
            #expect(forward == (0..<200).map { 10 + $0 % 10 })
            let reverse = shown(fps: 60, hz: 60, jitter: jitter, mode: .loopReverse, inFrame: 10, outFrame: 19, count: 100, ticks: 200)
            #expect(reverse == (0..<200).map { 19 - $0 % 10 })
            let half = shown(fps: 25, hz: 50, jitter: jitter, inFrame: 10, outFrame: 19, count: 100, ticks: 200)
            #expect(half == (0..<200).map { 10 + $0 / 2 % 10 })
            let bounce = shown(fps: 60, hz: 60, jitter: jitter, mode: .bounce, inFrame: 10, outFrame: 19, count: 100, ticks: 200)
            #expect(bounce == (0..<200).map { 10 + ($0 % 18 <= 9 ? $0 % 18 : 18 - $0 % 18) }, "each end frame once per turn")
        }
    }

    @Test func onceModesShowTheEndFrameForAWholeFrame() {
        for jitter in Self.jitters {
            let black = shown(fps: 60, hz: 60, jitter: jitter, mode: .onceBlack, count: 10, ticks: 14)
            #expect(black == Array(0...9) + [nil, nil, nil, nil])
            let hold = shown(fps: 60, hz: 60, jitter: jitter, mode: .onceHold, count: 10, ticks: 14)
            #expect(hold == Array(0...9) + [9, 9, 9, 9])
            let reverse = shown(fps: 60, hz: 60, jitter: jitter, mode: .onceBlackReverse, count: 10, ticks: 12)
            #expect(reverse == Array((0...9).reversed()) + [nil, nil])
            let slow = shown(fps: 25, hz: 50, jitter: jitter, mode: .onceBlack, inFrame: 2, outFrame: 5, count: 10, ticks: 10)
            #expect(slow == [2, 2, 3, 3, 4, 4, 5, 5, nil, nil])
        }
    }

    @Test func aPositionSetFromOutsideShowsTheFrameItIsOn() {
        // timecode chase and a sync slave set the position each tick: a whole frame plus float noise is the common case
        for k in [1, 7, 98] {
            for position in [Double(k).nextDown, Double(k).nextUp, Double(k) - 0.4, Double(k) + 0.5] {
                var clock = LayerClock()
                clock.position = position
                #expect(clock.frame(lo: 0, hi: 99) == k, "\(position)")
                #expect(clock.advance(dt: 0.04, fps: 25, speed: 100, mode: .timecode, inFrame: 0, outFrame: 99, frameCount: 100) == k)
            }
        }
        var wrap = LayerClock()
        wrap.position = 99.6  // a slave's wrap within the file, a loop's last 11/24 frame
        #expect(wrap.frame(lo: 0, hi: 99) == 0)
    }
}
