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
    private let logger: Logger
    private var timer: DispatchSourceTimer?
    public let status = Mutex(Status(current: nil, currentName: nil, next: nil, nextName: nil, fading: false, count: 0))

    public init(dmx: DMXStore, logger: Logger) {
        self.dmx = dmx
        self.logger = logger
    }

    public func replace(list: CueList) {
        queue.async { [self] in
            engine.withLock { $0.replace(list: list) }
            publish()
        }
    }

    public func go() { queue.async { [self] in act { $0.go(at: CACurrentMediaTime()) } } }
    public func back() { queue.async { [self] in act { $0.back(at: CACurrentMediaTime()) } } }
    public func goto(_ number: Double) { queue.async { [self] in act { $0.goto(number: number, at: CACurrentMediaTime()) } } }

    /// From the timecode clock (any thread): fires cues whose trigger was crossed.
    public func timecode(_ timecode: Timecode) {
        queue.async { [self] in act { $0.timecode(timecode, at: CACurrentMediaTime()) } }
    }

    private func act(_ body: (inout CueEngine) -> Void) {
        engine.withLock { body(&$0) }
        tick()
        ensureTimer()
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.02, repeating: 0.02)
        timer.setEventHandler { [self] in
            tick()
            if !engine.withLock({ $0.isFading }) {
                self.timer?.cancel()
                self.timer = nil
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let outputs = engine.withLock { $0.tick(at: CACurrentMediaTime()) }
        dmx.setCue(outputs)
        publish()
    }

    private func publish() {
        let s = engine.withLock { e -> Status in
            Status(
                current: e.current?.number, currentName: e.current?.name, next: e.next?.number, nextName: e.next?.name, fading: e.isFading,
                count: e.list.cues.count)
        }
        status.withLock { $0 = s }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }
}
