// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import Synchronization

/// One preview streamer per target ("canvas", "output:<id>") that has subscribers, created on demand and released with
/// its last subscriber, so one client's target never changes what another sees. The canvas streamer always exists:
/// CITP consoles stream the canvas.
public final class PreviewHub: @unchecked Sendable {
    public let canvas: PreviewStreamer
    private let make: @Sendable () throws -> PreviewStreamer
    private let streamers = Mutex<[String: PreviewStreamer]>([:])
    /// The streamers `tap` walks; replaced (never mutated) when the set changes, so a tick takes one lock and a retain.
    private let active: Mutex<[PreviewStreamer]>
    /// Points a new streamer at its target; false for an unknown target. Set by the engine (output compile needs its project).
    nonisolated(unsafe) public var configure: (@Sendable (String, PreviewStreamer) -> Bool)?

    public init(canvas: PreviewStreamer, make: @escaping @Sendable () throws -> PreviewStreamer) {
        self.canvas = canvas
        self.make = make
        active = Mutex([canvas])
    }

    /// Subscribes `connection`'s stream to `target`, creating that target's streamer when this is its first subscriber.
    /// `announce` runs before the first frame can be sent (the `sub` reply carries the stream's size). False: bad target.
    public func attach(target: String, connection: StateServer.Connection, stream: UInt32, jpeg: Bool, announce: (PreviewStreamer) -> Void) -> Bool {
        // compiling an output reads the project (the store's queue): never under our lock, the store calls `refreshOutputs` from there
        var fresh: PreviewStreamer?
        if target != "canvas", !streamers.withLock({ $0[target] != nil }) {
            guard let created = try? make(), configure?(target, created) == true else { return false }
            fresh = created
        }
        return streamers.withLock { all in
            let streamer: PreviewStreamer
            if target == "canvas" {
                streamer = canvas
            } else if let existing = all[target] {
                streamer = existing  // another client got there first; ours is dropped
            } else if let fresh {
                all[target] = fresh
                streamer = fresh
                publishActive(all)
            } else {
                return false  // released between the check and here; the client may retry
            }
            announce(streamer)
            streamer.subscribe(PreviewStreamer.Subscriber(connection: connection, stream: stream, jpeg: jpeg))
            return true
        }
    }

    public func unsubscribe(connection: StateServer.Connection, stream: UInt32) {
        canvas.unsubscribe(connection: connection, stream: stream)
        streamers.withLock { all in
            for streamer in all.values { streamer.unsubscribe(connection: connection, stream: stream) }
            release(&all)
        }
    }

    public func remove(connection: StateServer.Connection) {
        canvas.remove(connection: connection)
        streamers.withLock { all in
            for streamer in all.values { streamer.remove(connection: connection) }
            release(&all)
        }
    }

    /// Output streamers without subscribers go; the canvas one stays.
    private func release(_ all: inout [String: PreviewStreamer]) {
        let before = all.count
        all = all.filter { $0.value.hasSubscribers }
        if all.count != before { publishActive(all) }
    }

    private func publishActive(_ all: [String: PreviewStreamer]) {
        let list = [canvas] + all.values
        active.withLock { $0 = list }
    }

    /// Targets with a streamer right now (tests, diagnostics).
    public var targets: [String] { streamers.withLock { Array($0.keys) } + ["canvas"] }

    /// Points every output streamer at its (possibly changed) output again; `reconfigure` returns false to keep the old one.
    public func refreshOutputs(_ reconfigure: (String, PreviewStreamer) -> Bool) {
        let current = streamers.withLock { $0 }
        for (target, streamer) in current { _ = reconfigure(target, streamer) }
    }

    // MARK: Compositor thread

    /// Anyone who needs canvas frames: a subscriber of any target or a CITP console.
    public var wantsFrames: Bool { active.withLock { $0 }.contains { $0.wantsFrames } }

    /// `Compositor.previewTap`.
    public func tap(canvas texture: MTLTexture, commandBuffer: MTLCommandBuffer, target: Double) {
        for streamer in active.withLock({ $0 }) { streamer.tap(canvas: texture, commandBuffer: commandBuffer, target: target) }
    }

    // MARK: Counters

    public var framesIn: Int { active.withLock { $0 }.reduce(0) { $0 + $1.framesIn.load(ordering: .relaxed) } }
    public var framesOut: Int { active.withLock { $0 }.reduce(0) { $0 + $1.framesOut.load(ordering: .relaxed) } }
    public var skipped: Int { active.withLock { $0 }.reduce(0) { $0 + $1.skipped.load(ordering: .relaxed) } }
}
