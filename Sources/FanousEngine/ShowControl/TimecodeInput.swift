// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import CoreAudio
import CoreMIDI
import Foundation
import FanousCore
import Logging
import QuartzCore
import Synchronization

/// The timecode the engine chases (DESIGN.md §15.1): one sample written by the active source, read by
/// the compositor every tick (never blocks) and by the live feed. Frames are extrapolated from the host
/// time of the last decoded frame; after `freewheelSeconds` without frames the clock is lost.
public final class TimecodeClock: @unchecked Sendable {
    public enum State: String, Sendable { case off, locked, freewheel, lost }

    public struct Sample: Sendable, Equatable {
        public var frameCount: Int = 0
        public var rate: TimecodeRate = .fps25
        public var hostTime: Double = 0
        public var state: State = .off
        public var source: String = ""
        /// Frames between the source's updates: LTC decodes every frame, MTC assembles a time every 2 (B65).
        public var updateFrames: Int = 1

        public var timecode: Timecode { Timecode(frameCount: max(0, frameCount), rate: rate) }
    }

    private let sample = Mutex<Sample>(Sample())
    nonisolated(unsafe) private var cached = Sample()
    public var freewheelSeconds: Double = 2
    /// Every decoded frame, on the source's thread (cue triggers; the engine dispatches onward).
    nonisolated(unsafe) public var onFrame: ((Timecode, Double) -> Void)?
    public let framesSeen = Atomic<Int>(0)

    public init() {}

    /// Source thread: one decoded frame at the host time its last bit ended; `everyFrames` is the update interval
    /// the source promises, which sets the lock window.
    public func update(_ timecode: Timecode, at hostTime: Double, source: String, everyFrames: Int = 1) {
        sample.withLock { s in
            s.frameCount = timecode.frameCount
            s.rate = timecode.rate
            s.hostTime = hostTime
            s.state = .locked
            s.source = source
            s.updateFrames = everyFrames
        }
        framesSeen.wrappingAdd(1, ordering: .relaxed)
        onFrame?(timecode, hostTime)
    }

    public func stop() { sample.withLock { $0 = Sample() } }

    /// Compositor thread: the last sample without ever blocking (a contended lock returns the previous read).
    public func read(at now: Double) -> Sample {
        if let latest = sample.withLockIfAvailable({ $0 }) { cached = latest }
        return Self.extrapolate(cached, at: now, freewheel: freewheelSeconds)
    }

    public func current(at now: Double = CACurrentMediaTime()) -> Sample {
        Self.extrapolate(sample.withLock { $0 }, at: now, freewheel: freewheelSeconds)
    }

    /// Locked within 1.5 update intervals of the last decode, freewheeling up to `freewheel` seconds, then lost.
    static func extrapolate(_ s: Sample, at now: Double, freewheel: Double) -> Sample {
        guard s.state != .off else { return s }
        var out = s
        let age = now - s.hostTime
        let interval = Double(s.updateFrames) / s.rate.exactFrameRate
        if age > freewheel {
            out.state = .lost
            out.frameCount = s.frameCount + Int((freewheel * s.rate.exactFrameRate).rounded(.down))
        } else {
            out.state = age > interval * 1.5 ? .freewheel : .locked
            out.frameCount = s.frameCount + Int((max(0, age) * s.rate.exactFrameRate).rounded(.down))
        }
        return out
    }

    /// Fractional frames at `now` for chasing (sub-frame phase), nil when there is no usable timecode.
    public func frames(at now: Double) -> Double? {
        let s = read(at: now)
        guard s.state == .locked || s.state == .freewheel else { return nil }
        return Double(cached.frameCount) + max(0, now - cached.hostTime) * cached.rate.exactFrameRate
    }
}

