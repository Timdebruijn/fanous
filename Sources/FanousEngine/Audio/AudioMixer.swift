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
    /// Mach ticks to nanoseconds, read once here: the render callback converts its buffer's host time with it.
    private let timebase: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase
    }()
    /// The output device's latency after the buffer's host time (B406), in nanoseconds; set by `start`, 0 until then.
    let outputLatencyNanos = Atomic<UInt64>(0)

    /// Plays to the system default output (device selection: B4).
    public init(channels: Int) {
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
    /// The engine opened the output device: its name and the output latency `start` read (B406), for the log.
    nonisolated(unsafe) public var onOutputLatency: (@Sendable (_ device: String, _ millis: Double) -> Void)?
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
            let node = AVAudioSourceNode(format: format) { [unowned(unsafe) self] _, timestamp, frameCount, audioBufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                    let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
                else { return noErr }
                self.render(frames: Int(frameCount), left: left, right: right, atHostNanos: self.heard(timestamp.pointee))
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
        // read at every open: the engine reopens after an idle stop, so a device changed meanwhile is read then
        // ponytail: a route change while the engine runs keeps the old latency until the next idle stop; listen to
        // AVAudioEngineConfigurationChange if that turns out to matter
        if let device = engine?.outputNode.auAudioUnit.deviceID {
            let latency = Self.outputLatency(device: device)
            outputLatencyNanos.store(latency.nanos, ordering: .relaxed)
            onOutputLatency?(latency.name, Double(latency.nanos) / 1e6)
        }
    }

    /// The output latency of `device` after a render buffer's host time: device latency plus the first output stream's
    /// latency. Not the IO buffer or the safety offset: the buffer's host time already lies that far ahead of the
    /// callback (measured 2026-11-25 on a 512-frame buffer with a 74-frame safety offset: 12.1 ms, which is 512 + 74
    /// frames at 48 kHz). A property the device does not have counts 0.
    static func outputLatency(device: AudioObjectID) -> (nanos: UInt64, name: String) {
        let output = kAudioObjectPropertyScopeOutput, global = kAudioObjectPropertyScopeGlobal
        var deviceFrames: UInt32 = 0, streamFrames: UInt32 = 0, rate: Float64 = 0
        var name: Unmanaged<CFString>?
        _ = read(device, kAudioDevicePropertyLatency, output, into: &deviceFrames)
        _ = read(device, kAudioDevicePropertyNominalSampleRate, global, into: &rate)
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: output, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &size) == noErr, size >= 4 {
            var ids = [AudioStreamID](repeating: 0, count: Int(size) / 4)
            if AudioObjectGetPropertyData(device, &streams, 0, nil, &size, &ids) == noErr {
                _ = read(ids[0], kAudioStreamPropertyLatency, global, into: &streamFrames)
            }
        }
        let named = read(device, kAudioObjectPropertyName, global, into: &name)
        let nanos = latencyNanos(frames: UInt64(deviceFrames) + UInt64(streamFrames), sampleRate: rate)
        return (nanos, named ? (name?.takeRetainedValue() as String?) ?? "" : "")
    }

    /// One fixed-size HAL property into `value`; false, `value` untouched, when `object` does not have it.
    private static func read<T>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, into value: inout T
    ) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    /// `frames` at `sampleRate` in nanoseconds; 0 without a rate.
    static func latencyNanos(frames: UInt64, sampleRate: Double) -> UInt64 {
        sampleRate > 0 ? UInt64((Double(frames) / sampleRate * 1e9).rounded()) : 0
    }

    /// Mach ticks in nanoseconds (`CLOCK_UPTIME_RAW`'s unit), without overflowing the multiplication.
    static func nanos(ticks: UInt64, _ timebase: mach_timebase_info_data_t) -> UInt64 {
        let numer = UInt64(timebase.numer), denom = UInt64(max(1, timebase.denom))
        return ticks / denom * numer + ticks % denom * numer / denom
    }

    /// The host time (nanoseconds) the first frame of the buffer stamped `stamp` is heard at: its host time plus the
    /// output latency; now when the stamp carries no host time. Real-time safe.
    func heard(_ stamp: AudioTimeStamp) -> UInt64 {
        guard stamp.mFlags.contains(.hostTimeValid) else { return LayerAudioChannel.hostNanos() }
        return Self.nanos(ticks: stamp.mHostTime, timebase) + outputLatencyNanos.load(ordering: .relaxed)
    }

    public func stop() { control.sync { stopLocked() } }

    // MARK: Render

    /// The render callback's body (also called directly by tests, which have no audio device). Overwrites
    /// `left` / `right` with the sum of all channels. `now`: the host time the buffer is heard at (`heard`), at which
    /// each channel's clock is read (B406). Real-time safe.
    /// ponytail: no limiter; a sum above full scale clips at the device. Add one on the master if programme material needs it.
    func render(
        frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
        atHostNanos now: UInt64 = LayerAudioChannel.hostNanos()
    ) {
        callbackCount.add(1, ordering: .relaxed)
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        for i in 0..<channels.count {
            let channel = channels[i]
            channel.pull(into: left, right: right, frames: frames, wantedPTS: channel.wantedPTS(atHostNanos: now))
        }
    }
}
