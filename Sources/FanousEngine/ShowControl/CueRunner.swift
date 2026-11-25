// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import QuartzCore
import Synchronization

/// Runs the project's cue list (DESIGN.md §15.2): go/back/goto from commands, OSC and the Space key,
/// timecode triggers from the clock, fades ticked at 50 Hz while anything is fading or a follow is pending.
/// Cue values reach the resolvers as the cue source.
public final class CueRunner: @unchecked Sendable {
    public struct Status: Sendable, Equatable {
        public var current: Double?
        public var currentName: String?
        public var next: Double?
        public var nextName: String?
        public var fading: Bool
        public var count: Int
    }

    private let queue = DispatchQueue(label: "org.fanous.cues", qos: .userInitiated)
    private let engine = Mutex(CueEngine(list: CueList()))
    private let dmx: DMXStore
    private var timer: DispatchSourceTimer?
    public let status = Mutex(Status(current: nil, currentName: nil, next: nil, nextName: nil, fading: false, count: 0))
    /// B284: called on the cue queue when the current cue or the held values change (a fire, a list edit, a resume), not
    /// per tick, with the current cue and `CueEngine.targets`; set before the first command. It must not block: the
    /// engine hands them to the show-state file off this queue.
    public var onStateChange: (@Sendable (Cue?, [UUID: [CueValue]]) -> Void)?
    private var lastRevision = 0  // cue queue only
    private var stopped = false  // cue queue only: set by `stop`, after which nothing changes

    public init(dmx: DMXStore) {
        self.dmx = dmx
    }

    /// `resuming` (B284, at start when show mode resumes): the stored state, applied in the same step as the list, so
    /// only the resumed state is ever reported. See `CueEngine.resume(current:number:targets:)`.
    public func replace(list: CueList, resuming state: (current: UUID?, number: Double?, targets: [UUID: [CueValue]])? = nil) {
        queue.async { [self] in
            guard !stopped else { return }
            engine.withLock { e in
                e.replace(list: list)
                if let state { e.resume(current: state.current, number: state.number, targets: state.targets) }
            }
            tick()  // pushes the released (or resumed) values to the resolvers
        }
    }

    public func go() { queue.async { [self] in act { $0.go(at: CACurrentMediaTime()) } } }
    public func back() { queue.async { [self] in act { $0.back(at: CACurrentMediaTime()) } } }
    public func goto(_ number: Double) { queue.async { [self] in act { $0.goto(number: number, at: CACurrentMediaTime()) } } }

    /// From the timecode clock (any thread): fires cues whose trigger was crossed.
    public func timecode(_ timecode: Timecode, running: Bool = true) {
        queue.async { [self] in act { $0.timecode(timecode, at: CACurrentMediaTime(), running: running) } }
    }

    private func act(_ body: (inout CueEngine) -> Void) {
        guard !stopped else { return }
        engine.withLock { body(&$0) }
        tick()
        ensureTimer()
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        timer = DispatchSource.repeating(every: 0.02, on: queue) { [self] in
            tick()
            if !engine.withLock({ $0.isFading || $0.hasPendingFollow }) {
                timer?.cancel()
                timer = nil
            }
        }
    }

    private func tick() {
        let outputs = engine.withLock { $0.tick(at: CACurrentMediaTime()) }
        dmx.setCue(outputs)
        publish()
    }

    private func publish() {
        let last = lastRevision
        let (s, changed) = engine.withLock { e -> (Status, (revision: Int, current: Cue?, targets: [UUID: [CueValue]])?) in
            let status = Status(
                current: e.current?.number, currentName: e.current?.name, next: e.next?.number, nextName: e.next?.name, fading: e.isFading,
                count: e.list.cues.count)
            return (status, e.revision == last ? nil : (e.revision, e.current, e.targets))
        }
        status.withLock { $0 = s }
        if let changed {
            lastRevision = changed.revision
            onStateChange?(changed.current, changed.targets)
        }
    }

    /// After this no command, list edit or follow changes anything, so the state a stop keeps is the last one.
    public func stop() {
        queue.sync {
            stopped = true
            timer?.cancel()
            timer = nil
        }
    }
}
