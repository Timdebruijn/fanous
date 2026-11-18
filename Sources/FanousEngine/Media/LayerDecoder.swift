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
        let signpost = Signposts.id(self)
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

    // B278: the error path. A frame gets `Self.tries` tries (a read that fails once on a slow volume succeeds on the
    // next), then it is skipped: the ring keeps its last good frame and the thread goes on with the next one. Skipped
    // frames with no good one between are tried with a pause that grows from 50 ms; a run that lasts `failingAfter` is a
    // failing file: the layer's status carries the error (B342), and the log gets one line when it starts, a count at
    // most every `reportEvery` and one line when it recovers. One bad frame on stage (the thread may come back to it
    // while the clock still shows it) stays one log line and never reaches the status.

    /// Tries of one frame before it is skipped.
    static let tries = 3
    /// Seconds a run of skipped frames lasts before the layer reads as failing.
    var failingAfter = 0.5
    /// The longest pause between skipped frames; it starts at 50 ms and doubles.
    var longestPause = 1.0
    /// Seconds between the count lines of a failing file.
    var reportEvery = 10.0
    /// The layer's status: the error text while frame after frame fails, nil when a frame decodes again. Set by the
    /// loader before `start`; called on the decode thread.
    public var failing: (@Sendable (String?) -> Void)?
    /// Decode thread only.
    private var tries = 0
    private var triedFrame = -1
    private var run = 0
    private var runStart = ContinuousClock.now
    private var isFailing = false
    private var skipped = -1
    private var lastReport = ContinuousClock.now

    private func failed(_ frame: Int, _ error: any Error) {
        // counted per frame: between two tries of it the thread may decode the requested frame again
        if frame != triedFrame { (triedFrame, tries) = (frame, 0) }
        tries += 1
        guard tries >= Self.tries else { return pause(0.01) }
        tries = 0
        lastProduced = frame  // skipped: the next pass goes on after it
        run += 1
        let file = source.url.lastPathComponent
        if run == 1 {
            runStart = .now
            // once per bad frame: the thread comes back to it while the request stands, and on every pass of a loop
            if frame != skipped { logger.error("decode failed, frame skipped", metadata: ["file": "\(file)", "frame": "\(frame)", "error": "\(error)"]) }
            skipped = frame
            return
        }
        if !isFailing, runStart.duration(to: .now) >= .seconds(failingAfter) {
            isFailing = true
            logger.error("decode failing", metadata: ["file": "\(file)", "frame": "\(frame)", "error": "\(error)"])
            lastReport = .now
        } else if isFailing, lastReport.duration(to: .now) >= .seconds(reportEvery) {
            logger.warning("decode still failing", metadata: ["file": "\(file)", "skipped": "\(run)", "error": "\(error)"])
            lastReport = .now
        }
        if isFailing { failing?(error.clientText) }  // every time: the loader writes a new layer's status after starting its decoder
        pause(min(0.05 * Double(1 << min(run - 2, 10)), longestPause))
    }

    private func recovered(at frame: Int) {
        if isFailing {
            logger.info("decode recovered", metadata: ["file": "\(source.url.lastPathComponent)", "frame": "\(frame)", "skipped": "\(run)"])
            failing?(nil)
        }
        run = 0
        isFailing = false
    }

    /// Waits `seconds`, feeding audio meanwhile; a changed request does not cut it short, a stop does.
    private func pause(_ seconds: Double) {
        let until = DispatchTime.now() + seconds
        while running.load(ordering: .relaxed), DispatchTime.now() < until {
            let feeding = audio != nil && audioEnabled.load(ordering: .relaxed)
            if feeding, let audio { audio.channel.fill(from: audio.reader) }
            _ = wake.wait(timeout: feeding ? min(until, .now() + .milliseconds(10)) : until)
        }
    }
}
