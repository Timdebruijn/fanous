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
        #expect(frames[0] == 98)
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
}
