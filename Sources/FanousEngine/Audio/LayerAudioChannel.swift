// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Synchronization

/// Counters read from atomics, safe to take from any thread.
public struct AudioStatistics: Sendable, Equatable {
    /// Render callbacks (mixer) or active pulls (channel).
    public var callbacks: UInt64 = 0
    /// Pulls that found fewer frames in the ring than they needed while the channel was active (end of media excluded),
    /// or that stayed silent because the audio was more than 100 ms off the clock or still the segment from before a
    /// retrigger or a hand-over to another file (B396). Includes the short gap after a seek or retrigger while the
    /// producer resyncs.
    public var underruns: UInt64 = 0
    /// Pulls that played the ring faster or slower to follow the layer clock (B321). The first pull of a segment, and
    /// the first after the channel was inactive, land on the clock and are not counted (B393).
    public var corrections: UInt64 = 0
    /// Largest |ring head PTS - wanted PTS| seen since the last `resetPeakDrift()`, in milliseconds. Drift beyond
    /// 100 ms is a pending resync (seek, retrigger) and is not recorded here; it counts as an underrun. The lag or
    /// lead a pull that lands on the clock removes (B393) is not recorded either: nothing of it was heard.
    public var maxDriftMillis: Double = 0

    public init() {}
}

/// One layer's audio: an SPSC ring of 48 kHz stereo Float32 frames between the layer's decode thread (producer,
/// `fill`) and the real-time render callback (consumer, `pull`), plus the atomics through which the compositor
/// tells both what the layer clock wants (`setState`). DESIGN.md §10, ADR-0019.
///
/// Invariants behind `@unchecked Sendable`:
/// - `tail` and the producer-only vars belong to the producer thread; `head`, `appliedGeneration`,
///   `alignedGeneration`, `alignNext`, `correcting` and the gain state belong to the consumer thread; everything else is an atomic. The producer never writes `head`.
///   The compositor's retrigger reaches the producer as `jumpGeneration` and the consumer as `staleSegment` (B394).
/// - One producer at a time (B397). The compositor's `handOver()` names the next producer in `owner`; a fill from
///   any other is ignored, and a fill holds `busy` so a thread that was already inside one (a read can stall for
///   tens of milliseconds, B391) finishes alone before the new producer's first fill. Each segment carries the token
///   of the producer that wrote it; the consumer plays only the owner's segments (B396), and the new producer
///   starts the ring over at its first fill.
/// - Frame indices only grow. The PTS of frame `i` is `basePTS + (i - baseIndex) / 48000`: one PTS pair per
///   contiguous segment. The producer rewrites the pair only while the ring is empty (first fill, or after the
///   consumer has acknowledged a flush), and publishes it before the `tail` release that makes the first frame
///   of the new segment visible, so the consumer, which reads `tail` (acquire) before the pair, sees a consistent one.
/// - Draining on a seek is a handshake because only the consumer may move `head`: the producer stores
///   `flushTarget = tail`, bumps `flushGeneration` (release) and waits; the consumer sees the new generation at
///   the top of its next pull and jumps `head` to the target. The producer refills once `head >= target`.
public final class LayerAudioChannel: @unchecked Sendable {
    public static let sampleRate = 48_000
    /// 250 ms.
    public static let capacity = 12_000
    /// ±20 ms: beyond this the consumer starts nudging the audio towards the clock, and keeps nudging until it is
    /// on it or the drift has changed sign (B394). Also how far past the ring's tail the clock may run before the
    /// producer reseeks (`needsReseek`).
    public static let driftToleranceFrames = 960
    /// 2 ms: the most one pull consumes more or fewer frames than it plays.
    public static let maxCorrectionFrames = 96
    /// 100 ms: beyond this the audio is too far off to nudge back. The producer reseeks, and until it has the
    /// consumer stays silent (and counts an underrun) instead of dropping or repeating stale audio.
    /// ponytail: a guess. Up to 100 ms off, the 2 ms-per-callback correction takes at most ~0.5 s at 480-frame callbacks (~1 s at 1024); tune from the drift statistics.
    public static let resyncThresholdFrames = 4800

    private static let rate = Double(sampleRate)

