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
    /// or that stayed silent because the audio was more than 100 ms off the clock. Includes the short gap after a
    /// seek or retrigger while the producer resyncs.
    public var underruns: UInt64 = 0
    /// Pulls that dropped or repeated frames to follow the layer clock.
    public var corrections: UInt64 = 0
    /// Largest |ring head PTS - wanted PTS| seen since the last `resetPeakDrift()`, in milliseconds. Drift beyond
    /// 100 ms is a pending resync (seek, retrigger) and is not recorded here; it counts as an underrun.
    public var maxDriftMillis: Double = 0

    public init() {}
}

/// One layer's audio: an SPSC ring of 48 kHz stereo Float32 frames between the layer's decode thread (producer,
/// `fill`) and the real-time render callback (consumer, `pull`), plus the atomics through which the compositor
/// tells both what the layer clock wants (`setState`). DESIGN.md §10, ADR-0019.
///
/// Invariants behind `@unchecked Sendable`:
/// - `tail` and the producer-only vars belong to the producer thread; `head`, `appliedGeneration` and the gain
///   state belong to the consumer thread; everything else is an atomic. The producer never writes `head`.
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
    /// ±20 ms: the window inside which audio and layer clock are considered in sync.
    public static let driftToleranceFrames = 960
    /// 2 ms: the most one pull drops or repeats.
    public static let maxCorrectionFrames = 96
    /// 100 ms: beyond this the audio is too far off to nudge back. The producer reseeks, and until it has the
    /// consumer stays silent (and counts an underrun) instead of dropping or repeating stale audio.
    /// ponytail: a guess. Between 20 and 100 ms the 2 ms-per-callback correction takes at most ~0.5 s; tune from the drift statistics.
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

    // Statistics.
    private let pullCount = Atomic<Int>(0)
    private let underrunCount = Atomic<Int>(0)
    private let correctionCount = Atomic<Int>(0)
    private let peakDriftMicros = Atomic<Int>(0)

    // Consumer thread only.
    private var appliedGeneration = 0
    private var previousGainL: Float = 0
    private var previousGainR: Float = 0

    // Producer thread only.
    private var segmentValid = false
    private var startNewSegment = false  // the next frame written is the first of a new segment
    private var flushPending = false
    private var pendingFlushTarget = 0

    public init() {
        storage = .allocate(capacity: Self.capacity * 2)
        storage.initialize(repeating: 0, count: Self.capacity * 2)
    }

    deinit { storage.deallocate() }

    // MARK: Compositor

    /// Called by the compositor every tick. `wantedPTS` is the media time (seconds) the layer clock is at now;
    /// `active` means speed is 100 % forward and the layer is playing; `pan` is -1 (left) ... 1 (right).
    /// Between ticks the audio side extrapolates the clock with the host clock (`wantedPTS(atHostNanos:)`), so the
    /// up to 16.7 ms age of the value does not eat into the ±20 ms window.
    public func setState(wantedPTS: Double, active: Bool, volume: Float, pan: Float) {
        setState(wantedPTS: wantedPTS, active: active, volume: volume, pan: pan, atHostNanos: Self.hostNanos())
    }

    func setState(wantedPTS: Double, active: Bool, volume: Float, pan: Float, atHostNanos nanos: UInt64) {
        clockOffsetBits.store((wantedPTS - Double(nanos) / 1e9).bitPattern, ordering: .relaxed)
        volumeBits.store(volume.bitPattern, ordering: .relaxed)
        panBits.store(pan.bitPattern, ordering: .relaxed)
        let wasActive = activeFlag.exchange(active, ordering: .acquiringAndReleasing)
        if active && !wasActive { onActivate?() }
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

    /// Tops the ring up to capacity from `reader`. If the ring content is too far from the wanted PTS to be nudged
    /// back (more than `resyncThresholdFrames` off, or run dry more than 20 ms behind: a seek, retrigger or loop wrap),
    /// starts over: drains (a handshake with the consumer, see the type comment), seeks the reader and refills.
    /// Does nothing while the channel is inactive.
    /// The ring's PTS is tracked per contiguous segment (base index and base PTS); `nextFramePTS` is that line
    /// evaluated at the head.
    /// ponytail: a loop wrap is a reseek (a callback of silence), not a gapless read across the loop point.
    public func fill(from reader: AudioTrackReader) {
        fill(from: reader, wanted: wantedPTS(atHostNanos: Self.hostNanos()))
    }

    func fill(from reader: AudioTrackReader, wanted: Double) {
        fill(wanted: wanted, read: { reader.read(into: $0, frameCount: $1) }, seek: { reader.seek(toSeconds: $0) })
    }

    /// `fill` against any frame source (tests use a synthetic one) and an explicit layer clock. `read` writes up to
    /// `n` interleaved frames and returns how many it wrote (fewer only at the end of the media) and the PTS of the first.
    func fill(wanted: Double, read: (UnsafeMutablePointer<Float>, Int) -> (framesRead: Int, firstFramePTS: Double), seek: (Double) -> Void) {
        guard activeFlag.load(ordering: .acquiring) else { return }
        if flushPending {
            guard head.load(ordering: .acquiring) >= pendingFlushTarget else { return }  // consumer has not drained yet
            flushPending = false
            restart(at: wanted, seek)
        } else if !segmentValid {
            restart(at: wanted, seek)
        } else if needsReseek(wanted) {
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
        topUp(read)
    }

    private func restart(at wanted: Double, _ seek: (Double) -> Void) {
        seek(wanted)
        startNewSegment = true
        segmentValid = false
        reachedEnd.store(false, ordering: .relaxed)
    }

    /// The audio is too far from the layer clock for the consumer to nudge it back (`resyncThresholdFrames`), or the
    /// ring has run dry more than the tolerance behind it.
    private func needsReseek(_ wanted: Double) -> Bool {
        let resync = Double(Self.resyncThresholdFrames) / Self.rate
        let headPTS = pts(ofFrame: head.load(ordering: .acquiring))
        let endPTS = pts(ofFrame: tail.load(ordering: .relaxed))
        if wanted < headPTS - resync { return true }  // jumped back (retrigger, loop wrap), or the audio is far ahead
        if wanted > headPTS + resync || wanted > endPTS + Double(Self.driftToleranceFrames) / Self.rate {
            // Past the end of the media there is nothing to refill; only a jump back reseeks.
            return !reachedEnd.load(ordering: .relaxed) || wanted <= endPTS
        }
        return false
    }

    private func topUp(_ read: (UnsafeMutablePointer<Float>, Int) -> (framesRead: Int, firstFramePTS: Double)) {
        while true {
            let t = tail.load(ordering: .relaxed)
            let space = Self.capacity - (t - head.load(ordering: .acquiring))
            if space <= 0 { return }
            let position = t % Self.capacity
            let n = min(space, Self.capacity - position)  // contiguous run; the next loop pass handles the wrap
            let (got, firstPTS) = read(storage + 2 * position, n)
            if startNewSegment {  // ring is empty here, so the consumer is not using the pair
                baseIndex.store(t, ordering: .relaxed)
                basePTSBits.store(firstPTS.bitPattern, ordering: .relaxed)
                startNewSegment = false
                segmentValid = true
            }
            if got > 0 { tail.store(t + got, ordering: .releasing) }
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
    /// Follows the layer clock (`wantedPTS`): beyond ±20 ms it drops frames (audio behind) or repeats the first
    /// frame (audio ahead), at most 96 frames per call. Beyond ±100 ms it stays silent until the producer has
    /// resynced. Silent and consuming nothing while inactive.
    /// Real-time safe: no allocation, no locks, no logging.
    /// ponytail: hard drop/repeat as DESIGN.md §10 specifies; interpolating over the callback would be click-free.
    public func pull(into left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, wantedPTS: Double) {
        let generation = flushGeneration.load(ordering: .acquiring)
        if generation != appliedGeneration {
            appliedGeneration = generation
            head.store(flushTarget.load(ordering: .relaxed), ordering: .releasing)
        }
        guard activeFlag.load(ordering: .acquiring), frames > 0 else {
            previousGainL = 0
            previousGainR = 0
            return
        }
        pullCount.add(1, ordering: .relaxed)

        let volume = max(0, Float(bitPattern: volumeBits.load(ordering: .relaxed)))
        let pan = Self.panGains(Float(bitPattern: panBits.load(ordering: .relaxed)))
        let targetL = volume * pan.left
        let targetR = volume * pan.right

        let h = head.load(ordering: .relaxed)
        let available = tail.load(ordering: .acquiring) - h
        var skip = 0
        var repeats = 0
        if available > 0 {
            let drift = Self.frames(from: (pts(ofFrame: h) - wantedPTS) * Self.rate)  // < 0: audio is behind the clock
            if abs(drift) > Self.resyncThresholdFrames {  // a seek or retrigger the producer has not caught up with yet
                previousGainL = targetL
                previousGainR = targetR
                underrunCount.add(1, ordering: .relaxed)
                return
            }
            peakDriftMicros.max(abs(drift) * 1_000_000 / Self.sampleRate, ordering: .relaxed)
            if drift < -Self.driftToleranceFrames {
                skip = min(Self.maxCorrectionFrames, -drift, available)
            } else if drift > Self.driftToleranceFrames {
                repeats = min(Self.maxCorrectionFrames, drift, frames - 1)
            }
            if skip > 0 || repeats > 0 { correctionCount.add(1, ordering: .relaxed) }
        }

        // Gains ramp linearly over the callback so fades and pan moves do not zipper.
        var gainL = previousGainL
        var gainR = previousGainR
        let stepL = (targetL - gainL) / Float(frames)
        let stepR = (targetR - gainR) / Float(frames)
        let usable = available - skip
        var position = (h + skip) % Self.capacity
        var written = 0
        if repeats > 0 && usable > 0 {
            let l = storage[2 * position]
            let r = storage[2 * position + 1]
            while written < repeats {
                gainL += stepL
                gainR += stepR
                left[written] += l * gainL
                right[written] += r * gainR
                written += 1
            }
        }
        let toMix = min(frames - written, usable)
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
        previousGainL = targetL
        previousGainR = targetR
        head.store(h + skip + toMix, ordering: .releasing)
        if written < frames && !reachedEnd.load(ordering: .relaxed) { underrunCount.add(1, ordering: .relaxed) }
    }

    /// Frames from a possibly non-finite or absurd Double without trapping.
    private static func frames(from value: Double) -> Int {
        let rounded = value.rounded()
        return rounded.isFinite ? Int(max(-1e9, min(1e9, rounded))) : 0
    }
}
