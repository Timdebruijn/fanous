// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// MIDI 1.0 input for show control (DESIGN.md §15.4, B36): the messages a controller or a show-control
/// sender produces. Channels are 0–15 on the wire; `description` shows them 1–16 as every device does.
public enum MIDIMessage: Equatable, Sendable, CustomStringConvertible {
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case programChange(channel: UInt8, program: UInt8)
    case showControl(MSCMessage)

    public var description: String {
        switch self {
        case .noteOn(let c, let n, let v): "ch \(c + 1) · note \(n) on · \(v)"
        case .noteOff(let c, let n, _): "ch \(c + 1) · note \(n) off"
        case .controlChange(let c, let n, let v): "ch \(c + 1) · CC \(n) = \(v)"
        case .programChange(let c, let p): "ch \(c + 1) · program \(p)"
        case .showControl(let msc): msc.description
        }
    }
}

/// MIDI Show Control: `F0 7F <device> 02 <format> <command> <data> F7`. Data of GO/STOP/RESUME/… is
/// `Q_number 00 Q_list 00 Q_path`, each ASCII digits and ".", all optional.
public struct MSCMessage: Equatable, Sendable, CustomStringConvertible {
    public static let allCall: UInt8 = 0x7F
    public enum Command: UInt8, Sendable {
        case go = 0x01, stop = 0x02, resume = 0x03, timedGo = 0x04, load = 0x05, set = 0x06, fire = 0x07, allOff = 0x08
        case restore = 0x09, reset = 0x0A, goOff = 0x0B
    }

    public var deviceID: UInt8
    public var format: UInt8
    public var command: UInt8
    public var cue: String?
    public var list: String?
    public var path: String?

    public init(deviceID: UInt8, format: UInt8 = 0x01, command: UInt8, cue: String? = nil, list: String? = nil, path: String? = nil) {
        self.deviceID = deviceID
        self.format = format
        self.command = command
        self.cue = cue
        self.list = list
        self.path = path
    }

    public var knownCommand: Command? { Command(rawValue: command) }
    public var cueNumber: Double? { cue.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }

    /// Our own device id or the all-call. ponytail: group ids (0x70–0x7E) are not answered; add a group setting when a desk needs it.
    public func isAddressed(to device: UInt8) -> Bool { deviceID == Self.allCall || deviceID == device }

    public var description: String {
        let name = knownCommand.map { "\($0)".uppercased() } ?? "command 0x" + String(command, radix: 16, uppercase: true)
        return "MSC \(name)\(cue.map { " \($0)" } ?? "") · device \(deviceID == Self.allCall ? "all" : "\(deviceID)")"
    }

    /// The SysEx bytes between F0 and F7; nil for anything that is not an MSC message.
    public init?(sysex body: some Collection<UInt8>) {
        let b = Array(body)
        guard b.count >= 5, b[0] == 0x7F, b[2] == 0x02 else { return nil }
        let fields = b.dropFirst(5).split(separator: 0, omittingEmptySubsequences: false).map { field -> String? in
            field.isEmpty || !field.allSatisfy({ $0 == 0x2E || (0x30...0x39).contains($0) }) ? nil : String(decoding: field, as: UTF8.self)
        }
        self.init(deviceID: b[1], format: b[3], command: b[4], cue: fields.first ?? nil, list: fields.count > 1 ? fields[1] : nil, path: fields.count > 2 ? fields[2] : nil)
    }

    public var sysex: [UInt8] {
        var out: [UInt8] = [0xF0, 0x7F, deviceID, 0x02, format, command]
        let fields = [cue, list, path]
        let used = fields.lastIndex { $0 != nil }.map { $0 + 1 } ?? 0
        for (i, field) in fields.prefix(used).enumerated() {
            if i > 0 { out.append(0) }
            out += Array((field ?? "").utf8)
        }
        return out + [0xF7]
    }
}

/// Byte-stream parser: running status, real-time bytes anywhere (ignored), system common cancels running status,
/// SysEx assembled up to `maxSysex` bytes. Note-on with velocity 0 is a note-off.
public struct MIDIParser: Sendable {
    public static let maxSysex = 256
    private var status: UInt8 = 0
    private var data: [UInt8] = []
    private var sysex: [UInt8]?

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        for b in bytes {
            switch b {
            case 0xF8...0xFF: continue  // real time: clock, start, stop, active sensing
            case 0xF0:
                sysex = []
                status = 0
            case 0xF7:
                if let body = sysex, let msc = MSCMessage(sysex: body) { out.append(.showControl(msc)) }
                sysex = nil
                status = 0
            case 0xF1...0xF6:
                sysex = nil
                status = 0  // its data bytes are dropped below
            case 0x80...0xEF:
                sysex = nil
                status = b
                data = []
            default:
                if sysex != nil {
                    if sysex!.count < Self.maxSysex { sysex!.append(b) } else { sysex = nil }
                    continue
                }
                guard status != 0 else { continue }
                data.append(b)
                let kind = status & 0xF0
                guard data.count == (kind == 0xC0 || kind == 0xD0 ? 1 : 2) else { continue }
                defer { data = [] }
                let channel = status & 0x0F
                switch kind {
                case 0x80: out.append(.noteOff(channel: channel, note: data[0], velocity: data[1]))
                case 0x90: out.append(data[1] == 0 ? .noteOff(channel: channel, note: data[0], velocity: 0) : .noteOn(channel: channel, note: data[0], velocity: data[1]))
                case 0xB0: out.append(.controlChange(channel: channel, controller: data[0], value: data[1]))
                case 0xC0: out.append(.programChange(channel: channel, program: data[0]))
                default: break  // aftertouch, pitch bend
                }
            }
        }
        return out
    }

    /// MIDI 1.0 bytes of Universal MIDI Packet words as CoreMIDI delivers them with the 1.0 protocol: message type 1
    /// (system), 2 (MIDI 1.0 channel voice) and 3 (7-bit SysEx, two words each); other types are skipped by size.
    public static func bytes(ump words: some Collection<UInt32>) -> [UInt8] {
        let w = Array(words)
        var out: [UInt8] = []
        var i = 0
        while i < w.count {
            let word = w[i]
            let type = Int(word >> 28)
            let size = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][type]
            defer { i += size }
            let status = UInt8((word >> 16) & 0xFF)
            let d1 = UInt8((word >> 8) & 0x7F)
            let d2 = UInt8(word & 0x7F)
            switch type {
            case 1:
                switch status {
                case 0xF1, 0xF3: out += [status, d1]
                case 0xF2: out += [status, d1, d2]
                default: out.append(status)
                }
            case 2:
                let kind = status & 0xF0
                out += kind == 0xC0 || kind == 0xD0 ? [status, d1] : [status, d1, d2]
            case 3 where i + 1 < w.count:
                let second = w[i + 1]
                let form = (word >> 20) & 0xF  // 0 complete, 1 start, 2 continue, 3 end
                let count = min(6, Int((word >> 16) & 0xF))
                let payload = [UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F), UInt8((second >> 24) & 0x7F), UInt8((second >> 16) & 0x7F), UInt8((second >> 8) & 0x7F), UInt8(second & 0x7F)]
                if form == 0 || form == 1 { out.append(0xF0) }
                out += payload.prefix(count)
                if form == 0 || form == 3 { out.append(0xF7) }
            default: break
            }
        }
        return out
    }
}