    private let storage: UnsafeMutablePointer<Float>  // capacity frames, interleaved L R
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    private let baseIndex = Atomic<Int>(0)
    private let basePTSBits = Atomic<UInt64>(0)  // Double bit pattern
    private let reachedEnd = Atomic<Bool>(false)  // producer hit the end of the media: an empty ring is not an underrun
    private let flushTarget = Atomic<Int>(0)
    private let flushGeneration = Atomic<Int>(0)

    // Compositor -> producer and consumer. The layer clock is stored as `media seconds - host seconds` (one atomic, so a
    // reader can never pair a new position with an old time); while the channel is active the clock runs 1:1 with host time.
    private let clockOffsetBits = Atomic<UInt64>(0)
    private let activeFlag = Atomic<Bool>(false)
    private let volumeBits = Atomic<UInt32>(Float(1).bitPattern)
    private let panBits = Atomic<UInt32>(Float(0).bitPattern)
    // Loop range of a forward loop (`setState(loop:)`): start (seconds) and length in frames; 0 frames = no loop.
    // One atomic so a reader never pairs a new start with an old length: start frame << 32 | length in frames.
    let loopBits = Atomic<UInt64>(0)  // internal for a test (B264)

    // Statistics.
    private let pullCount = Atomic<Int>(0)
    private let underrunCount = Atomic<Int>(0)
    private let correctionCount = Atomic<Int>(0)
    private let peakDriftMicros = Atomic<Int>(0)
    /// B393: counts the segments the producer started; the consumer's first pull of a segment lands on the clock exactly.
    private let segmentGeneration = Atomic<Int>(0)
    /// The segment that was current when the clock jumped (`jumpGeneration`): the consumer plays nothing of it, the
    /// producer starts a new one. 0 is the empty ring before any segment.
    private let staleSegment = Atomic<Int>(0)
    /// The producer the channel belongs to (`handOver()`), 0 before the first; a fill from another producer is ignored.
    private let owner = Atomic<Int>(0)
    /// A producer is inside `fill`.
    private let busy = Atomic<Bool>(false)
    /// The producer that wrote the current segment, published with the segment's pair: not the owner's → not heard.
    private let segmentOwner = Atomic<Int>(0)

    // Consumer thread only.
    private var appliedGeneration = 0
    private var alignedGeneration = 0  // the segment whose first pull landed on the clock (B393)
    private var alignNext = true  // the channel was inactive: the next pull lands on the clock (B393)
    private var correcting = 0  // -1: dropping frames, 1: repeating, until the audio is on the clock or the drift changes sign, not only until inside the window (B394)
    private var previousGainL: Float = 0
    private var previousGainR: Float = 0

    // Producer thread only.
    private var segmentValid = false
    private var startNewSegment = false  // the next frame written is the first of a new segment
    private var flushPending = false
    private var pendingFlushTarget = 0
    private var producerPTS = 0.0  // media time of the next frame the producer reads (loop wrap bookkeeping)
    private var seenJump = 0  // the `jumpGeneration` the producer last reseeked for
    private var lastProducer = 0  // the producer of the last fill: another one starts the ring over (B397)

    /// Bumped by `setState(jumped: true)` (the compositor retriggered the layer, so its clock jumped back). The
    /// producer reseeks at its next active fill, also when the jump is smaller than `resyncThresholdFrames` (B394):
    /// the new segment's first pull lands on the clock, where nudging would repeat frames towards it. A retrigger
    /// stores it after the clock (release), and the producer reads it (acquire) after it has seen the channel active
    /// and before it takes its clock, so a reseek never starts at the clock from before the jump.
    private let jumpGeneration = Atomic<Int>(0)

    public init() {
        storage = .allocate(capacity: Self.capacity * 2)
        storage.initialize(repeating: 0, count: Self.capacity * 2)
    }

    deinit { storage.deallocate() }

    // MARK: Compositor

