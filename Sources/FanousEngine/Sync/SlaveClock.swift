// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation

/// How a slave layer's clock follows its group's master (DESIGN.md §23.3): set from the newest entry, never integrated.
/// Pure arithmetic, called by `Compositor.prepare`.
enum SlaveClock {
    enum State: String, Sendable { case locked, freewheel, lost, noMaster, conflict }

    /// No entry for this long: lost (the timecode default, §15).
    static let freewheelSeconds = 2.0

    /// Locked within 1.5 ticks of the entry's arrival (at least 50 ms, so a master ticking slower than the slave,
    /// 30 against 60 fps, stays locked between its packets), freewheeling up to the freewheel time, then lost.
    static func state(age: Double, interval: Double) -> State {
        age <= max(1.5 * interval, 0.05) ? .locked : age <= freewheelSeconds ? .freewheel : .lost
    }

    /// Where the master is `age` seconds after the entry arrived, in frames of a file at `fps`.
    static func implied(_ entry: SyncPacket.Layer, age: Double, fps: Double) -> Double {
        (entry.position + Double(entry.rate) * age) * fps / Double(entry.fps)
    }

    /// One tick of a slave on a file of `frameCount` frames at `fps`: locked sets the position from the entry
    /// (clamped to the file), freewheel and lost advance it by the entry's rate, wrapping within the file like a loop.
    /// `offsetMs`: how far the entry's position is from where the slave's clock would have been without it (its
    /// previous position advanced by the entry's rate), i.e. the correction a locked tick applies; a whole-file jump
    /// (the master looping) does not count. `jumped`: a locked tick set the clock more than `jumpMillis` away from
    /// where it would have run on, both in host time (`elapsed` seconds since the previous tick; a remote master's
    /// entry is extrapolated in host time, so a slave tick that starts late is no step there) and in target time
    /// (`dt`; a local master's entry steps with the target, so the same late tick is no step there, while it is one in
    /// host time): the master was retriggered, or the slave locked on (first, or again after freewheeling or a freeze);
    /// its audio then reseeks to the new clock instead of nudging towards it (B395). A tick that clamps the clock to
    /// the file (the master's file is longer) is no jump: the clock stands at the last frame. At the master's loop wrap
    /// the fold leaves the clamped last frame's remainder, under one frame: past 20 ms only below 50 fps, where the
    /// producer reseeks at the wrap anyway (a slave reads no loop range).
    static func follow(
        _ clock: inout LayerClock, entry: SyncPacket.Layer, age: Double, dt: Double, elapsed: Double? = nil, interval: Double, fps: Double,
        frameCount: Int
    ) -> (state: State, offsetMs: Double, jumped: Bool) {
        let span = Double(max(1, frameCount))
        let rate = Double(entry.rate) * fps / Double(entry.fps)
        let predicted = clock.position + rate * dt
        let implied = implied(entry, age: age, fps: fps)
        let state = state(age: age, interval: interval)
        let jump = min(abs(fold(implied - (clock.position + rate * (elapsed ?? dt)), span)), abs(fold(implied - predicted, span))) * 1000 / fps
        clock.position = state == .locked ? min(span - 1, max(0, implied)) : wrap(predicted, span)
        clock.direction = entry.direction < 0 ? -1 : 1
        clock.finished = entry.finished
        let jumped = state == .locked && implied >= 0 && implied <= span - 1 && jump > jumpMillis
        return (state, fold(implied - predicted, span) * 1000 / fps, jumped)
    }

    /// A distance in frames folded within half the file: a whole-file jump (the master looping) is none.
    private static func fold(_ frames: Double, _ span: Double) -> Double {
        let r = frames.truncatingRemainder(dividingBy: span)
        return r > span / 2 ? r - span : r < -span / 2 ? r + span : r
    }

    /// The audio's drift tolerance (`LayerAudioChannel.driftToleranceFrames`, 20 ms): a smaller correction is nudged
    /// out by the render callback, a larger one is a jump the producer answers with a reseek.
    static let jumpMillis = Double(LayerAudioChannel.driftToleranceFrames) * 1000 / Double(LayerAudioChannel.sampleRate)

    static func wrap(_ position: Double, _ span: Double) -> Double {
        let r = position.truncatingRemainder(dividingBy: span)
        return r < 0 ? min(r + span, span.nextDown) : r  // −1e-17 + span rounds to span
    }
}

/// What a layer's Sync channel does this tick, for `live.layers[n].sync` and readiness; written by the compositor.
struct LayerSyncStatus: Sendable, Equatable {
    var role: LayerSync = .off
    /// A slave with a file playing; nil otherwise (not in use).
    var state: SlaveClock.State?
    var offsetMs = 0.0
    /// The entry the slave follows.
    var master: SyncTable.Entry?
}