/// LTC from a CoreAudio input device through an `AVAudioSinkNode` (real-time thread → biphase decoder).
public final class LTCInput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let clock: TimecodeClock
    private let logger: Logger
    private let channel: Int
    nonisolated(unsafe) private var decoder: LTCDecoder?
    nonisolated(unsafe) private var sampleBase: Int64 = 0
    public private(set) var deviceName = ""
    public private(set) var lastError: String?

    public init(clock: TimecodeClock, channel: Int = 0, logger: Logger) {
        self.clock = clock
        self.channel = channel
        self.logger = logger
    }

    /// Starts on the named input device (nil = the system default). Asks for the microphone permission once.
    public func start(device name: String?) async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            lastError = "microphone permission denied: allow Fanous under Privacy & Security › Microphone"
            logger.warning("LTC input: \(lastError!)")
            return false
        }
        if let name, let id = Self.inputDevice(named: name) {
            var deviceID = id
            let status = AudioUnitSetProperty(
                engine.inputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { logger.warning("LTC input: cannot select device \(name) (\(status)); using the default input") }
        }
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastError = "no audio input device"
            logger.warning("LTC input: \(lastError!)")
            return false
        }
        deviceName = name ?? "default input"
        let sampleRate = format.sampleRate
        let channel = min(self.channel, Int(format.channelCount) - 1)
        decoder = LTCDecoder(sampleRate: sampleRate, nominalFrameRate: 25)
        let clock = self.clock
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
        let sink = AVAudioSinkNode { [self] timestamp, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
            guard channel < buffers.count, let data = buffers[channel].mData else { return noErr }
            let samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frameCount)))
            let bufferStart = sampleBase
            sampleBase += Int64(frameCount)
            let bufferHostTime = Double(timestamp.pointee.mHostTime) * secondsPerTick
            guard var decoder = self.decoder else { return noErr }
            let frames = decoder.process(samples)
            self.decoder = decoder
            for frame in frames {
                // sub-frame phase: the host time at which the frame's last bit ended
                let offset = Double(frame.endSampleIndex - bufferStart) / sampleRate
                clock.update(frame.timecode, at: bufferHostTime + offset, source: "LTC")
            }
            return noErr
        }
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: format)
        do {
            try engine.start()
        } catch {
            lastError = "audio engine: \(error)"
            logger.error("LTC input failed", metadata: ["error": "\(error)"])
            return false
        }
        logger.info("LTC input running", metadata: ["device": "\(deviceName)", "rate": "\(sampleRate)", "channel": "\(channel)"])
        return true
    }

    public func stop() {
        engine.stop()
        clock.stop()
    }

    /// Input devices by name (CoreAudio), for the machine setting and the UI.
    public static func inputDevices() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in hasInput(id) ? name(of: id) : nil }
    }

    static func inputDevice(named name: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { hasInput($0) && self.name(of: $0) == name }
    }

    static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        return status == noErr ? name as String? : nil
    }

    static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }
}

/// MTC from CoreMIDI (quarter frames and full-frame SysEx) on every source, or one chosen by name, reconnecting when
/// sources come and go (B64, as `MIDIInput` does). Everything after the CoreMIDI callback runs on `queue`: one parse
/// state per source unique id, so two senders never mix their quarter frames.
public final class MTCInput: @unchecked Sendable {
    public struct Status: Sendable {
        public var connected: [String] = []
        /// Why there is no MTC: no matching source connected, or CoreMIDI refused the client or port.
        public var error: String?
    }

    /// One source's assembly: quarter frames, and the 64-bit SysEx UMPs (two words each) of a full frame.
    struct Parse {
        var decoder = MTCDecoder()
        var sysex: [UInt8] = []
        var pendingSysexWord: UInt32?

        /// One UMP word: type 1 = system message (F1 quarter frame), type 3 = 64-bit SysEx (two words). Returns the
        /// timecode when one is complete.
        mutating func feed(_ word: UInt32) -> Timecode? {
            if let first = pendingSysexWord {
                pendingSysexWord = nil
                return sysex(first: first, second: word)
            }
            switch word >> 28 {
            case 1:
                guard (word >> 16) & 0xFF == 0xF1, let timecode = decoder.quarterFrame(UInt8((word >> 8) & 0xFF)) else { return nil }
                // the assembled time is that of piece 0: two frames ago
                return Timecode(frameCount: timecode.frameCount + 2, rate: timecode.rate)
            case 3:
                pendingSysexWord = word
                return nil
            default:
                return nil
            }
        }

