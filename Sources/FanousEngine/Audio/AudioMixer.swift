// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import AudioToolbox
import Foundation
import Synchronization

/// The engine's one audio output (ADR-0019): an `AVAudioEngine` with a single `AVAudioSourceNode` whose
/// real-time render callback mixes every layer's PCM ring (`LayerAudioChannel.pull`).
///
/// `@unchecked Sendable`: `channels` and the atomics are immutable or thread-safe; `engine` is touched by
/// `start` / `stop` on the control side only.
public final class AudioMixer: @unchecked Sendable {
    /// One per layer, preallocated; `channels[i]` belongs to layer `i`.
    public let channels: [LayerAudioChannel]

    private let callbackCount = Atomic<Int>(0)
    private var engine: AVAudioEngine?

    /// `deviceUID` selects the output device. Device selection is a later phase: for now it is ignored and the
    /// system default output is used.
    public init(channels: Int, deviceUID: String? = nil) {
        self.channels = (0..<max(0, channels)).map { _ in LayerAudioChannel() }
        for channel in self.channels { channel.onActivate = { [weak self] in self?.ensureRunning() } }
    }

    deinit { engine?.stop() }

    // MARK: Lifecycle

    /// The engine stops this long after the last channel went inactive (unless `keepRunning` says otherwise).
    nonisolated(unsafe) public var idleStopSeconds = 10.0
    /// Tests: stand-ins for opening and closing the output device.
    nonisolated(unsafe) var startHook: (() throws -> Void)?
    nonisolated(unsafe) var stopHook: (() -> Void)?
    /// True while the output device is held open. Atomic so the compositor-side callback can look without a lock.
    private let runningFlag = Atomic<Bool>(false)
    private let control = DispatchQueue(label: "org.fanous.audio.control", qos: .utility)
    private var watchdog: DispatchSourceTimer?  // control queue only
    private var lastBusy = 0.0  // control queue only (host seconds)
    /// Show mode keeps the device open: no first-sound latency during a show.
    nonisolated(unsafe) public var keepRunning: (@Sendable () -> Bool)?
    /// A failed start (no device, wrong configuration): the layers play silent until the next attempt.
    nonisolated(unsafe) public var onError: (@Sendable (Error) -> Void)?
    public var isRunning: Bool { runningFlag.load(ordering: .relaxed) }

    /// Starts the engine in the background if it is not running (first media with audio opened, a channel turned active).
    /// Never blocks the caller; a running engine makes this one atomic load.
    public func ensureRunning() {
        guard !runningFlag.load(ordering: .relaxed) else { return }
        control.async { [self] in
            do { try startLocked() } catch { onError?(error) }
        }
    }

    private func startLocked() throws {
        guard !runningFlag.load(ordering: .relaxed) else { return }
        if let startHook { try startHook() } else { try start() }
        runningFlag.store(true, ordering: .relaxed)
        lastBusy = ProcessInfo.processInfo.systemUptime
        watchdog = DispatchSource.repeating(every: 1, on: control) { [weak self] in self?.checkIdle() }
    }

    private func checkIdle() {
        let now = ProcessInfo.processInfo.systemUptime
        if channels.contains(where: \.isActive) || keepRunning?() == true {
            lastBusy = now
        } else if now - lastBusy >= idleStopSeconds {
            stopLocked()
        }
    }

    private func stopLocked() {
        watchdog?.cancel()
        watchdog = nil
        if let stopHook { stopHook() } else { engine?.stop() }
        runningFlag.store(false, ordering: .relaxed)
    }

    /// Counters summed over all channels (`maxDriftMillis` is the worst channel); `callbacks` counts render callbacks.
    public var statistics: AudioStatistics {
        var total = AudioStatistics()
        total.callbacks = UInt64(callbackCount.load(ordering: .relaxed))
        for channel in channels {
            let s = channel.statistics
            total.underruns += s.underruns
            total.corrections += s.corrections
            total.maxDriftMillis = max(total.maxDriftMillis, s.maxDriftMillis)
        }
        return total
    }

    public func resetPeakDrift() {
        for channel in channels { channel.resetPeakDrift() }
    }

    // MARK: Engine

    /// Builds the engine on first use (so constructing a mixer never touches audio hardware) and starts it.
    public func start() throws {
        if engine == nil {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(LayerAudioChannel.sampleRate), channels: 2, interleaved: false) else {
                throw AudioError.converter(kAudioFormatUnsupportedDataFormatError)
            }
            // unowned(unsafe): the engine owns the node owns this block; a strong capture would be a cycle. `deinit`
            // stops the engine, which ends render callbacks, before `self` goes away.
            let node = AVAudioSourceNode(format: format) { [unowned(unsafe) self] _, _, frameCount, audioBufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                    let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
                else { return noErr }
                self.render(frames: Int(frameCount), left: left, right: right)
                return noErr
            }
            let engine = AVAudioEngine()
            engine.attach(node)
            // The main mixer feeds the default output device. `connect(_:to:format:)` is deprecated since macOS 27, but its
            // successor `connectNode` exists only in the macOS 27 SDK and CI builds with an older one; the floor is 15.
            // ponytail: switch to connectNode when the minimum SDK for building is 27
            engine.connect(node, to: engine.mainMixerNode, format: format)
            self.engine = engine
        }
        try engine?.start()
    }

    public func stop() { control.sync { stopLocked() } }

    // MARK: Render

    /// The render callback's body (also called directly by tests, which have no audio device). Overwrites
    /// `left` / `right` with the sum of all channels. Real-time safe.
    /// ponytail: no limiter; a sum above full scale clips at the device. Add one on the master if programme material needs it.
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        callbackCount.add(1, ordering: .relaxed)
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        let now = LayerAudioChannel.hostNanos()
        for i in 0..<channels.count {
            let channel = channels[i]
            channel.pull(into: left, right: right, frames: frames, wantedPTS: channel.wantedPTS(atHostNanos: now))
        }
    }
}
