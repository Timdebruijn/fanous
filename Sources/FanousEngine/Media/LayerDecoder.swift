// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Logging
import Synchronization

/// One decode thread per layer (DESIGN.md §4.2). The compositor asks for a
/// frame index each tick; the thread fills the ring ahead in play direction
/// and restarts from the requested index on a seek.
public final class LayerDecoder: @unchecked Sendable {
    public let ring: FrameRing
    public let source: MovieSource
    private let wanted = Atomic<Int>(0)
    private let direction = Atomic<Int>(1)
    private let running = Atomic<Bool>(true)
    private let wake = DispatchSemaphore(value: 0)
    /// What the decode thread was last woken for; a repeated request (paused clip) wakes nobody.
    private let signalledFrame = Atomic<Int>(-1)
    private let signalledDirection = Atomic<Int>(0)
    /// Wake-ups sent to the decode thread; diagnostics and tests.
    public let wakeups = Atomic<Int>(0)
    private let logger: Logger
    private var thread: Thread?
    private var lastProduced = -1
    public let decoded = Atomic<Int>(0)
    /// Audio track of the same movie, filled from this thread between video frames (ADR-0019).
    public var audio: (reader: AudioTrackReader, channel: LayerAudioChannel)?
    /// The compositor enables audio for the playback that owns the channel (a dissolve hands it over).
    public let audioEnabled = Atomic<Bool>(false)

    public init(source: MovieSource, ring: FrameRing, logger: Logger) {
        self.source = source
        self.ring = ring
        self.logger = logger
    }

    public func start(name: String) {
        let thread = Thread { [self] in loop() }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
        self.thread = thread
    }

    public func stop() {
        running.store(false, ordering: .relaxed)
        wake.signal()
    }

    /// Called by the compositor every tick (never blocks). The thread is only woken when the frame or the direction
    /// differs from the last wake-up: while it has a full ring and nothing changes it sleeps.
    public func request(frame: Int, direction: Int) {
        let dir = direction >= 0 ? 1 : -1
        wanted.store(frame, ordering: .relaxed)
        self.direction.store(dir, ordering: .relaxed)
        let frameChanged = signalledFrame.exchange(frame, ordering: .relaxed) != frame
        let directionChanged = signalledDirection.exchange(dir, ordering: .relaxed) != dir
        if frameChanged || directionChanged { nudge() }
    }

    /// Wakes the decode thread (audio just got enabled, a request changed).
    public func nudge() {
        wakeups.wrappingAdd(1, ordering: .relaxed)
        wake.signal()
    }

    private func loop() {
        let count = source.info.frameCount
        while running.load(ordering: .relaxed) {
            if let audio, audioEnabled.load(ordering: .relaxed) { audio.channel.fill(from: audio.reader) }
            guard let slot = ring.slotForWriting() else {
                // with audio to feed, keep topping it up while the video ring is full; otherwise sleep until a request changes
                _ = wake.wait(timeout: audio != nil && audioEnabled.load(ordering: .relaxed) ? .now() + .milliseconds(10) : .distantFuture)
                continue
            }
            let want = ((wanted.load(ordering: .relaxed) % count) + count) % count
            let dir = direction.load(ordering: .relaxed)
            var next = want
            if lastProduced >= 0, !ring.isEmpty {
                let ahead = dir > 0 ? (want - lastProduced + count) % count : (lastProduced - want + count) % count
                next = ahead <= ring.capacity ? (lastProduced + dir + count) % count : want
            }
            do {
                try autoreleasepool { try source.decode(frame: next, into: slot) }
                ring.commit()
                lastProduced = next
                decoded.wrappingAdd(1, ordering: .relaxed)
            } catch {
                logger.error("decode failed", metadata: ["file": "\(source.url.lastPathComponent)", "frame": "\(next)", "error": "\(error)"])
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}
