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
    /// Audio track of the same movie, filled from this thread between video frames (ADR-0019); set by the loader before
    /// the thread starts.
    public var audioReader: AudioTrackReader?
    /// The layer's two mixer channels (the compositor keeps a dissolve's two files on different ones); set by the loader
    /// with the reader.
    public var audioChannels: [LayerAudioChannel] = []
    /// The channel this decoder fills: the compositor picks it from `audioChannels` at the swap, the one the layer's
    /// other playback does not hold (B399), and writes it before it sets `audioEnabled` (release); this thread reads
    /// `audioEnabled` first (acquire). Nil until then; written once.
    public var audioChannel: LayerAudioChannel?
    /// Set by the compositor at the swap once the channel is chosen, cleared when the playback is retired.
    public let audioEnabled = Atomic<Bool>(false)

    public init(source: MovieSource, ring: FrameRing, logger: Logger) {
        self.source = source
        self.ring = ring
        self.logger = logger
        source.logger = logger  // a session made again is logged (B278)
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
        let signpost = Signposts.id(self)
        while running.load(ordering: .relaxed) {
            if audioEnabled.load(ordering: .acquiring), let audioReader, let audioChannel { audioChannel.fill(from: audioReader) }
            guard let slot = ring.slotForWriting() else {
                // with audio to feed, keep topping it up while the video ring is full; otherwise sleep until a request changes
                _ = wake.wait(timeout: audioReader != nil && audioEnabled.load(ordering: .relaxed) ? .now() + .milliseconds(10) : .distantFuture)
                continue
            }
            let want = ((wanted.load(ordering: .relaxed) % count) + count) % count
            let dir = direction.load(ordering: .relaxed)
            var next = want
            if lastProduced >= 0, !ring.isEmpty {
                // how far the last decoded frame runs ahead of the request in play direction; behind it (a seek, a slow
                // decode) this wraps to count − k and the thread restarts at the request
                let ahead = dir > 0 ? (lastProduced - want + count) % count : (want - lastProduced + count) % count
                next = ahead <= ring.capacity ? (lastProduced + dir + count) % count : want
            }
            do {
                Signposts.begin("decode", id: signpost)
                defer { Signposts.end("decode", id: signpost) }
                try autoreleasepool { try source.decode(frame: next, into: slot) }
                ring.commit()
                lastProduced = next
                decoded.wrappingAdd(1, ordering: .relaxed)
                if run > 0 { recovered(at: next) }
            } catch {
                failed(next, error)
            }
        }
    }

    // B278: the error path. A frame that fails is skipped: the ring keeps its last good frame, the thread pauses
    // `pauseAfterError` and goes on (with an empty ring it goes on with the requested frame, which may be the same one).
    // Skipped frames with no good one between, for `failingAfter` of wall time, are a failing file: the layer's status
    // carries the error (B342) until a frame decodes again. The log lines are budgeted, each line carrying what it held
    // back: skip lines at most one per `reportEvery`, and the `decode failing` / `decode still failing` /
    // `decode recovered` lines at most one per `reportEvery` (a recovery line always follows a failing line it pairs with).

    /// Wall time from the first skipped frame of a run (no good frame between) to the layer reading as failing.
    var failingAfter = 0.5
    /// Seconds between two lines of one budget.
    var reportEvery = 10.0
    /// The pause after a frame that failed (a stop cuts it short).
    static let pauseAfterError = 0.015
    /// The layer's status: the error text while frame after frame fails (when it starts, then at most once a second),
    /// nil once when a frame decodes again. Set by the loader before `start`; called on the decode thread, error path only.
    public var failing: (@Sendable (String?) -> Void)?
    /// Decode thread only.
    private var run = 0
    private var runStart = ContinuousClock.now
    private var isFailing = false
    private var failingLogged = false
    private var lastStatus = ContinuousClock.now
    private var skippedSinceLine = 0
    private var skipLines = LineBudget()
    private var stateLines = LineBudget()

    private func failed(_ frame: Int, _ error: any Error) {
        lastProduced = frame  // skipped: with frames in the ring the next pass goes on after it
        run += 1
        let now = ContinuousClock.now
        if run == 1 { runStart = now }
        let file = source.url.lastPathComponent
        if isFailing {
            // again at most once a second: the loader writes a new layer's status after starting its decoder
            if lastStatus.duration(to: now) >= .seconds(1) {
                failing?(error.clientText)
                lastStatus = now
            }
            if let held = stateLines.take(every: reportEvery, now: now, counts: false) {
                logger.warning("decode still failing", metadata: ["file": "\(file)", "skipped": "\(run)", "linesHeldBack": "\(held)", "error": "\(error)"])
            }
        } else if runStart.duration(to: now) >= .seconds(failingAfter) {
            isFailing = true
            skippedSinceLine = 0  // this run's skips are in `skipped` below
            failing?(error.clientText)
            lastStatus = now
            failingLogged = false
            if let held = stateLines.take(every: reportEvery, now: now) {
                logger.error("decode failing", metadata: ["file": "\(file)", "frame": "\(frame)", "skipped": "\(run)", "linesHeldBack": "\(held)", "error": "\(error)"])
                failingLogged = true
            }
        } else {
            skippedSinceLine += 1
            if skipLines.take(every: reportEvery, now: now) != nil {
                logger.error("decode failed, frame skipped", metadata: ["file": "\(file)", "frame": "\(frame)", "skippedSinceLastLine": "\(skippedSinceLine)", "error": "\(error)"])
                skippedSinceLine = 0
            }
        }
        pause(Self.pauseAfterError)
    }

    private func recovered(at frame: Int) {
        if isFailing {
            failing?(nil)
            let held = failingLogged ? 0 : stateLines.take(every: reportEvery)
            if let held {
                logger.info("decode recovered", metadata: ["file": "\(source.url.lastPathComponent)", "frame": "\(frame)", "skipped": "\(run)", "linesHeldBack": "\(held)"])
            }
        }
        run = 0
        isFailing = false
    }

    /// Waits `seconds`, feeding audio meanwhile; a changed request does not cut it short, a stop does.
    private func pause(_ seconds: Double) {
        let until = DispatchTime.now() + seconds
        while running.load(ordering: .relaxed), DispatchTime.now() < until {
            let feeding = audioReader != nil && audioEnabled.load(ordering: .acquiring)
            if feeding, let audioReader, let audioChannel { audioChannel.fill(from: audioReader) }
            _ = wake.wait(timeout: feeding ? min(until, .now() + .milliseconds(10)) : until)
        }
    }
}

/// At most one log line per `every` seconds (B278): `take` answers how many lines it held back since the last one, or
/// nil when this one is held back too. A line that is only due when the budget allows it (a periodic count) passes
/// `counts: false`, so a held-back try of it is not a held-back line.
struct LineBudget {
    private var last: ContinuousClock.Instant?
    private var held = 0

    mutating func take(every: Double, now: ContinuousClock.Instant = .now, counts: Bool = true) -> Int? {
        if let last, last.duration(to: now) < .seconds(every) {
            if counts { held += 1 }
            return nil
        }
        defer { (last, held) = (now, 0) }
        return held
    }
}
