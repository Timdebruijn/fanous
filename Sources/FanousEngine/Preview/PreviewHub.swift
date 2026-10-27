// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Metal
import Synchronization

/// One preview streamer per (target, size class) that has subscribers ("canvas" = "canvas:1", "canvas:<id>",
/// "output:<id>", "layer:<n>"; DESIGN.md §11.3, B32), created on demand and released with its last subscriber, so one
/// client's target or size never changes what another sees. The canvas 1 streamer at the default class always exists:
/// CITP consoles stream it.
public final class PreviewHub: @unchecked Sendable {
    /// A streamer's key: its target and its size class (`PreviewSize`).
    public struct Key: Hashable, Sendable {
        public var target: String
        public var width: Int
    }

    /// Replaced by `rebuild` (canvas size or rate changed); taken under `streamers` when both are needed.
    private let canvasBox: Mutex<PreviewStreamer>
    public var canvas: PreviewStreamer { canvasBox.withLock { $0 } }
    /// Makes a streamer of a pixel size at the rendered canvas rate.
    private let make: @Sendable (Int, Int) throws -> PreviewStreamer
    /// A target's picture size in pixels: canvas 1, a canvas that renders, a layer's canvas, an output's region; nil =
    /// no such target (refused).
    private let shape: @Sendable (String) -> (width: Int, height: Int)?
    private let streamers = Mutex<[Key: PreviewStreamer]>([:])
    /// The streamers `tap` walks; replaced (never mutated) when the set changes, so a tick takes one lock and a retain.
    private let active: Mutex<[PreviewStreamer]>
    /// Points a new output or layer streamer at its target; false for an unknown target. Set by the engine (output
    /// compile needs its project).
    nonisolated(unsafe) public var configure: (@Sendable (String, PreviewStreamer) -> Bool)?
    /// Compositor thread: a canvas of the running tick by id (`Compositor.tickCanvas`).
    nonisolated(unsafe) public var canvasTexture: ((Int) -> MTLTexture?)?

    public init(make: @escaping @Sendable (Int, Int) throws -> PreviewStreamer, shape: @escaping @Sendable (String) -> (width: Int, height: Int)?) throws {
        let canvas = try Self.canvasStreamer(make, shape)
        canvasBox = Mutex(canvas)
        self.make = make
        self.shape = shape
        active = Mutex([canvas])
    }

    private static func canvasStreamer(_ make: (Int, Int) throws -> PreviewStreamer, _ shape: (String) -> (width: Int, height: Int)?) throws -> PreviewStreamer {
        let size = PreviewSize.size(class: PreviewSize.defaultClass, shape: shape("canvas") ?? (16, 9))
        return try make(size.width, size.height)
    }

    /// Subscribes `connection`'s stream to `target` at the size class for `width` (nil: the default), creating that
    /// streamer when this is its first subscriber. At `PreviewSize.maxEncoders` a new size of a target that already
    /// has one attaches to its nearest size instead; a new target always gets its streamer. `announce` runs before the
    /// first frame can be sent (the `sub` reply carries the stream's size). False: bad target.
    public func attach(
        target requested: String, width: Int? = nil, connection: StateServer.Connection, stream: UInt32, jpeg: Bool, announce: (PreviewStreamer) -> Void
    ) -> Bool {
        let key = Key(target: requested == "canvas:1" ? "canvas" : requested, width: PreviewSize.sizeClass(wanted: width))
        // compiling an output reads the project (the store's queue): never under our lock, the store calls
        // `refreshOutputs` from there. So the streamer is made outside it, and made again when the target changed shape
        // meanwhile (a rebuild keeps a streamer it did not see) or the size to fall back to lost its last subscriber
        for _ in 0..<8 {  // ponytail: bounded; a target that changes shape 8 times during one subscription is refused
            var fresh: PreviewStreamer?
            if streamers.withLock({ existing(key, in: $0) }) == nil {
                guard let created = try? create(key) else { return false }
                fresh = created
            }
            let attached: Bool? = streamers.withLock { all in
                let streamer: PreviewStreamer
                if let found = existing(key, in: all) {
                    streamer = found  // another client got there first, or the limit was reached meanwhile; ours is dropped
                } else if let fresh {
                    // `shape` takes only the engine's own locks, never ours
                    guard let shape = shape(key.target) else { return false }
                    let size = PreviewSize.size(class: key.width, shape: shape)
                    guard size.width == fresh.width, size.height == fresh.height else { return nil }
                    all[key] = fresh
                    streamer = fresh
                    publishActive(all)
                } else {
                    return nil
                }
                announce(streamer)
                streamer.subscribe(PreviewStreamer.Subscriber(connection: connection, stream: stream, jpeg: jpeg))
                return true
            }
            if let attached { return attached }
        }
        return false
    }