    /// Called by the compositor every tick. `wantedPTS` is the media time (seconds) the layer clock is at now;
    /// `active` means speed is 100 % forward and the layer is playing; `pan` is -1 (left) ... 1 (right).
    /// `loop` is the media range [start, end) in seconds a forward loop plays; the producer then reads across the
    /// wrap (the ring holds the unwrapped timeline) and `wantedPTS` is compared modulo the loop length. Ignored
    /// when shorter than 0.5 s.
    /// `jumped` says the layer was retriggered this tick (its clock jumped back): the producer reseeks, whatever the
    /// size of the jump.
    /// Between ticks the audio side extrapolates the clock with the host clock (`wantedPTS(atHostNanos:)`), so the
    /// up to 16.7 ms age of the value does not eat into the ±20 ms window. `nanos`: the host time `wantedPTS` belongs
    /// to (tests pass one).
    public func setState(
        wantedPTS: Double, active: Bool, volume: Float, pan: Float, loop: (start: Double, end: Double)? = nil, jumped: Bool = false,
        atHostNanos nanos: UInt64 = LayerAudioChannel.hostNanos()
    ) {
        // B264: a loop that is no whole number of frames in 32 bits (NaN, or longer than ~25 h) is no loop; `Int(_:)` trapped
        let frames = loop.flatMap { Int(exactly: (($0.end - $0.start) * Self.rate).rounded()) } ?? 0
        let start = loop.flatMap { Int(exactly: ($0.start * Self.rate).rounded()) } ?? -1
        let fits = (Self.sampleRate / 2...Int(UInt32.max)).contains(frames) && (0...Int(UInt32.max)).contains(start)
        loopBits.store(fits ? UInt64(start) << 32 | UInt64(frames) : 0, ordering: .relaxed)
        clockOffsetBits.store((wantedPTS - Double(nanos) / 1e9).bitPattern, ordering: .relaxed)
        if jumped { jump() }  // after the clock: a fill that sees the jump sees the new clock
        volumeBits.store(volume.bitPattern, ordering: .relaxed)
        panBits.store(pan.bitPattern, ordering: .relaxed)
        let wasActive = activeFlag.exchange(active, ordering: .acquiringAndReleasing)
        if active && !wasActive { onActivate?() }
    }

    /// The channel goes to another file's decoder (the compositor's swap, after the file that had it was released, at
    /// an earlier swap, the end of a dissolve or this swap's retire of the outgoing, and before it enables the new
    /// one's audio): answers the token the new producer passes to `fill`. Whatever the ring holds, or the previous
    /// producer still writes from inside a fill it was in (B397), carries another token and is never heard; the new
    /// producer starts over at the clock (B396).
    @discardableResult public func handOver() -> Int {
        let token = owner.load(ordering: .relaxed) + 1
        owner.store(token, ordering: .releasing)
        return token
    }

    private func jump() {
        staleSegment.store(segmentGeneration.load(ordering: .relaxed), ordering: .relaxed)
        jumpGeneration.wrappingAdd(1, ordering: .releasing)
    }

    /// Called on the compositor thread when the channel turns active (the mixer starts its engine if it had stopped).
    /// Set once before the channel is used.
    nonisolated(unsafe) var onActivate: (@Sendable () -> Void)?

    /// Host time in nanoseconds (monotonic, does not tick during sleep); real-time safe.
    public static func hostNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// The layer clock at host time `nanos`: the compositor's last `wantedPTS`, advanced by the time since.
    /// Only meaningful while the channel is active.
    public func wantedPTS(atHostNanos nanos: UInt64) -> Double {
        Double(nanos) / 1e9 + Double(bitPattern: clockOffsetBits.load(ordering: .relaxed))
    }

    public var isActive: Bool { activeFlag.load(ordering: .acquiring) }

    // MARK: Inspection (any thread, approximate while the other side runs)

    /// Frames in the ring right now.
    public var bufferedFrames: Int { tail.load(ordering: .acquiring) - head.load(ordering: .acquiring) }
    /// Media time of the next frame the consumer would pull.
    public var nextFramePTS: Double { pts(ofFrame: head.load(ordering: .acquiring)) }

    public var statistics: AudioStatistics {
        var s = AudioStatistics()
        s.callbacks = UInt64(pullCount.load(ordering: .relaxed))
        s.underruns = UInt64(underrunCount.load(ordering: .relaxed))
        s.corrections = UInt64(correctionCount.load(ordering: .relaxed))
        s.maxDriftMillis = Double(peakDriftMicros.load(ordering: .relaxed)) / 1000
        return s
    }

