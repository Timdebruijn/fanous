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

    /// B383: a master in a once mode sends rate 0 while its clock shows the end frame, so a slave, which sees no in or
    /// out point, never extrapolates past it: forward to an out point before the file's last frame, reverse to an in
    /// point after frame 0. 25p on 50 Hz, the entry 1.7 ms to 35 ms old (younger than one frame of the content, 40 ms:
    /// the ceiling, see `showsEndFrame`); the slave shows `frame(lo: 0, hi: last)` as `prepare` does. With rate × age
    /// instead (main), forward shows 13 from 1.7 ms, reverse 3 from 20 ms. A bounce turns at both seams within the 40
    /// ticks: on main 3 on the way down from 20 ms and 13 on the way up from 35 ms (here, 25p on 50 Hz).
    @Test(arguments: [PlayMode.onceHold, .onceBlack, .onceHoldReverse, .onceBlackReverse, .bounce])
    func anEndFrameIsNotExtrapolatedPast(_ mode: PlayMode) {
        let lo = 4, hi = 12, frames = 20
        for age in [0.0017, 0.01, 0.02, 0.035] {
            var master = LayerClock()
            master.retrigger(mode: mode, inFrame: lo, outFrame: hi, frameCount: frames)
            var slave = LayerClock()
            var shown: [Int] = []
            for _ in 0..<40 {
                _ = master.advance(dt: 0.02, fps: 25, speed: 100, mode: mode, inFrame: lo, outFrame: hi, frameCount: frames)
                let direction = Float(mode.isReverse ? -1 : 1) * Float(master.direction)
                let moving = !master.finished && !SlaveClock.showsEndFrame(master, mode: mode, lo: lo, hi: hi)
                let entry = Self.entry(
                    position: master.position, fps: 25, rate: moving ? 25 * direction : 0, direction: Int8(direction),
                    finished: master.finished)
                _ = SlaveClock.follow(&slave, entry: entry, age: age, dt: 0.02, interval: 0.02, fps: 25, frameCount: frames)
                shown.append(slave.frame(lo: 0, hi: frames - 1))
            }
            #expect(shown.allSatisfy { (lo...hi).contains($0) }, "age \(age): \(shown)")
            #expect(mode == .bounce ? shown.contains(lo) && shown.contains(hi) : shown.last == (mode.isReverse ? lo : hi), "reaches the end frame")
        }
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

    /// B395: a locked tick that moves the clock by more than the audio's 20 ms tolerance is a jump (the master was
    /// retriggered, or the slave just locked on); the slave's audio then reseeks like the master's. A smaller correction
    /// is not, and a freewheeling tick and the master's loop wrap never are.
    @Test func aLockedTickThatMovesTheClockPastTheToleranceIsAJump() {
        var clock = LayerClock()
        clock.position = 10
        // 20 ms of dt at 50 fps: the slave would be at 11; the entry says 8.5, a jump back of 50 ms
        let back = SlaveClock.follow(
            &clock, entry: Self.entry(position: 8.5), age: 0, dt: 0.02, interval: Self.interval, fps: 50, frameCount: 100)
        #expect(back.jumped && abs(back.offsetMs + 50) < 1e-6)
        // 10 ms off either way: nudged by the render callback, not a jump
        let near = SlaveClock.follow(
            &clock, entry: Self.entry(position: 9), age: 0, dt: 0.02, interval: Self.interval, fps: 50, frameCount: 100)
        #expect(!near.jumped && abs(near.offsetMs + 10) < 1e-6)
        let forward = SlaveClock.follow(
            &clock, entry: Self.entry(position: 12.5), age: 0, dt: 0.02, interval: Self.interval, fps: 50, frameCount: 100)
        #expect(forward.jumped && abs(forward.offsetMs - 50) < 1e-6)
        // freewheeling: the clock is not set from the entry, so nothing jumps however far off it is
        let stale = SlaveClock.follow(
            &clock, entry: Self.entry(position: 60), age: 0.5, dt: 0.02, interval: Self.interval, fps: 50, frameCount: 100)
        #expect(stale.state == .freewheel && !stale.jumped)
        // the master looped: the slave stood clamped at frame 99 (the entry was at 99.5), the entry is at 0.5 now: half a
        // frame on at 50 fps, no jump; at 25 fps the same wrap is a whole frame (40 ms) and reseeks, as the producer does
        // there anyway
        clock.position = 99
        let wrap = SlaveClock.follow(
            &clock, entry: Self.entry(position: 0.5), age: 0, dt: 0.02, interval: Self.interval, fps: 50, frameCount: 100)
        #expect(!wrap.jumped && abs(wrap.offsetMs - 10) < 1e-6)
        clock.position = 99
        let slowWrap = SlaveClock.follow(
            &clock, entry: Self.entry(position: 0.5, fps: 25, rate: 25), age: 0, dt: 0.02, interval: Self.interval, fps: 25, frameCount: 100)
        #expect(slowWrap.jumped && abs(slowWrap.offsetMs - 40) < 1e-6)
        // a slave tick 30 ms late (50 ms of host time for a 20 ms target step) under a remote master: the entry aged with
        // it and the clock ran on with it in host time; the offset shows the 30 ms, the audio saw no jump
        clock.position = 10
        let late = SlaveClock.follow(
            &clock, entry: Self.entry(position: 10), age: 0.05, dt: 0.02, elapsed: 0.05, interval: Self.interval, fps: 50, frameCount: 100)
        #expect(!late.jumped && abs(late.offsetMs - 30) < 1e-6)
        // the same late tick under a local master, whose entry stepped with the target (one frame, age 0): in host time the
        // clock seems 30 ms behind the entry, in target time it is on it; no jump either
        clock.position = 10
        let localLate = SlaveClock.follow(
            &clock, entry: Self.entry(position: 11), age: 0, dt: 0.02, elapsed: 0.05, interval: Self.interval, fps: 50, frameCount: 100)
        #expect(!localLate.jumped && abs(localLate.offsetMs) < 1e-6)
        // the master's file is longer: the slave stands at its last frame while the entry runs past it, no jump on any tick
        clock.position = 99
        for position in [105.0, 106, 110] {
            let pinned = SlaveClock.follow(
                &clock, entry: Self.entry(position: position), age: 0, dt: 0.02, interval: Self.interval, fps: 50, frameCount: 100)
            #expect(!pinned.jumped && clock.position == 99, "entry \(position)")
        }
        // retriggered from beyond the end back into the file: a jump
        let returned = SlaveClock.follow(
            &clock, entry: Self.entry(position: 40), age: 0, dt: 0.02, interval: Self.interval, fps: 50, frameCount: 100)
        #expect(returned.jumped && clock.position == 40)
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

    // B372: a local slave on the same file shows its master's frame on every tick, across the loop's wrap too. The
    // targets are whole periods of a 24 MHz mach clock, as `PacedThread` makes them. On 13798aee the master's position
    // sat at 99.999… while it showed frame 0; the slave clamped that to 99 and showed 99, then skipped 0. Whether the
    // float noise lands on that side depends on the start time, so four starts; 25p on 50 Hz is the control.
    @Test func aLocalSlaveShowsItsMastersFrameAcrossTheWrap() {
        for start in (0..<4).map({ 6_220_800_000_000 + UInt64($0) * 1_000_003 }) {  // three days of host time
            for (fps, hz, speed) in [(60.0, 60.0, 100.0), (24, 60, 100), (25, 60, 100), (60, 60, 80), (25, 50, 100)] {
                wrap(start: start, fps: fps, hz: hz, speed: speed)
            }
        }
    }

    func wrap(start: UInt64, fps: Double, hz: Double, speed: Double) {
        var master = LayerClock()
        master.retrigger(mode: .loopForward, inFrame: 0, outFrame: 99, frameCount: 100)
        var slave = LayerClock()
        let period = UInt64(24_000_000 / hz)
        var tick = start
        var last = Double(tick + period) / 24e6
        var disagree = 0
        for _ in 0..<6000 {
            tick += period
            let target = Double(tick + period) / 24e6
            let shown = master.advance(
                dt: target - last, fps: fps, speed: speed, mode: .loopForward, inFrame: 0, outFrame: 99, frameCount: 100)
            let entry = Self.entry(position: master.position, fps: Float(fps), rate: Float(fps * speed / 100))
            _ = SlaveClock.follow(&slave, entry: entry, age: 0, dt: target - last, interval: 1 / hz, fps: fps, frameCount: 100)
            if slave.frame(lo: 0, hi: 99) != shown { disagree += 1 }
            last = target
        }
        #expect(disagree == 0, "start \(start): \(fps) on \(hz) Hz at \(speed) %: \(disagree) of 6000 ticks")
    }
}