        private mutating func sysex(first: UInt32, second: UInt32) -> Timecode? {
            let status = (first >> 20) & 0xF  // 0 complete, 1 start, 2 continue, 3 end
            let count = Int((first >> 16) & 0xF)
            let bytes = [UInt8((first >> 8) & 0xFF), UInt8(first & 0xFF), UInt8(second >> 24), UInt8((second >> 16) & 0xFF), UInt8((second >> 8) & 0xFF), UInt8(second & 0xFF)]
            if status == 0 || status == 1 { sysex = [0xF0] }
            sysex.append(contentsOf: bytes.prefix(count))
            guard status == 0 || status == 3 else { return nil }
            sysex.append(0xF7)
            defer { sysex = [] }
            return MTCDecoder.fullFrame(sysex)
        }
    }

    let queue = DispatchQueue(label: "org.fanous.mtc", qos: .userInteractive)
    private let clock: TimecodeClock
    private let logger: Logger
    /// Owns the client, the port, the chosen source and the connected sources by unique id (two identical interfaces
    /// share a name).
    private var listener: MIDISourceListener!
    private var parsers: [MIDIUniqueID: Parse] = [:]
    public let status = Mutex(Status())

    public init(clock: TimecodeClock, logger: Logger) {
        self.clock = clock
        self.logger = logger
        listener = MIDISourceListener(
            label: "MTC", port: "MTC in", queue: queue, logger: logger,
            receive: { [weak self] words, uid in self?.receive(words, uid: uid) },
            changed: { [weak self] connected, gone in self?.sourcesChanged(connected, gone: gone) },
            failed: { [weak self] error in self?.status.withLock { $0.error = error } })
    }

    public static func sources() -> [String] {
        (0..<MIDIGetNumberOfSources()).compactMap { MIDISourceListener.name(of: MIDIGetSource($0)) }
    }

    /// Connects every source (or the one named), now and on every CoreMIDI setup change. The client is made on the
    /// main thread (see `MIDISourceListener`): at engine start this runs on main, a runtime `timecode.set` on the
    /// control queue.
    public func start(source: String?) {
        queue.sync {
            listener.wanted = source
            status.withLock { $0.error = Self.missing(source) }
        }
        listener.start()
    }

    static func missing(_ wanted: String?) -> String {
        wanted.map { "MTC source \($0) is not connected" } ?? "no MIDI source connected"
    }

    /// On `queue`: the sources now connected. One that went away takes its parse state with it; for the clock an
    /// unplugged source is signal loss like a stopped sender: freewheel, then lost after the freewheel time.
    func setSources(_ connected: [MIDIUniqueID: String]) { listener.setSources(connected) }

    private func sourcesChanged(_ connected: [MIDIUniqueID: String], gone: Set<MIDIUniqueID>) {
        for uid in gone { parsers[uid] = nil }
        let list = connected.values.sorted()
        let error = list.isEmpty ? Self.missing(listener.wanted) : nil
        status.withLock {
            $0.connected = list
            $0.error = error
        }
    }

    /// On `queue`: UMP words from one source, each with the host time of its packet.
    func receive(_ words: [(word: UInt32, hostTime: Double)], uid: MIDIUniqueID) {
        // still in flight from a source that has just gone, or after stop
        guard listener.names[uid] != nil else { return }
        var parse = parsers[uid] ?? Parse()
        for (word, hostTime) in words {
            guard let timecode = parse.feed(word) else { continue }
            clock.update(timecode, at: hostTime, source: "MTC", everyFrames: 2)
        }
        parsers[uid] = parse
    }

    public func stop() {
        queue.sync {
            listener.stop()
            parsers = [:]
        }
        status.withLock { $0 = Status() }
        clock.stop()
    }
}
