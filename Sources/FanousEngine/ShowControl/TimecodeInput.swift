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

        public var timecode: Timecode { Timecode(frameCount: max(0, frameCount), rate: rate) }
    }

    private let sample = Mutex<Sample>(Sample())
    nonisolated(unsafe) private var cached = Sample()
    public var freewheelSeconds: Double = 2
    /// Every decoded frame, on the source's thread (cue triggers; the engine dispatches onward).
    nonisolated(unsafe) public var onFrame: ((Timecode, Double) -> Void)?
    public let framesSeen = Atomic<Int>(0)

    public init() {}

    /// Source thread: one decoded frame at the host time its last bit ended.
    public func update(_ timecode: Timecode, at hostTime: Double, source: String) {
        sample.withLock { s in
            s.frameCount = timecode.frameCount
            s.rate = timecode.rate
            s.hostTime = hostTime
            s.state = .locked
            s.source = source
        }
        framesSeen.wrappingAdd(1, ordering: .relaxed)
        onFrame?(timecode, hostTime)
    }

    public func stop() { sample.withLock { $0 = Sample() } }

    /// The source went away (unplugged): lost at once, at the last decoded frame, until a source sends frames again.
    public func lose() { sample.withLock { if $0.state != .off { $0.state = .lost } } }

    /// Compositor thread: the last sample without ever blocking (a contended lock returns the previous read).
    public func read(at now: Double) -> Sample {
        if let latest = sample.withLockIfAvailable({ $0 }) { cached = latest }
        return Self.extrapolate(cached, at: now, freewheel: freewheelSeconds)
    }

    public func current(at now: Double = CACurrentMediaTime()) -> Sample {
        Self.extrapolate(sample.withLock { $0 }, at: now, freewheel: freewheelSeconds)
    }

    /// Locked within one frame of the last decode, freewheeling up to `freewheel` seconds, then lost.
    static func extrapolate(_ s: Sample, at now: Double, freewheel: Double) -> Sample {
        guard s.state != .off, s.state != .lost else { return s }
        var out = s
        let age = now - s.hostTime
        let frameDuration = 1 / s.rate.exactFrameRate
        if age > freewheel {
            out.state = .lost
            out.frameCount = s.frameCount + Int((freewheel * s.rate.exactFrameRate).rounded(.down))
        } else {
            out.state = age > frameDuration * 1.5 ? .freewheel : .locked
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
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    /// The source name chosen in the settings; nil = every source.
    private var wanted: String?
    private var stopped = false
    /// Connected sources by CoreMIDI unique id: two identical interfaces share a name, not an id.
    private var names: [MIDIUniqueID: String] = [:]
    private var parsers: [MIDIUniqueID: Parse] = [:]
    /// The source whose frame the clock holds: when it goes away the clock is lost.
    private var feeding: MIDIUniqueID?
    public let status = Mutex(Status())

    public init(clock: TimecodeClock, logger: Logger) {
        self.clock = clock
        self.logger = logger
    }

    public static func sources() -> [String] {
        (0..<MIDIGetNumberOfSources()).compactMap { name(of: MIDIGetSource($0)) }
    }

    static func name(of object: MIDIObjectRef) -> String? {
        var name: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    /// Connects every source (or the one named), now and on every CoreMIDI setup change. Setup notifications come on
    /// the run loop that was current at the process's first CoreMIDI call (see `MIDIInput.start`), so the client is
    /// made on the main thread here too: at engine start this runs on main, a runtime `timecode.set` on the control queue.
    public func start(source: String?) {
        queue.sync {
            wanted = source
            status.withLock { $0.error = Self.missing(source) }
        }
        if Thread.isMainThread { open() } else { DispatchQueue.main.async { [self] in open() } }
    }

    static func missing(_ wanted: String?) -> String {
        wanted.map { "MTC source \($0) is not connected" } ?? "no MIDI source connected"
    }

    /// On the main thread.
    private func open() {
        guard !queue.sync(execute: { stopped }) else { return }
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
        var client = MIDIClientRef()
        var port = MIDIPortRef()
        let created = MIDIClientCreateWithBlock("Fanous MTC" as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged, let self else { return }
            self.queue.async { self.connect() }
        }
        guard created == noErr else { return fail("cannot create the MIDI client (\(created))") }
        let made = MIDIInputPortCreateWithProtocol(client, "MTC in" as CFString, ._1_0, &port) { [weak self] eventList, refCon in
            guard let self else { return }
            let uid = MIDIUniqueID(bitPattern: UInt32(truncatingIfNeeded: Int(bitPattern: refCon)))
            var words: [(word: UInt32, hostTime: Double)] = []
            for packet in eventList.unsafeSequence() {
                // the host time travels with the word, so the hop to the queue costs no chase accuracy
                let stamp = packet.pointee.timeStamp
                let hostTime = stamp == 0 ? CACurrentMediaTime() : Double(stamp) * secondsPerTick
                let count = Int(packet.pointee.wordCount)
                withUnsafeBytes(of: packet.pointee.words) { raw in
                    for word in raw.bindMemory(to: UInt32.self).prefix(count) { words.append((word, hostTime)) }
                }
            }
            self.queue.async { self.receive(words, uid: uid) }
        }
        guard made == noErr else {
            MIDIClientDispose(client)
            return fail("cannot create the MIDI input port (\(made))")
        }
        queue.async { [self] in
            // stopped while the main thread was getting here (the settings changed again at once)
            guard !stopped else {
                MIDIPortDispose(port)
                MIDIClientDispose(client)
                return
            }
            self.client = client
            self.port = port
            connect()
        }
    }

    private func fail(_ error: String) {
        status.withLock { $0.error = error }
        logger.error("MTC input: \(error)")
    }

    /// On `queue`: every source matching the setting; the source's unique id rides along as the connection refCon.
    private func connect() {
        guard port != 0 else { return }
        var connected: [MIDIUniqueID: String] = [:]
        for i in 0..<MIDIGetNumberOfSources() {
            let ref = MIDIGetSource(i)
            MIDIPortDisconnectSource(port, ref)
            let name = Self.name(of: ref) ?? "source \(i)"
            if let wanted, wanted != name { continue }
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &uid)
            // bit 32 keeps the refCon non-null for a unique id of 0
            let refCon = UnsafeMutableRawPointer(bitPattern: Int(UInt32(bitPattern: uid)) | 1 << 32)
            if MIDIPortConnectSource(port, ref, refCon) == noErr { connected[uid] = name }
        }
        setSources(connected)
        logger.info("MTC input listening", metadata: ["sources": "\(connected.values.sorted())"])
    }

    /// On `queue`: the sources now connected. One that went away takes its parse state with it, and the clock is lost
    /// at once when it was the one feeding it: an unplugged source is not a dropout to freewheel over.
    func setSources(_ connected: [MIDIUniqueID: String]) {
        for uid in Set(names.keys).subtracting(connected.keys) {
            parsers[uid] = nil
            if feeding == uid {
                feeding = nil
                clock.lose()
            }
        }
        names = connected
        let list = connected.values.sorted()
        let error = list.isEmpty ? Self.missing(wanted) : nil
        status.withLock {
            $0.connected = list
            $0.error = error
        }
    }

    /// On `queue`: UMP words from one source, each with the host time of its packet.
    func receive(_ words: [(word: UInt32, hostTime: Double)], uid: MIDIUniqueID) {
        // still in flight from a source that has just gone, or after stop
        guard names[uid] != nil else { return }
        var parse = parsers[uid] ?? Parse()
        for (word, hostTime) in words {
            guard let timecode = parse.feed(word) else { continue }
            clock.update(timecode, at: hostTime, source: "MTC")
            feeding = uid
        }
        parsers[uid] = parse
    }

    public func stop() {
        queue.sync {
            stopped = true
            if port != 0 { MIDIPortDispose(port) }
            if client != 0 { MIDIClientDispose(client) }
            port = 0
            client = 0
            names = [:]
            parsers = [:]
            feeding = nil
        }
        status.withLock { $0 = Status() }
        clock.stop()
    }
}