    /// Starts a new `maxDriftMillis` window (call after reading `statistics`, e.g. once a second).
    public func resetPeakDrift() { peakDriftMicros.store(0, ordering: .relaxed) }

    private func pts(ofFrame index: Int) -> Double {
        Double(bitPattern: basePTSBits.load(ordering: .relaxed)) + Double(index - baseIndex.load(ordering: .relaxed)) / Self.rate
    }

    // MARK: Producer (the layer's decode thread)

    /// Tops the ring up to capacity from `reader`. If the layer was retriggered (`setState(jumped:)`), or the ring
    /// content is too far from the wanted PTS to be nudged back (more than `resyncThresholdFrames` off, or run dry
    /// more than 20 ms behind: a seek or loop wrap), starts over: drains (a handshake with the consumer, see the type
    /// comment), seeks the reader and refills.
    /// Does nothing while the channel is inactive.
    /// The ring's PTS is tracked per contiguous segment (base index and base PTS); `nextFramePTS` is that line
    /// evaluated at the head.
    /// A forward loop (`setState(loop:)`) is read across the wrap: the reader seeks back to the loop start when the
    /// loop end is reached and the ring just keeps filling, so a wrap is not a reseek and the consumer never runs dry.
    /// `producer` is the token `handOver()` gave this decoder; a fill with another one does nothing.
    public func fill(from reader: AudioTrackReader, producer: Int) {
        guard activeFlag.load(ordering: .acquiring) else { return }  // the clock read below is then at least the one that activated the channel
        let jump = jumpGeneration.load(ordering: .acquiring)  // before the clock, see `jumpGeneration`
        fill(wanted: wantedPTS(atHostNanos: Self.hostNanos()), jump: jump, producer: producer, read: { reader.read(into: $0, frameCount: $1) }, seek: { reader.seek(toSeconds: $0) })
    }

    /// `fill` against any frame source (tests use a synthetic one) and an explicit layer clock. `read` writes up to
    /// `n` interleaved frames and returns how many it wrote (fewer only at the end of the media) and the PTS of the first.
    /// `jump` is the `jumpGeneration` read before `wanted` was taken (read here when nil). `producer` is the token of
    /// the caller (0 fits a channel never handed over).
    func fill(wanted: Double, jump: Int? = nil, producer: Int = 0, read: (UnsafeMutablePointer<Float>, Int) -> (framesRead: Int, firstFramePTS: Double), seek: (Double) -> Void) {
        // B397: another producer is inside a fill: nothing, try again later. The owner check is under `busy`, so a
        // producer that lost the channel while the new one filled cannot slip in behind it.
        guard !busy.exchange(true, ordering: .acquiring) else { return }
        defer { busy.store(false, ordering: .releasing) }
        guard owner.load(ordering: .acquiring) == producer, activeFlag.load(ordering: .acquiring) else { return }
        let jump = jump ?? jumpGeneration.load(ordering: .acquiring)
        let jumped = jump != seenJump || producer != lastProducer  // a new producer starts the ring over (B396)
        seenJump = jump  // a restart below starts at `wanted`, so every branch answers the jump
        lastProducer = producer
        if flushPending {
            guard head.load(ordering: .acquiring) >= pendingFlushTarget else { return }  // consumer has not drained yet
            flushPending = false
            restart(at: wanted, seek)
        } else if !segmentValid {
            restart(at: wanted, seek)
        } else if jumped || needsReseek(wanted) {
            let t = tail.load(ordering: .relaxed)
            if head.load(ordering: .acquiring) == t {
                restart(at: wanted, seek)  // already empty: nothing to drain
            } else {
                pendingFlushTarget = t
                flushTarget.store(t, ordering: .relaxed)
                flushGeneration.wrappingAdd(1, ordering: .releasing)
                flushPending = true
                return
            }
        }
        topUp(read, seek)
    }

