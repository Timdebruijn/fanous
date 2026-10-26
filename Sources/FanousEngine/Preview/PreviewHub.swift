// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import Synchronization

/// One preview streamer per target ("canvas", "output:<id>", "layer:<n>") that has subscribers, created on demand and released with
/// its last subscriber, so one client's target never changes what another sees. The canvas streamer always exists:
/// CITP consoles stream the canvas.
public final class PreviewHub: @unchecked Sendable {
    /// Replaced by `rebuild` (canvas size or rate changed); taken under `streamers` when both are needed.
    private let canvasBox: Mutex<PreviewStreamer>
    public var canvas: PreviewStreamer { canvasBox.withLock { $0 } }
    private let make: @Sendable () throws -> PreviewStreamer
    private let streamers = Mutex<[String: PreviewStreamer]>([:])
    /// The streamers `tap` walks; replaced (never mutated) when the set changes, so a tick takes one lock and a retain.
    private let active: Mutex<[PreviewStreamer]>
    /// Points a new streamer at its target; false for an unknown target. Set by the engine (output compile needs its project).
    nonisolated(unsafe) public var configure: (@Sendable (String, PreviewStreamer) -> Bool)?

    public init(canvas: PreviewStreamer, make: @escaping @Sendable () throws -> PreviewStreamer) {
        canvasBox = Mutex(canvas)
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
        streamers.withLock { all in
            canvas.unsubscribe(connection: connection, stream: stream)
            for streamer in all.values { streamer.unsubscribe(connection: connection, stream: stream) }
            release(&all)
        }
    }

    public func remove(connection: StateServer.Connection) {
        streamers.withLock { all in
            canvas.remove(connection: connection)
            for streamer in all.values { streamer.remove(connection: connection) }
            release(&all)
        }
    }

    /// The canvas changed size or rate (B31): every streamer is made again by `make` (new size, new frame interval)
    /// and its subscribers move over; they get a new `stream` description with the first frame. Output streamers are
    /// configured outside the lock (that reads the project); one that no longer configures keeps its old streamer.
    public func rebuild() throws {
        let fresh = try make()
        var outputs: [String: PreviewStreamer] = [:]
        for target in streamers.withLock({ Array($0.keys) }) {
            let streamer = try make()
            if configure?(target, streamer) == true { outputs[target] = streamer }
        }
        streamers.withLock { all in
            let old = canvas
            fresh.externalJPEGWanted = old.externalJPEGWanted
            for subscriber in old.subscriberList { fresh.subscribe(subscriber) }
            canvasBox.withLock { $0 = fresh }
            for (target, previous) in all {
                guard let replacement = outputs[target] else { continue }
                for subscriber in previous.subscriberList { replacement.subscribe(subscriber) }
                all[target] = replacement
            }
            publishActive(all)
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

    /// "layer:<n>" with 1 ≤ n ≤ `layerCount` → the 0-based layer index; anything else nil.
    public static func layerIndex(of target: String, layerCount: Int) -> Int? {
        guard target.hasPrefix("layer:"), let n = Int(target.dropFirst(6)), n >= 1, n <= layerCount else { return nil }
        return n - 1
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
