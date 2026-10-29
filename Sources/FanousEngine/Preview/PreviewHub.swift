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
/// CITP consoles stream it. H.264 encoders are bounded across targets (`PreviewSize.maxEncoders`, B70): `choose`.
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
    /// The canvas an output (its first slice) or a layer shows, the second fallback at the encoder limit (B70); nil or
    /// unset: canvas 1. Set by the engine; takes only the engine's own locks.
    nonisolated(unsafe) public var canvasOf: (@Sendable (String) -> Int?)?
    /// H.264 subscribers on another streamer than their (target, size) at the encoder limit, or refused to JPEG, oldest
    /// first: `rebalance` moves them when an encoder is released (B70). Guarded by `streamers`.
    private var fallbacks: [(subscriber: PreviewStreamer.Subscriber, key: Key)] = []
    /// Live layer thumbnails (B29): one producer for every `thumbs` subscriber and CITP layer stream. Set by the engine
    /// before the first tick.
    nonisolated(unsafe) public var thumbnails: ThumbnailStreamer?

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
    /// streamer when this is its first subscriber; at the encoder limit `choose` picks another. `announce` runs before
    /// the first frame can be sent (the `sub` reply carries the stream's size and whether it is JPEG). False: bad target.
    public func attach(
        target requested: String, width: Int? = nil, connection: StateServer.Connection, stream: UInt32, jpeg: Bool, announce: (PreviewStreamer, _ jpeg: Bool) -> Void
    ) -> Bool {
        let key = Key(target: requested == "canvas:1" ? "canvas" : requested, width: PreviewSize.sizeClass(wanted: width))
        // compiling an output reads the project (the store's queue): never under our lock, the store calls
        // `refreshOutputs` from there. So the streamer is made outside it, and made again when the target changed shape
        // meanwhile (a rebuild keeps a streamer it did not see) or the size to fall back to lost its last subscriber
        for _ in 0..<8 {  // ponytail: bounded; a target that changes shape 8 times during one subscription is refused
            var fresh: PreviewStreamer?
            if streamers.withLock({ choose(key, jpeg: jpeg, in: $0).streamer }) == nil {
                guard let created = try? create(key) else { return false }
                fresh = created
            }
            let attached: Bool? = streamers.withLock { all in
                // another client got there first, or the limit was reached meanwhile: ours is dropped
                let choice = choose(key, jpeg: jpeg, in: all)
                guard let streamer = choice.streamer ?? install(fresh, as: key, in: &all) else { return nil }
                let subscriber = PreviewStreamer.Subscriber(connection: connection, stream: stream, jpeg: jpeg)
                if choice.fallback { fallbacks.append((subscriber, key)) }
                announce(streamer, choice.jpeg)
                streamer.subscribe(PreviewStreamer.Subscriber(connection: connection, stream: stream, jpeg: choice.jpeg))
                return true
            }
            if let attached { return attached }
        }
        return false
    }

    /// Where a subscriber of `key` goes (B70). JPEG has no encoder: its own streamer. H.264 within
    /// `PreviewSize.maxEncoders` (the canvas one counted): its own. At the limit, a streamer that encodes already: its
    /// target's nearest size, else its canvas's nearest size; else refused, as JPEG on its own streamer (the browser
    /// falls back to JPEG when no `stream` description comes). `streamer` nil: make it.
    private func choose(_ key: Key, jpeg: Bool, in all: [Key: PreviewStreamer]) -> (streamer: PreviewStreamer?, jpeg: Bool, fallback: Bool) {
        let own = key == Key(target: "canvas", width: PreviewSize.defaultClass) ? canvas : all[key]
        if jpeg { return (own, true, false) }
        // the canvas streamer is always counted: its own viewers are never on a fallback
        if own === canvas || own.map(Self.encodes) == true || encoderCount(all) < PreviewSize.maxEncoders { return (own, false, false) }
        for target in [key.target, canvasTarget(of: key.target)] {
            var sizes = [Int: PreviewStreamer]()
            for (k, s) in all where k.target == target && Self.encodes(s) { sizes[k.width] = s }
            if target == "canvas" { sizes[PreviewSize.defaultClass] = canvas }
            if let nearest = PreviewSize.nearest(key.width, in: sizes.keys) { return (sizes[nearest], false, true) }
        }
        return (own, true, true)
    }

    /// The canvas target `target` shows: itself for a canvas, else `canvasOf`'s ("canvas" for canvas 1).
    private func canvasTarget(of target: String) -> String {
        if target.hasPrefix("canvas") { return target }
        let id = canvasOf?(target) ?? 1
        return id == 1 ? "canvas" : "canvas:\(id)"
    }

    /// Streamers with an H.264 subscriber, each with its VideoToolbox session (B66), and the canvas one, always counted.
    private func encoderCount(_ all: [Key: PreviewStreamer]) -> Int { 1 + all.values.count { Self.encodes($0) } }
    private static func encodes(_ streamer: PreviewStreamer) -> Bool { streamer.subscriberList.contains { !$0.jpeg } }

    /// Publishes `fresh` as `key`'s streamer when its target still has the shape it was made for; nil otherwise.
    private func install(_ fresh: PreviewStreamer?, as key: Key, in all: inout [Key: PreviewStreamer]) -> PreviewStreamer? {
        // `shape` takes only the engine's own locks, never ours
        guard let fresh, let shape = shape(key.target) else { return nil }
        let size = PreviewSize.size(class: key.width, shape: shape)
        guard size.width == fresh.width, size.height == fresh.height else { return nil }
        all[key] = fresh
        publishActive(all)
        return fresh
    }

    /// An encoder was released (B70): subscribers on a fallback get their own (target, size) while the limit allows,
    /// oldest first. Its streamer is made outside the lock, like `attach`'s; they leave the fallback in the same step
    /// and get the new `stream` description with its first frame, a key frame (as after a rebuild). Off the caller's
    /// thread: `create` can read the project. `orphans` (B88) lost their fallback stream in a rebuild and are on no
    /// streamer: they take their own stream or another fallback; one that `choose` refuses to JPEG is told its target is
    /// gone, as before B88 (the browser drops JPEG frames on a stream that was H.264, B86).
    private func rebalance(placing orphans: [PreviewStreamer.Subscriber] = []) {
        for wanted in streamers.withLock({ _ in fallbacks }) {
            let sub = wanted.subscriber
            let orphan = orphans.contains { $0.connection === sub.connection && $0.stream == sub.stream }
            for attempt in 0..<(orphan ? 2 : 1) {
                let first = streamers.withLock { choose(wanted.key, jpeg: false, in: $0) }
                guard orphan || !first.fallback else { break }
                let fresh = first.streamer == nil && !first.jpeg ? try? create(wanted.key) : nil
                let retry: Bool = streamers.withLock { all in
                    guard let index = fallbacks.firstIndex(where: { $0.subscriber.connection === sub.connection && $0.subscriber.stream == sub.stream }) else { return false }
                    let choice = choose(wanted.key, jpeg: false, in: all)
                    // the limit was reached again: tried again after the next release
                    guard orphan || !choice.fallback else { return false }
                    if !choice.jpeg, let streamer = choice.streamer ?? install(fresh, as: wanted.key, in: &all) {
                        if !choice.fallback { fallbacks.remove(at: index) }
                        canvas.unsubscribe(connection: sub.connection, stream: sub.stream)
                        for other in all.values { other.unsubscribe(connection: sub.connection, stream: sub.stream) }
                        streamer.subscribe(sub)
                        release(&all)
                        return false
                    }
                    // a fallback viewer whose target went or changed shape meanwhile waits for the next release. An
                    // orphan whose streamer was not installed (its target changed shape, or a concurrent release changed
                    // the choice) tries once more while its target exists; ponytail: a second race ends that preview
                    guard orphan else { return false }
                    if !choice.jpeg, attempt == 0, shape(wanted.key.target) != nil { return true }
                    fallbacks.remove(at: index)
                    Self.tellGone(sub, target: wanted.key.target)
                    return false
                }
                if !retry { break }
            }
        }
    }

    /// Tells a viewer its preview target is gone, instead of leaving it on a frozen picture.
    private static func tellGone(_ s: PreviewStreamer.Subscriber, target: String) {
        _ = s.connection.send(text: #"{"t":"error","code":"badTarget","message":"preview target \#(target) no longer exists","id":\#(s.stream)}"#, droppable: false)
    }

    public func unsubscribe(connection: StateServer.Connection, stream: UInt32) {
        let freed = streamers.withLock { all in
            let before = encoderCount(all)
            canvas.unsubscribe(connection: connection, stream: stream)
            thumbnails?.unsubscribe(connection: connection, stream: stream)
            for streamer in all.values { streamer.unsubscribe(connection: connection, stream: stream) }
            fallbacks.removeAll { $0.subscriber.connection === connection && $0.subscriber.stream == stream }
            release(&all)
            return encoderCount(all) < before && !fallbacks.isEmpty
        }
        if freed { DispatchQueue.global(qos: .utility).async { [weak self] in self?.rebalance() } }
    }

    public func remove(connection: StateServer.Connection) {
        let freed = streamers.withLock { all in
            let before = encoderCount(all)
            canvas.remove(connection: connection)
            thumbnails?.remove(connection: connection)
            for streamer in all.values { streamer.remove(connection: connection) }
            fallbacks.removeAll { $0.subscriber.connection === connection }
            release(&all)
            return encoderCount(all) < before && !fallbacks.isEmpty
        }
        if freed { DispatchQueue.global(qos: .utility).async { [weak self] in self?.rebalance() } }
    }

    /// The canvas changed size or rate (B31), or a target its shape: every streamer is made again (new size, new frame
    /// interval) and its subscribers move over; they get a new `stream` description with the first frame. Output
    /// streamers are configured outside the lock (that reads the project); one that no longer configures keeps its old
    /// streamer. A viewer on a removed canvas's stream as a fallback is chosen again for its own target (B88); then
    /// `rebalance` gives the encoders the rebuild freed to waiting viewers.
    public func rebuild() throws {
        let fresh = try Self.canvasStreamer(make, shape)
        var remade: [Key: PreviewStreamer] = [:]
        let keys = Set(streamers.withLock { $0.keys })
        for key in keys {
            if let streamer = try create(key) { remade[key] = streamer }
        }
        var orphans: [PreviewStreamer.Subscriber] = []
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
                            let index = fallbacks.firstIndex { $0.subscriber.connection === s.connection && $0.subscriber.stream == s.stream }
                            // another target's viewer on this canvas as a fallback, its own target still there (B88)
                            if let index, fallbacks[index].key.target != key.target, shape(fallbacks[index].key.target) != nil {
                                orphans.append(s)
                                continue
                            }
                            let own = index.map { fallbacks.remove(at: $0).key.target }
                            Self.tellGone(s, target: own ?? key.target)
                        }
                    }
                    continue
                }
                for subscriber in previous.subscriberList { replacement.subscribe(subscriber) }
                all[key] = replacement
            }
            publishActive(all)
        }
        rebalance(placing: orphans)
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
    /// H.264 encoders right now, the canvas one always counted; at most `PreviewSize.maxEncoders` (tests, `/metrics`).
    public var encoders: Int { streamers.withLock { encoderCount($0) } }
    /// Subscribers on a fallback or refused to JPEG (tests).
    var fallbackCount: Int { streamers.withLock { _ in fallbacks.count } }
    /// Streamers right now by target and size class (tests).
    var keys: Set<Key> { streamers.withLock { Set($0.keys) } }

    /// Points every output streamer at its (possibly changed) output again; `reconfigure` returns false to keep the old one.
    public func refreshOutputs(_ reconfigure: (String, PreviewStreamer) -> Bool) {
        let current = streamers.withLock { $0 }
        for (key, streamer) in current { _ = reconfigure(key.target, streamer) }
    }

    // MARK: Compositor thread

    /// Anyone who needs canvas frames this tick: a subscriber of any target or a CITP console, or thumbnails on their
    /// pass ticks (4 a second).
    public var wantsFrames: Bool { active.withLock { $0 }.contains { $0.wantsFrames } || thumbnails?.wantsPass == true }

    /// `Compositor.previewTap`.
    public func tap(canvas texture: MTLTexture, commandBuffer: MTLCommandBuffer, target: Double) {
        for streamer in active.withLock({ $0 }) {
            guard let canvas = streamer.canvasID == 1 ? texture : canvasTexture?(streamer.canvasID) else { continue }
            streamer.tap(canvas: canvas, commandBuffer: commandBuffer, target: target, canvases: canvasTexture)
        }
        thumbnails?.tap(commandBuffer: commandBuffer)
    }

    // MARK: Counters

    public var framesIn: Int { active.withLock { $0 }.reduce(0) { $0 + $1.framesIn.load(ordering: .relaxed) } }
    public var framesOut: Int { active.withLock { $0 }.reduce(0) { $0 + $1.framesOut.load(ordering: .relaxed) } }
    public var skipped: Int { active.withLock { $0 }.reduce(0) { $0 + $1.skipped.load(ordering: .relaxed) } }
    public var jpegOut: Int { active.withLock { $0 }.reduce(0) { $0 + $1.jpegOut.load(ordering: .relaxed) } }
    public var jpegFailed: Int { active.withLock { $0 }.reduce(0) { $0 + $1.jpegFailed.load(ordering: .relaxed) } }
    public var jpegDropped: Int { active.withLock { $0 }.reduce(0) { $0 + $1.jpegDropped.load(ordering: .relaxed) } }
}
