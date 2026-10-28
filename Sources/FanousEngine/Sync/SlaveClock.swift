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

    /// Locked within 1.5 ticks of the entry's arrival, freewheeling up to the freewheel time, then lost.
    static func state(age: Double, interval: Double) -> State {
        age <= 1.5 * interval ? .locked : age <= freewheelSeconds ? .freewheel : .lost
    }

    /// Where the master is `age` seconds after the entry arrived, in frames of a file at `fps`.
    static func implied(_ entry: SyncPacket.Layer, age: Double, fps: Double) -> Double {
        (entry.position + Double(entry.rate) * age) * fps / Double(entry.fps)
    }

    /// One tick of a slave on a file of `frameCount` frames at `fps`: locked sets the position from the entry
    /// (clamped to the file), freewheel and lost advance it by the entry's rate, wrapping within the file like a loop.
    /// `offsetMs`: how far the entry's position is from where the slave's clock would have been without it (its
    /// previous position advanced by the entry's rate), i.e. the correction a locked tick applies; a whole-file jump
    /// (the master looping) does not count.
    static func follow(
        _ clock: inout LayerClock, entry: SyncPacket.Layer, age: Double, dt: Double, interval: Double, fps: Double,
        frameCount: Int
    ) -> (state: State, offsetMs: Double) {
        let span = Double(max(1, frameCount))
        let predicted = clock.position + Double(entry.rate) * dt * fps / Double(entry.fps)
        let implied = implied(entry, age: age, fps: fps)
        let state = state(age: age, interval: interval)
        clock.position = state == .locked ? min(span - 1, max(0, implied)) : wrap(predicted, span)
        clock.direction = entry.direction < 0 ? -1 : 1
        clock.finished = entry.finished
        var offset = (implied - predicted).truncatingRemainder(dividingBy: span)
        if offset > span / 2 { offset -= span } else if offset < -span / 2 { offset += span }
        return (state, offset * 1000 / fps)
    }

    static func wrap(_ position: Double, _ span: Double) -> Double {
        let r = position.truncatingRemainder(dividingBy: span)
        return r < 0 ? r + span : r
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
