// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Testing

@testable import FanousEngine

/// A slave's clock is set from its master's entry, never integrated (DESIGN.md §23.3).
struct SlaveClockTests {
    static let interval = 1.0 / 60

    static func entry(position: Double, fps: Float = 50, rate: Float = 50, direction: Int8 = 1, finished: Bool = false)
        -> SyncPacket.Layer
    {
        SyncPacket.Layer(
            group: 1, layer: 1, mediaKey: 0x0101, fps: fps, position: position, direction: direction,
            finished: finished, rate: rate)
    }

    @Test func aSlowerFileKeepsTheSameTime() {
        // a 25 fps slave against a 50 fps master: frame 100 of the master is frame 50 of the slave, 0.1 s later 52.5
        var clock = LayerClock()
        let fresh = SlaveClock.follow(
            &clock, entry: Self.entry(position: 100), age: 0, dt: Self.interval, interval: Self.interval, fps: 25,
            frameCount: 500)
        #expect(fresh.state == .locked)
        #expect(clock.position == 50)
        _ = SlaveClock.follow(
            &clock, entry: Self.entry(position: 100), age: 0.02, dt: Self.interval, interval: Self.interval, fps: 25,
            frameCount: 500)
        #expect(abs(clock.position - 50.5) < 1e-9, "extrapolated by the entry's age at the master's rate, then scaled")
    }

    @Test func lockedSetsAndClampsToTheFile() {
        var clock = LayerClock()
        _ = SlaveClock.follow(
            &clock, entry: Self.entry(position: 900), age: 0, dt: Self.interval, interval: Self.interval, fps: 50,
            frameCount: 100)
        #expect(clock.position == 99, "a longer master file holds the slave's last frame")
        _ = SlaveClock.follow(
            &clock, entry: Self.entry(position: -3, rate: 0), age: 0, dt: Self.interval, interval: Self.interval,
            fps: 50, frameCount: 100)
        #expect(clock.position == 0)
    }

    @Test func stateFollowsTheAge() {
        #expect(SlaveClock.state(age: 0.02, interval: Self.interval) == .locked)
        #expect(
            SlaveClock.state(age: 0.033, interval: Self.interval) == .locked,
            "a 30 fps master against a 60 fps slave: one packet every other tick stays locked")
        #expect(SlaveClock.state(age: 0.06, interval: Self.interval) == .freewheel, "past the 50 ms lock window")
        #expect(SlaveClock.state(age: 0.06, interval: 1.0 / 24) == .locked, "1.5 ticks at 24 fps is longer")
        #expect(SlaveClock.state(age: 1.9, interval: Self.interval) == .freewheel)
        #expect(SlaveClock.state(age: 2.1, interval: Self.interval) == .lost, "past the freewheel time")
    }

    @Test func aWrapNeverReachesTheFrameCount() {
        #expect(SlaveClock.wrap(-1e-17, 100) < 100, "−1e-17 + 100 rounds to 100")
        #expect(Int(SlaveClock.wrap(-1e-17, 100)) == 99)
        #expect(SlaveClock.wrap(-0.5, 100) == 99.5)
        #expect(SlaveClock.wrap(100.5, 100) == 0.5)
    }

    @Test func freewheelAdvancesByTheEntrysRateAndWrapsAtTheEnd() {
        var clock = LayerClock()
        clock.position = 98.5
        // a stale entry: the clock moves on at the entry's rate (25 fps master, 1×), not where the entry points
        let stale = Self.entry(position: 10, fps: 25, rate: 25)
        let first = SlaveClock.follow(
            &clock, entry: stale, age: 0.5, dt: 0.04, interval: Self.interval, fps: 25, frameCount: 100)
        #expect(first.state == .freewheel)
        #expect(abs(clock.position - 99.5) < 1e-9)
        let second = SlaveClock.follow(
            &clock, entry: stale, age: 2.5, dt: 0.04, interval: Self.interval, fps: 25, frameCount: 100)
        #expect(second.state == .lost, "lost keeps freewheeling")
        #expect(abs(clock.position - 0.5) < 1e-9, "wrapped within the file like a loop")
        // the next fresh entry snaps it back
        _ = SlaveClock.follow(
            &clock, entry: Self.entry(position: 40, fps: 25, rate: 25), age: 0, dt: 0.04, interval: Self.interval,
            fps: 25, frameCount: 100)
        #expect(clock.position == 40)
    }

    @Test func finishedAndDirectionPassThrough() {
        var clock = LayerClock()
        _ = SlaveClock.follow(
            &clock, entry: Self.entry(position: 20, rate: -50, direction: -1), age: 0, dt: Self.interval,
            interval: Self.interval, fps: 50, frameCount: 100)
        #expect(clock.direction == -1)
        #expect(!clock.finished)
        _ = SlaveClock.follow(
            &clock, entry: Self.entry(position: 0, rate: 0, direction: -1, finished: true), age: 0, dt: Self.interval,
            interval: Self.interval, fps: 50, frameCount: 100)
        #expect(clock.finished)
    }

    @Test func offsetIsTheCorrectionALockedTickApplies() {
        var clock = LayerClock()
        clock.position = 10
        // where the slave would have been (10 + 50 fps × 20 ms = 11) is where the entry says: no correction
        let even = SlaveClock.follow(
            &clock, entry: Self.entry(position: 11), age: 0, dt: 0.02, interval: Self.interval, fps: 50, frameCount: 100
        )
        #expect(abs(even.offsetMs) < 1e-9)
        // one frame ahead of that: 20 ms at 50 fps
        let ahead = SlaveClock.follow(
            &clock, entry: Self.entry(position: 13), age: 0, dt: 0.02, interval: Self.interval, fps: 50, frameCount: 100
        )
        #expect(abs(ahead.offsetMs - 20) < 1e-6)
        // the master looping (frame 99 → 0) is no correction
        clock.position = 99.5
        let loop = SlaveClock.follow(
            &clock, entry: Self.entry(position: 0.5), age: 0, dt: 0.02, interval: Self.interval, fps: 50,
            frameCount: 100)
        #expect(abs(loop.offsetMs) < 1e-6)
    }
}