    /// The streamer `key` gets without a new encoder: its own, or at the encoder limit the nearest size of its target.
    private func existing(_ key: Key, in all: [Key: PreviewStreamer]) -> PreviewStreamer? {
        var sizes = all.filter { $0.key.target == key.target }
        if key.target == "canvas" { sizes[Key(target: "canvas", width: PreviewSize.defaultClass)] = canvas }
        if let own = sizes[key] { return own }
        guard 1 + all.count >= PreviewSize.maxEncoders, let nearest = PreviewSize.nearest(key.width, in: sizes.keys.map(\.width)) else { return nil }
        return sizes[Key(target: key.target, width: nearest)]
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

    /// The canvas changed size or rate (B31), or a target its shape: every streamer is made again (new size, new frame
    /// interval) and its subscribers move over; they get a new `stream` description with the first frame. Output
    /// streamers are configured outside the lock (that reads the project); one that no longer configures keeps its old
    /// streamer.
    public func rebuild() throws {
        let fresh = try Self.canvasStreamer(make, shape)
        var remade: [Key: PreviewStreamer] = [:]
        let keys = Set(streamers.withLock { $0.keys })
        for key in keys {
            if let streamer = try create(key) { remade[key] = streamer }
        }
        streamers.withLock { all in
            let old = canvas
            fresh.externalJPEGWanted = old.externalJPEGWanted
            for subscriber in old.subscriberList { fresh.subscribe(subscriber) }
            canvasBox.withLock { $0 = fresh }
            for (key, previous) in all {
                guard let replacement = remade[key] else {
                    // a removed canvas: its viewers are told instead of left on a frozen picture. A key subscribed
                    // while we built (not in `keys`) was made after the switch began and stays (B62); in the rare
                    // case it was made just before the switch for a canvas that went, its viewer drops it when
                    // `live.canvas` no longer lists that canvas
                    if key.target.hasPrefix("canvas:"), keys.contains(key) {
                        all.removeValue(forKey: key)
                        for s in previous.subscriberList {
                            _ = s.connection.send(text: #"{"t":"error","code":"badTarget","message":"preview target \#(key.target) no longer exists","id":\#(s.stream)}"#, droppable: false)
                        }
                    }
                    continue
                }
                for subscriber in previous.subscriberList { replacement.subscribe(subscriber) }
                all[key] = replacement
            }
            publishActive(all)
        }
    }

    /// True when a streamer's target changed shape (an output's region, a layer's canvas): `rebuild` makes it again.
    /// The canvas streamers follow the canvas switch, which rebuilds anyway.
    public var shapeChanged: Bool {
        streamers.withLock { $0 }.contains { key, streamer in
            guard !key.target.hasPrefix("canvas"), let shape = shape(key.target) else { return false }
            let size = PreviewSize.size(class: key.width, shape: shape)
            return size.width != streamer.width || size.height != streamer.height
        }
    }

    /// A streamer other than the canvas one, at its class in its target's shape; "canvas:<id>" taps that canvas, an
    /// output or layer goes through `configure`.
    private func create(_ key: Key) throws -> PreviewStreamer? {
        guard let shape = shape(key.target) else { return nil }
        let size = PreviewSize.size(class: key.width, shape: shape)
        let streamer = try make(size.width, size.height)
        if key.target == "canvas" { return streamer }
        if key.target.hasPrefix("canvas:") {
            guard let id = Int(key.target.dropFirst(7)) else { return nil }
            streamer.canvasID = id
            return streamer
        }
        return configure?(key.target, streamer) == true ? streamer : nil
    }

    /// Output streamers without subscribers go; the canvas one stays.
    private func release(_ all: inout [Key: PreviewStreamer]) {
        let before = all.count
        all = all.filter { $0.value.hasSubscribers }
        if all.count != before { publishActive(all) }
    }

    private func publishActive(_ all: [Key: PreviewStreamer]) {
        let list = [canvas] + all.values
        active.withLock { $0 = list }
    }

    /// "layer:<n>" with 1 ≤ n ≤ `layerCount` → the 0-based layer index; anything else nil.
    public static func layerIndex(of target: String, layerCount: Int) -> Int? {
        guard target.hasPrefix("layer:"), let n = Int(target.dropFirst(6)), n >= 1, n <= layerCount else { return nil }
        return n - 1
    }

    /// Targets with a streamer right now, each once (tests, diagnostics).
    public var targets: [String] { Array(streamers.withLock { Set($0.keys.map(\.target)) }.subtracting(["canvas"])) + ["canvas"] }
    /// Streamers right now, the canvas one included: each has its own encoder (tests, `/metrics`).
    public var encoders: Int { 1 + streamers.withLock { $0.count } }
    /// Streamers right now by target and size class (tests).
    var keys: Set<Key> { streamers.withLock { Set($0.keys) } }

    /// Points every output streamer at its (possibly changed) output again; `reconfigure` returns false to keep the old one.
    public func refreshOutputs(_ reconfigure: (String, PreviewStreamer) -> Bool) {
        let current = streamers.withLock { $0 }
        for (key, streamer) in current { _ = reconfigure(key.target, streamer) }
    }

    // MARK: Compositor thread

    /// Anyone who needs canvas frames: a subscriber of any target or a CITP console.
    public var wantsFrames: Bool { active.withLock { $0 }.contains { $0.wantsFrames } }

    /// `Compositor.previewTap`.
    public func tap(canvas texture: MTLTexture, commandBuffer: MTLCommandBuffer, target: Double) {
        for streamer in active.withLock({ $0 }) {
            guard let canvas = streamer.canvasID == 1 ? texture : canvasTexture?(streamer.canvasID) else { continue }
            streamer.tap(canvas: canvas, commandBuffer: commandBuffer, target: target, canvases: canvasTexture)
        }
    }

    // MARK: Counters

    public var framesIn: Int { active.withLock { $0 }.reduce(0) { $0 + $1.framesIn.load(ordering: .relaxed) } }
    public var framesOut: Int { active.withLock { $0 }.reduce(0) { $0 + $1.framesOut.load(ordering: .relaxed) } }
    public var skipped: Int { active.withLock { $0 }.reduce(0) { $0 + $1.skipped.load(ordering: .relaxed) } }
}