    private func restart(at wanted: Double, _ seek: (Double) -> Void) {
        var wanted = wanted
        let (loopStart, loopLength) = loopRange
        if loopLength > 0 {  // the extrapolated clock can be a tick past the loop end: fold it back in
            let span = Double(loopLength) / Self.rate
            if wanted >= loopStart + span { wanted = loopStart + (wanted - loopStart).truncatingRemainder(dividingBy: span) }
        }
        seek(wanted)
        producerPTS = wanted
        startNewSegment = true
        segmentValid = false
        reachedEnd.store(false, ordering: .relaxed)
    }

    /// The audio is too far from the layer clock for the consumer to nudge it back (`resyncThresholdFrames`), or the
    /// ring has run dry more than the tolerance behind it. Between two pulls the head runs up to one callback ahead
    /// of the clock, so a clock a little behind the ring is normal, never a reason to reseek.
    private func needsReseek(_ wanted: Double) -> Bool {
        let resync = Double(Self.resyncThresholdFrames) / Self.rate
        let ahead = wrapped(wanted - pts(ofFrame: head.load(ordering: .acquiring)))  // > 0: the clock is ahead of the head
        let pastEnd = wrapped(wanted - pts(ofFrame: tail.load(ordering: .relaxed)))
        if ahead < -resync { return true }  // jumped back without a retrigger, or the audio is far ahead
        if ahead > resync || pastEnd > Double(Self.driftToleranceFrames) / Self.rate {
            // Past the end of the media there is nothing to refill; only a jump back reseeks.
            return !reachedEnd.load(ordering: .relaxed) || pastEnd <= 0
        }
        return false
    }

    /// `d` seconds folded into ±half a loop length when a loop is set (the ring's PTS line is unwrapped, the clock wraps).
    private func wrapped(_ d: Double) -> Double {
        let span = Double(loopRange.length) / Self.rate
        return span > 0 ? d - span * (d / span).rounded() : d
    }

    private var loopRange: (start: Double, length: Int) {
        let bits = loopBits.load(ordering: .relaxed)
        return (Double(bits >> 32) / Self.rate, Int(bits & 0xFFFF_FFFF))
    }

    private func topUp(_ read: (UnsafeMutablePointer<Float>, Int) -> (framesRead: Int, firstFramePTS: Double), _ seek: (Double) -> Void) {
        let (loopStart, loopLength) = loopRange
        let loopEnd = loopStart + Double(loopLength) / Self.rate
        while true {
            let t = tail.load(ordering: .relaxed)
            let space = Self.capacity - (t - head.load(ordering: .acquiring))
            if space <= 0 { return }
            let position = t % Self.capacity
            var n = min(space, Self.capacity - position)  // contiguous run; the next loop pass handles the wrap
            let looping = loopLength > 0 && producerPTS >= loopStart - 0.001 && producerPTS < loopEnd
            if looping { n = min(n, max(1, Int(((loopEnd - producerPTS) * Self.rate).rounded()))) }  // stop at the loop end
            var (got, firstPTS) = read(storage + 2 * position, n)
            var padded = false
            if looping && got < n && firstPTS + Double(got) / Self.rate >= loopEnd - 0.1 {
                // The source ends a little before the loop end (rounding, or an audio track a bit shorter than the
                // video): pad with silence so every lap is exactly the loop length, and wrap instead of ending.
                (storage + 2 * (position + got)).update(repeating: 0, count: 2 * (n - got))
                got = n
                padded = true
            }
            if startNewSegment {  // ring is empty here, so the consumer is not using the pair
                baseIndex.store(t, ordering: .relaxed)
                basePTSBits.store(firstPTS.bitPattern, ordering: .relaxed)
                segmentGeneration.wrappingAdd(1, ordering: .relaxed)  // published by the tail's release below
                segmentOwner.store(lastProducer, ordering: .relaxed)  // this fill's producer, which may no longer be the owner
                startNewSegment = false
                segmentValid = true
            }
            if got > 0 { tail.store(t + got, ordering: .releasing) }
            producerPTS = padded ? producerPTS + Double(n) / Self.rate : firstPTS + Double(got) / Self.rate  // a padded read leaves the reader's PTS at the end
            if looping && got == n && producerPTS >= loopEnd - 0.5 / Self.rate {
                seek(loopStart)  // wrap: continue in the same segment, the ring timeline is unwrapped
                producerPTS = loopStart
            }
            if got < n {
                reachedEnd.store(true, ordering: .relaxed)
                return
            }
        }
    }

