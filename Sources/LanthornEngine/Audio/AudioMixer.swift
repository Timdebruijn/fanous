// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import AudioToolbox
import Foundation
import Synchronization

/// The engine's one audio output (ADR-0019): an `AVAudioEngine` with a single `AVAudioSourceNode` whose
/// real-time render callback mixes every layer's PCM ring (`LayerAudioChannel.pull`) and applies the master volume.
///
/// `@unchecked Sendable`: `channels` and the atomics are immutable or thread-safe; `previousMaster` belongs to the
/// render thread; `engine` / `sourceNode` are touched by `start` / `stop` on the control side only.
public final class AudioMixer: @unchecked Sendable {
    /// One per layer, preallocated; `channels[i]` belongs to layer `i`.
    public let channels: [LayerAudioChannel]

    private let masterBits = Atomic<UInt32>(Float(1).bitPattern)
    private let callbackCount = Atomic<Int>(0)
    private var previousMaster: Float = 1  // render thread only
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    /// `deviceUID` selects the output device. Device selection is a later phase: for now it is ignored and the
    /// system default output is used.
    public init(channels: Int, deviceUID: String? = nil) {
        self.channels = (0..<max(0, channels)).map { _ in LayerAudioChannel() }
    }

    deinit { engine?.stop() }

    /// Master gain, 0 ... 1 (not clamped above). Ramped across each callback.
    public var masterVolume: Float {
        get { Float(bitPattern: masterBits.load(ordering: .relaxed)) }
        set { masterBits.store(newValue.bitPattern, ordering: .relaxed) }
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
            // The main mixer feeds the default output device. `connect(_:to:format:)` is deprecated since macOS 27 but the floor is 15.
            if #available(macOS 27.0, *) {
                try engine.connectNode(node, to: engine.mainMixerNode, format: format)
            } else {
                engine.connect(node, to: engine.mainMixerNode, format: format)
            }
            self.engine = engine
            sourceNode = node
        }
        try engine?.start()
    }

    public func stop() { engine?.stop() }

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
        let target = masterVolume
        if (target != 1 || previousMaster != 1) && frames > 0 {
            let step = (target - previousMaster) / Float(frames)
            var gain = previousMaster
            for i in 0..<frames {
                gain += step
                left[i] *= gain
                right[i] *= gain
            }
        }
        previousMaster = target
    }
}
