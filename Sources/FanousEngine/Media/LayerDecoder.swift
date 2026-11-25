// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Logging
import Synchronization

/// One decode thread per layer (DESIGN.md §4.2). The compositor asks for a
/// frame index each tick; the thread fills the ring ahead in play direction
/// and restarts from the requested index on a seek. It decodes nothing before
/// the first request (B294): the first frame in the ring is the one the
/// compositor's hand-off asks for (the in point, or the out point in a reverse
/// mode; a slave's master position and direction, a chase's frame, B404),
/// not frame 0.
public final class LayerDecoder: @unchecked Sendable {
    public let ring: FrameRing
    public let source: MovieSource
    private let wanted = Atomic<Int>(-1)  // -1: no request yet
    private let direction = Atomic<Int>(1)
    /// The range the compositor plays, as `lo << 32 | hi + 1` (0: none), with bit 63 set for a bounce: the thread reads
    /// across a loop's wrap, or turns at a bounce's ends, itself, so the ring never holds a frame past the range and a
    /// wrap or a turn is not a seek (B293).
    private let loopBits = Atomic<UInt64>(0)
    private let running = Atomic<Bool>(true)
    private let wake = DispatchSemaphore(value: 0)
    /// What the decode thread was last woken for; a repeated request (paused clip) wakes nobody.
    private let signalledFrame = Atomic<Int>(-1)
    private let signalledDirection = Atomic<Int>(0)
    /// Wake-ups sent to the decode thread; diagnostics and tests.
    public let wakeups = Atomic<Int>(0)
    private let logger: Logger
    private(set) var thread: Thread?
    private var lastProduced = -1
    private var produceDirection = 0  // a bounce's leg the thread is on (decode thread only); 0 outside a bounce
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
    /// The channel's token for this decoder (`handOver()`), written with the channel; a fill passes it (B397).
    public var audioToken = 0
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
        // ADR-0002: decode runs at .userInteractive, above the control plane (B319); the HAP chunk pool's
        // concurrentPerform runs its iterations at this thread's class (measured: 33 from a .userInteractive caller)
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    public func stop() {
        running.store(false, ordering: .relaxed)
        wake.signal()
    }

    /// Called by the compositor every tick (never blocks). The thread is only woken when the frame or the direction
    /// differs from the last wake-up: while it has a full ring and nothing changes it sleeps.
    /// `loop`: the frames a loop or bounce mode plays, read across the wrap (`bounce` false) or turned at the ends
    /// (`bounce` true) in play direction; nil for the other modes.
    public func request(frame: Int, direction: Int, loop: ClosedRange<Int>? = nil, bounce: Bool = false) {
        let dir = direction >= 0 ? 1 : -1
        wanted.store(max(0, frame), ordering: .relaxed)  // -1 is "nothing asked yet"
        self.direction.store(dir, ordering: .relaxed)
        let bits = loop.map { UInt64(max(0, $0.lowerBound) & 0x7FFF_FFFF) << 32 | UInt64(max(0, $0.upperBound) + 1) } ?? 0
        loopBits.store(bits == 0 ? 0 : bits | (bounce ? 1 << 63 : 0), ordering: .relaxed)
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
            if audioEnabled.load(ordering: .acquiring), let audioReader, let audioChannel { audioChannel.fill(from: audioReader, producer: audioToken) }
            guard wanted.load(ordering: .relaxed) >= 0 else {  // nothing asked for yet (B294): the first frame must be the right one
                _ = wake.wait(timeout: .distantFuture)
                continue
            }
            guard let slot = ring.slotForWriting() else {
                // with audio to feed, keep topping it up while the video ring is full; otherwise sleep until a request changes
                _ = wake.wait(timeout: audioReader != nil && audioEnabled.load(ordering: .relaxed) ? .now() + .milliseconds(10) : .distantFuture)
                continue
            }
            let want = ((wanted.load(ordering: .relaxed) % count) + count) % count
            let dir = direction.load(ordering: .relaxed)
            var next = want
            if lastProduced < 0 || ring.isEmpty { produceDirection = 0 }  // a restart at the request takes the request's leg
            if lastProduced >= 0, !ring.isEmpty {
                // how far the last decoded frame runs ahead of the request in play direction; behind it (a seek, a slow
                // decode) this wraps to count − k and the thread restarts at the request. Inside a loop the distance is
                // measured around the loop, and the frame after its out point is its in point (B293): the ring then holds
                // the wrap and the compositor never drains it there
                let loop = loopBits.load(ordering: .relaxed)
                let bounce = loop >> 63 == 1
                let lo = Int((loop >> 32) & 0x7FFF_FFFF), hi = Int(loop & 0xFFFF_FFFF) - 1
                let ranged = loop != 0 && lo <= hi && hi < count && (lo...hi).contains(lastProduced) && (lo...hi).contains(want)
                if ranged, bounce {
                    // a bounce: the thread runs the leg in its own direction and turns at the ends, so the ring already holds the
                    // frames after a turn; `produceDirection` is where it is heading, which the request only resets on a seek
                    // (`wanted`, `direction` and `loopBits` are three relaxed atomics: one iteration may pair a new request
                    // with old bits, which the next one corrects)
                    if produceDirection == 0 { produceDirection = dir }
                    let d = (lastProduced - want) * produceDirection  // ahead of the request along the leg
                    if d < -ring.capacity || d > 2 * ring.capacity {
                        // a seek or a lost request: restart at the request in its direction
                        produceDirection = dir
                        next = want
                    } else {
                        next = lastProduced + produceDirection
                        if next > hi { produceDirection = -1; next = hi - 1 } else if next < lo { produceDirection = 1; next = lo + 1 }
                        next = min(hi, max(lo, next))
                    }
                } else {
                    produceDirection = 0
                    let span = ranged ? hi - lo + 1 : count
                    let ahead = dir > 0 ? (lastProduced - want + span) % span : (want - lastProduced + span) % span
                    next = ahead <= ring.capacity ? (lastProduced + dir + count) % count : want
                    if ranged, ahead <= ring.capacity {
                        if dir > 0, next > hi || next < lo { next = lo } else if dir < 0, next < lo || next > hi { next = hi }
                    }
                }
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
            // again at most once a second: the layer's status is cleared when a selection lands and must come back
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
            if feeding, let audioReader, let audioChannel { audioChannel.fill(from: audioReader, producer: audioToken) }
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