    // MARK: Consumer (real-time render callback)

    /// Balance law for stereo programme material: unity at centre, the opposite channel fades linearly
    /// to silence at the extremes (`pan` in -1 ... 1). A constant-power law would dip stereo files by 3 dB.
    public static func panGains(_ pan: Float) -> (left: Float, right: Float) {
        let p = min(1, max(-1, pan))
        return (min(1, 1 - p), min(1, 1 + p))
    }

    /// Adds `frames` frames to `left` / `right`, scaled by volume and pan, and consumes them from the ring.
    /// Follows the layer clock (`wantedPTS`): beyond ±20 ms it starts consuming more frames than it plays (audio
    /// behind) or fewer (audio ahead), at most 96 more or fewer per call, resampled over the whole callback so the
    /// waveform has no jump (B321), and keeps doing so until the audio is on the clock or the drift has changed sign,
    /// not only until it is inside the window (B394); an underrun starts the same correction for the frames it missed.
    /// Beyond ±100 ms it stays silent until the producer has
    /// resynced. The first pull of a segment (a start, a retrigger, a seek), and the first after the channel was
    /// inactive (a resume), land on the clock: when the audio is behind it by up to 100 ms they drop straight to it,
    /// since nothing of it has been heard yet, and the 28 to 35 ms between the producer's seek at the clock and the
    /// first render callback (the output device still starting) would otherwise stay as a lag inside the window for
    /// the whole clip (B393); when the audio is ahead of it (a resume, where the last pull before the pause ran up to
    /// one callback past it) they wait, silent until the clock reaches the first frame (B394). The frames dropped
    /// there are never heard. Silent and consuming nothing while inactive, and while the ring still holds the segment
    /// from before a jump or a hand-over to another file (B396), until the producer has started a new one.
    /// Real-time safe: no allocation, no locks, no logging.
    public func pull(into left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, wantedPTS: Double) {
        let generation = flushGeneration.load(ordering: .acquiring)
        if generation != appliedGeneration {
            appliedGeneration = generation
            head.store(flushTarget.load(ordering: .relaxed), ordering: .releasing)
        }
        let active = activeFlag.load(ordering: .acquiring)
        guard active, frames > 0 else {
            previousGainL = 0
            previousGainR = 0
            if !active { alignNext = true }
            return
        }
        pullCount.add(1, ordering: .relaxed)

        let volume = max(0, Float(bitPattern: volumeBits.load(ordering: .relaxed)))
        let pan = Self.panGains(Float(bitPattern: panBits.load(ordering: .relaxed)))
        let targetL = volume * pan.left
        let targetR = volume * pan.right

        let h = head.load(ordering: .relaxed)
        let available = tail.load(ordering: .acquiring) - h
        var skip = 0  // frames a landing cuts: never heard
        var drops = 0  // a correction: frames played faster to catch up with the clock
        var repeats = 0  // a correction: frames played slower to let the clock catch up
        var lead = 0  // frames of silence before the ring's first frame: a landing found the audio ahead of the clock
        if available > 0 {
            var drift = Self.frames(from: wrapped(pts(ofFrame: h) - wantedPTS) * Self.rate)  // < 0: audio is behind the clock
            if abs(drift) > Self.resyncThresholdFrames {  // a seek or retrigger the producer has not caught up with yet
                previousGainL = targetL
                previousGainR = targetR
                underrunCount.add(1, ordering: .relaxed)
                return
            }
            let generation = segmentGeneration.load(ordering: .relaxed)  // ordered by the tail load above
            // the segment from before a jump (not this clock's) or from a producer the channel was taken from (not this file's): not heard
            if generation == staleSegment.load(ordering: .relaxed) || segmentOwner.load(ordering: .relaxed) != owner.load(ordering: .relaxed) {
                previousGainL = targetL
                previousGainR = targetR
                underrunCount.add(1, ordering: .relaxed)
                return
            }
            if alignNext || generation != alignedGeneration {  // the first frames heard of a segment, or after a pause: land on the clock, no correction
                if drift < 0 {
                    skip = min(-drift, available)
                } else {
                    lead = min(drift, frames)
                }
                drift = 0
                if skip < available && lead < frames {  // landed; a ring that held less than the lag, or a lead of a whole callback, is tried again at the next pull
                    alignedGeneration = generation
                    alignNext = false
                    correcting = 0
                }
            }
            peakDriftMicros.max(abs(drift) * 1_000_000 / Self.sampleRate, ordering: .relaxed)
            if abs(drift) > Self.driftToleranceFrames { correcting = drift < 0 ? -1 : 1 }
            if correcting != 0 {
                if (drift < 0) != (correcting < 0) {
                    correcting = 0  // the drift changed sign (a nudge overshot by the clock's jitter): done, no nudging back
                } else if correcting < 0 {
                    drops = min(Self.maxCorrectionFrames, -drift, available)
                } else {
                    repeats = min(Self.maxCorrectionFrames, drift, frames - 1)
                }
                if abs(drift) <= Self.maxCorrectionFrames { correcting = 0 }  // this pull puts the audio on the clock
            }
            if drops > 0 || repeats > 0 { correctionCount.add(1, ordering: .relaxed) }
        }

        // Gains ramp linearly over the audible part of the callback so fades, pan moves and a resume do not zipper.
        var gainL = previousGainL
        var gainR = previousGainR
        let stepL = (targetL - gainL) / Float(max(1, frames - lead))
        let stepR = (targetR - gainR) / Float(max(1, frames - lead))
        let usable = available - skip
        var position = (h + skip) % Self.capacity
        var written = lead  // the silence of a landing that waits for the clock (the output is mixed into, so nothing to write)
        var consumed = 0
        let corrected = drops > 0 || repeats > 0
        if corrected {
            // B321: the correction is spread over the callback, a resample instead of a cut. `consumed` ring frames (the
            // drop: the callback plus up to 96, the repeat: the callback less up to 96) are read at a constant step by
            // linear interpolation into `outputs` frames, the first on the frame after the last one heard, the last on
            // the last one consumed, so the waveform runs on without a jump: up to 2 ms faster or slower for one callback.
            let outputs = drops > 0 ? min(frames, usable - drops) : min(frames, repeats + usable)
            consumed = outputs - repeats + drops
            let span = max(1, outputs - 1)
            for k in 0..<outputs {
                let i = k * (consumed - 1) / span  // integer position and fraction: the last output is exactly the last frame
                let t = Float(k * (consumed - 1) % span) / Float(span)
                let a = 2 * ((position + i) % Self.capacity)
                let b = 2 * ((position + min(i + 1, consumed - 1)) % Self.capacity)
                gainL += stepL
                gainR += stepR
                left[k] += (storage[a] + t * (storage[b] - storage[a])) * gainL
                right[k] += (storage[a + 1] + t * (storage[b + 1] - storage[a + 1])) * gainR
            }
            written = outputs
        }
        let toMix = corrected ? 0 : min(frames - written, usable)
        consumed += toMix
        var remaining = toMix
        while remaining > 0 {
            let run = min(remaining, Self.capacity - position)
            for k in 0..<run {
                gainL += stepL
                gainR += stepR
                left[written + k] += storage[2 * (position + k)] * gainL
                right[written + k] += storage[2 * (position + k) + 1] * gainR
            }
            written += run
            remaining -= run
            position = (position + run) % Self.capacity
        }
        if lead < frames {  // a whole callback of waiting leaves the ramp for the pull that plays
            previousGainL = targetL
            previousGainR = targetR
        }
        head.store(h + skip + consumed, ordering: .releasing)
        if written < frames && !reachedEnd.load(ordering: .relaxed) {
            underrunCount.add(1, ordering: .relaxed)
            correcting = -1  // the frames that were not there are a lag now: nudged out, however short (B394)
        }
    }

    /// Frames from a possibly non-finite or absurd Double without trapping.
    private static func frames(from value: Double) -> Int {
        let rounded = value.rounded()
        return rounded.isFinite ? Int(max(-1e9, min(1e9, rounded))) : 0
    }
}
