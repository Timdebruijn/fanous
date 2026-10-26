// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreMIDI
import Foundation
import FanousCore
import Logging
import Synchronization

/// MIDI control (DESIGN.md §15.4, B36): notes, CC (7- and 14-bit), program change and MIDI Show Control from a
/// controller fire cues and drive parameters. The map lives in the project (`project.midi`); parameter values enter
/// the resolver as the internal `midi` source, so the source policy decides per layer, as for OSC and cues.
public struct MIDISettings: Codable, Equatable, Sendable {
    /// MIDI source name to listen to; nil = every connected source.
    public var source: String? = nil
    /// MSC device id we answer (0–111); the all-call (127) is always answered.
    public var mscDevice: Int = 0
    public var map: [MIDIMapping] = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        mscDevice = try c.decodeIfPresent(Int.self, forKey: .mscDevice) ?? 0
        map = try c.decodeIfPresent([MIDIMapping].self, forKey: .map) ?? []
    }

    public static func from(project: JSONValue) -> MIDISettings {
        guard let value = project["midi"], let data = try? JSONEncoder().encode(value) else { return MIDISettings() }
        return (try? JSONDecoder().decode(MIDISettings.self, from: data)) ?? MIDISettings()
    }
}

/// One entry of `project.midi.map`. Numbers are wire values (0–127); `channel` is 1–16, 0 = any channel.
public struct MIDIMapping: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case note, cc, cc14, pc }
    /// linear: the control's value across low…high (a note: velocity while held, low on release);
    /// toggle: every press flips between low and high.
    public enum Curve: String, Codable, Sendable { case linear, toggle }

    public var id = ""
    /// MIDI source name; nil = any source.
    public var source: String? = nil
    public var channel = 0
    public var kind = Kind.note
    /// Note, controller (cc14: the MSB controller 0–31, its LSB is +32) or program; nil = any program (pc only).
    public var number: Int? = nil
    /// "cue.go", "cue.back", "cue.goto" (with `cue`; a program change without one goes to cue program + 1),
    /// "fixture:Layer 3/intensity", "master/intensity".
    public var target = "cue.go"
    public var cue: Double? = nil
    public var curve = Curve.linear
    /// Ignore a moving control until it passes the parameter's current value, so nothing jumps.
    public var pickup = false
    /// Fractions of the parameter's range at the control's minimum and maximum (high < low inverts).
    public var low = 0.0
    public var high = 1.0

    public init(id: String = "", source: String? = nil, channel: Int = 0, kind: Kind, number: Int?, target: String, cue: Double? = nil, curve: Curve = .linear, pickup: Bool = false) {
        self.id = id
        self.source = source
        self.channel = channel
        self.kind = kind
        self.number = number
        self.target = target
        self.cue = cue
        self.curve = curve
        self.pickup = pickup
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source)
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? 0
        kind = try c.decode(Kind.self, forKey: .kind)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        target = try c.decode(String.self, forKey: .target)
        cue = try c.decodeIfPresent(Double.self, forKey: .cue)
        curve = try c.decodeIfPresent(Curve.self, forKey: .curve) ?? .linear
        pickup = try c.decodeIfPresent(Bool.self, forKey: .pickup) ?? false
        low = try c.decodeIfPresent(Double.self, forKey: .low) ?? 0
        high = try c.decodeIfPresent(Double.self, forKey: .high) ?? 1
    }

    /// Same control and same target: learning it again replaces the entry instead of adding a second one.
    func sameBinding(as other: MIDIMapping) -> Bool {
        source == other.source && channel == other.channel && kind == other.kind && number == other.number && target == other.target && cue == other.cue
    }

    /// Why the entry cannot work, nil when it can.
    public var problem: String? {
        guard (0...16).contains(channel) else { return "channel is 1–16, or 0 for any" }
        switch kind {
        case .note, .cc: guard let n = number, (0...127).contains(n) else { return "number is 0–127" }
        case .cc14: guard let n = number, (0...31).contains(n) else { return "a 14-bit controller is the MSB number 0–31" }
        case .pc: if let n = number, !(0...127).contains(n) { return "program is 0–127, or none for any" }
        }
        guard let target = MIDITarget(target, cue: cue) else { return "target: cue.go, cue.back, cue.goto, fixture:<Layer n|Master|Output n>/<parameter> or master/<parameter>" }
        if case .cueGoto(nil) = target, kind != .pc { return "cue.goto needs a cue number" }
        guard low.isFinite, high.isFinite, (0...1).contains(low), (0...1).contains(high) else { return "low and high are 0–1" }
        return nil
    }
}

/// What a mapping drives.
public enum MIDITarget: Equatable, Sendable {
    case cueGo, cueBack
    case cueGoto(Double?)
    case parameter(FixtureRef, ParameterID)

    public init?(_ text: String, cue: Double?) {
        switch text {
        case "cue.go": self = .cueGo
        case "cue.back": self = .cueBack
        case "cue.goto": self = .cueGoto(cue.flatMap { $0.isFinite ? $0 : nil })
        default:
            let path = text.hasPrefix("fixture:") ? String(text.dropFirst(8)) : text
            guard let slash = path.lastIndex(of: "/"), let fixture = FixtureRef(parsing: String(path[..<slash])),
                (text.hasPrefix("fixture:") || fixture == .master),
                let spec = ChannelMap.specs(for: fixture.mode).first(where: { $0.id.key == path[path.index(after: slash)...] })
            else { return nil }
            self = .parameter(fixture, spec.id)
        }
    }
}

/// The map applied to incoming messages: pure, owned by one queue. `current` reads the value the resolver shows
/// (for pickup); nil when the fixture is not patched.
public struct MIDIMapper: Sendable {
    public enum Action: Equatable, Sendable {
        case set(FixtureRef, ParameterID, UInt16)
        case cueGo, cueBack
        case cueGoto(Double)
    }

    private struct Pickup { var caught = false, lastIn: Int?, lastSent: Int? }

    public private(set) var settings = MIDISettings()
    private var targets: [MIDITarget?] = []
    /// Last MSB per channel × controller 0–31, and the pairs whose LSB has been seen (then the LSB carries the value).
    private var msb: [Int: UInt8] = [:]
    private var paired: Set<Int> = []
    private var held: [String: Bool] = [:]
    private var toggled: [String: Bool] = [:]
    private var pickups: [String: Pickup] = [:]

    public init(settings: MIDISettings = MIDISettings()) { update(settings) }

    /// New map; the per-control state (toggles, pickup, 14-bit pairs) is kept for entries that stay.
    public mutating func update(_ settings: MIDISettings) {
        self.settings = settings
        targets = settings.map.map { $0.problem == nil ? MIDITarget($0.target, cue: $0.cue) : nil }
    }

    public mutating func handle(_ message: MIDIMessage, from source: String, current: (FixtureRef, ParameterID) -> UInt16?) -> [Action] {
        let channel: UInt8
        switch message {
        case .showControl(let msc):
            guard msc.isAddressed(to: UInt8(clamping: settings.mscDevice)), msc.knownCommand == .go else { return [] }
            return [msc.cueNumber.map { .cueGoto($0) } ?? .cueGo]
        case .noteOn(let c, _, _), .noteOff(let c, _, _), .controlChange(let c, _, _), .programChange(let c, _):
            channel = c
        }
        // a 14-bit value this message completes: on the LSB once the pair is known, on the MSB before that
        var fourteen: (controller: Int, value: Int)?
        if case .controlChange(_, let cc, let v) = message, cc < 64 {
            let key = Int(channel) * 32 + Int(cc % 32)
            if cc < 32 {
                msb[key] = v
                if !paired.contains(key) { fourteen = (Int(cc), Int(v) << 7) }
            } else {
                paired.insert(key)
                fourteen = (Int(cc) - 32, Int(msb[key] ?? 0) << 7 | Int(v))
            }
        }
        var actions: [Action] = []
        for (m, target) in zip(settings.map, targets) {
            guard let target, m.source == nil || m.source == source, m.channel == 0 || m.channel == Int(channel) + 1 else { continue }
            // the control's position 0…1, and whether this message is a press (note on, a controller crossing half way up, a program change)
            var fraction = 0.0
            var press = false
            var program: UInt8?
            switch (m.kind, message) {
            case (.note, .noteOn(_, let n, let v)) where Int(n) == m.number:
                fraction = Double(v) / 127
                press = true
            case (.note, .noteOff(_, let n, _)) where Int(n) == m.number:
                fraction = 0
            case (.cc, .controlChange(_, let n, let v)) where Int(n) == m.number:
                fraction = Double(v) / 127
                press = edge(m.id, up: v >= 64)
            case (.cc14, .controlChange) where fourteen != nil && fourteen?.controller == m.number:
                fraction = Double(fourteen!.value) / 16383
                press = edge(m.id, up: fraction >= 0.5)
            case (.pc, .programChange(_, let p)) where m.number == nil || Int(p) == m.number:
                fraction = Double(p) / 127
                press = true
                program = p
            default:
                continue
            }
            switch target {
            case .cueGo: if press { actions.append(.cueGo) }
            case .cueBack: if press { actions.append(.cueBack) }
            case .cueGoto(let cue):
                if press, let number = cue ?? program.map({ Double($0) + 1 }) { actions.append(.cueGoto(number)) }
            case .parameter(let fixture, let parameter):
                if m.curve == .toggle {
                    guard press else { continue }
                    let on = !(toggled[m.id] ?? false)
                    toggled[m.id] = on
                    fraction = on ? 1 : 0
                }
                let max = Int(ChannelMap.spec(parameter).rawMax)
                let raw = Swift.min(max, Swift.max(0, Int(((m.low + fraction * (m.high - m.low)) * Double(max)).rounded())))
                if m.pickup, m.curve == .linear, let now = current(fixture, parameter), !caught(m.id, raw: raw, current: Int(now), step: Swift.max(1, max / 127)) {
                    continue
                }
                actions.append(.set(fixture, parameter, UInt16(raw)))
            }
        }
        return actions
    }

    /// A controller as a button: true once when it rises past half way.
    private mutating func edge(_ id: String, up: Bool) -> Bool {
        defer { held[id] = up }
        return up && !(held[id] ?? false)
    }

    /// Pickup: the control takes over once it is within one 7-bit step of the shown value or moves across it, and
    /// lets go again when something else (console, cue, UI) changes the value.
    private mutating func caught(_ id: String, raw: Int, current: Int, step: Int) -> Bool {
        var p = pickups[id] ?? Pickup()
        if p.lastSent != current { p.caught = false }
        if !p.caught, abs(raw - current) <= step || p.lastIn.map({ ($0 - current).signum() != (raw - current).signum() }) == true { p.caught = true }
        p.lastIn = raw
        if p.caught { p.lastSent = raw }
        pickups[id] = p
        return p.caught
    }
}

/// Learn mode: the control a message identifies. A controller 0–31 waits one message to see whether its LSB
/// (controller + 32) follows, which makes it a 14-bit pair.
public struct MIDILearner: Sendable {
    private var pending: (source: String, channel: UInt8, controller: UInt8)?

    public init() {}

    public mutating func feed(_ message: MIDIMessage, from source: String) -> MIDIMapping? {
        if let p = pending {
            pending = nil
            if case .controlChange(p.channel, p.controller + 32, _) = message, source == p.source {
                return MIDIMapping(source: source, channel: Int(p.channel) + 1, kind: .cc14, number: Int(p.controller), target: "")
            }
            return MIDIMapping(source: p.source, channel: Int(p.channel) + 1, kind: .cc, number: Int(p.controller), target: "")
        }
        switch message {
        case .noteOn(let c, let n, _): return MIDIMapping(source: source, channel: Int(c) + 1, kind: .note, number: Int(n), target: "")
        case .controlChange(let c, let n, _) where n < 32:
            pending = (source, c, n)
            return nil
        case .controlChange(let c, let n, _): return MIDIMapping(source: source, channel: Int(c) + 1, kind: .cc, number: Int(n), target: "")
        case .programChange(let c, let p): return MIDIMapping(source: source, channel: Int(c) + 1, kind: .pc, number: Int(p), target: "")
        default: return nil  // note off, MSC
        }
    }
}

// MARK: Commands

public enum MIDICommands {
    public struct Hooks: Sendable {
        /// Arm learn for a target (nil = cancel).
        public var learn: @Sendable (_ target: String?, _ cue: Double?) -> Void
        public init(learn: @escaping @Sendable (String?, Double?) -> Void) { self.learn = learn }
    }

    static func settings(_ project: JSONValue) throws -> JSONValue { try project["midi"] ?? JSONValue(encoding: MIDISettings()) }

    public static func register(on store: StateStore, hooks: Hooks) {
        store.register(
            CommandSpec(
                name: "midi.set", role: .programmer, summary: "MIDI input: source (a MIDI source name, null = all) and mscDevice (0–111; 127 all-call is always answered).",
                argsType: "{ source?: string | null; mscDevice?: number }"
            ) { project, args in
                var midi = try settings(project)
                if let source = args["source"] { try midi.set(source.string.map { .string($0) } ?? .null, at: "/source") }
                if let device = args["mscDevice"] {
                    guard let n = device.int, (0...111).contains(n) else { throw CommandError.invalidArgs("mscDevice is 0–111") }
                    try midi.set(.number(Double(n)), at: "/mscDevice")
                }
                try project.set(midi, at: "/midi")
                return nil
            })
        store.register(
            CommandSpec(
                name: "midi.map.set", role: .programmer,
                summary: "Add or replace (by id, or same control and target) a MIDI map entry; returns its id.",
                argsType:
                    "{ id?: string; source?: string | null; channel: number; kind: 'note' | 'cc' | 'cc14' | 'pc'; number?: number | null; target: string; cue?: number | null; curve?: 'linear' | 'toggle'; pickup?: boolean; low?: number; high?: number }"
            ) { project, args in
                guard let data = try? JSONEncoder().encode(args), var mapping = try? JSONDecoder().decode(MIDIMapping.self, from: data) else {
                    throw CommandError.invalidArgs("a map entry needs kind and target")
                }
                if let problem = mapping.problem { throw CommandError.invalidArgs(problem) }
                var midi = MIDISettings.from(project: project)
                if let i = midi.map.firstIndex(where: { (!mapping.id.isEmpty && $0.id == mapping.id) || (mapping.id.isEmpty && $0.sameBinding(as: mapping)) }) {
                    mapping.id = midi.map[i].id
                    midi.map[i] = mapping
                } else {
                    guard mapping.id.isEmpty else { throw CommandError.invalidArgs("no map entry \(mapping.id)") }
                    mapping.id = UUID().uuidString
                    midi.map.append(mapping)
                }
                var stored = try settings(project)
                try stored.set(try JSONValue(encoding: midi.map), at: "/map")
                try project.set(stored, at: "/midi")
                return .string(mapping.id)
            })
        store.register(CommandSpec(name: "midi.map.remove", role: .programmer, summary: "Remove a MIDI map entry by id.", argsType: "{ id: string }") { project, args in
            guard let id = args["id"]?.string else { throw CommandError.invalidArgs("args: { id }") }
            var midi = MIDISettings.from(project: project)
            guard midi.map.contains(where: { $0.id == id }) else { throw CommandError.invalidArgs("no map entry \(id)") }
            midi.map.removeAll { $0.id == id }
            var stored = try settings(project)
            try stored.set(try JSONValue(encoding: midi.map), at: "/map")
            try project.set(stored, at: "/midi")
            return nil
        })
        store.register(
            CommandSpec(
                name: "midi.learn", role: .programmer, undoable: false,
                summary: "Learn: the next note, controller or program change received is mapped to target (live.midi.learning until then); no target cancels.",
                argsType: "{ target?: string; cue?: number }"
            ) { _, args in
                guard let target = args["target"]?.string else {
                    hooks.learn(nil, nil)
                    return nil
                }
                guard let parsed = MIDITarget(target, cue: args["cue"]?.double) else { throw CommandError.invalidArgs("unknown target \(target)") }
                if case .cueGoto(nil) = parsed { throw CommandError.invalidArgs("cue.goto needs a cue number") }
                hooks.learn(target, args["cue"]?.double)
                return nil
            })
    }
}

// MARK: CoreMIDI input

/// Listens on every MIDI source (or the one chosen in `project.midi.source`), reconnecting when devices come and go.
/// Everything after the CoreMIDI callback runs on `queue`: parsing (one running status per source), learn, the map.
public final class MIDIInput: @unchecked Sendable {
    public struct Status: Sendable {
        public var connected: [String] = []
        public var last: String?
        public var lastAt: Double?
        public var learning: (target: String, cue: Double?)?
        public var learned: String?
        public var error: String?
    }

    let queue = DispatchQueue(label: "org.fanous.midi", qos: .userInteractive)
    private let dmx: DMXStore
    private let logger: Logger
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var names: [MIDIUniqueID: String] = [:]
    private var parsers: [String: MIDIParser] = [:]
    private var mapper = MIDIMapper()
    private var learner = MIDILearner()
    public let status = Mutex(Status())
    /// Cue actions of the map and MSC, on `queue`.
    public var onCue: (@Sendable (MIDIMapper.Action) -> Void)?
    /// Stores a learned entry (`midi.map.set`); returns the refusal, nil when stored.
    public var onLearn: (@Sendable (MIDIMapping) -> String?)?

    public init(dmx: DMXStore, logger: Logger) {
        self.dmx = dmx
        self.logger = logger
    }

    public func apply(_ settings: MIDISettings) {
        queue.async { [self] in
            let reconnect = settings.source != mapper.settings.source
            mapper.update(settings)
            if reconnect, client != 0 { connect() }
        }
    }

    public func learn(target: String?, cue: Double?) {
        queue.async { [self] in
            learner = MIDILearner()
            status.withLock {
                $0.learning = target.map { ($0, cue) }
                $0.learned = nil
            }
        }
    }

    public func start() {
        let created = MIDIClientCreateWithBlock("Fanous MIDI" as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged, let self else { return }
            self.queue.async { self.connect() }
        }
        guard created == noErr else {
            status.withLock { $0.error = "cannot create the MIDI client (\(created))" }
            logger.error("MIDI input: cannot create the MIDI client", metadata: ["status": "\(created)"])
            return
        }
        let made = MIDIInputPortCreateWithProtocol(client, "Control in" as CFString, ._1_0, &port) { [weak self] eventList, refCon in
            guard let self else { return }
            let uid = MIDIUniqueID(bitPattern: UInt32(truncatingIfNeeded: Int(bitPattern: refCon)))
            var words: [UInt32] = []
            for packet in eventList.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                withUnsafeBytes(of: packet.pointee.words) { raw in words += raw.bindMemory(to: UInt32.self).prefix(count) }
            }
            let bytes = MIDIParser.bytes(ump: words)
            self.queue.async { self.receive(bytes, from: self.names[uid] ?? "MIDI") }
        }
        guard made == noErr else {
            status.withLock { $0.error = "cannot create the MIDI input port (\(made))" }
            logger.error("MIDI input: cannot create the input port", metadata: ["status": "\(made)"])
            return
        }
        queue.async { [self] in connect() }
    }

    /// On `queue`: every source matching the setting; the source's unique id rides along as the connection refCon.
    private func connect() {
        var connected: [String] = []
        names = [:]
        for i in 0..<MIDIGetNumberOfSources() {
            let ref = MIDIGetSource(i)
            MIDIPortDisconnectSource(port, ref)
            let name = MTCInput.name(of: ref) ?? "source \(i)"
            if let wanted = mapper.settings.source, wanted != name { continue }
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &uid)
            names[uid] = name
            // bit 32 keeps the refCon non-null for a unique id of 0
            let refCon = UnsafeMutableRawPointer(bitPattern: Int(UInt32(bitPattern: uid)) | 1 << 32)
            if MIDIPortConnectSource(port, ref, refCon) == noErr { connected.append(name) }
        }
        status.withLock {
            $0.connected = connected
            $0.error = nil
        }
        logger.info("MIDI input listening", metadata: ["sources": "\(connected)"])
    }

    /// Tests: bytes as if a source sent them, handled before this returns.
    func inject(_ bytes: [UInt8], from source: String) { queue.sync { receive(bytes, from: source) } }

    /// On `queue`.
    private func receive(_ bytes: [UInt8], from source: String) {
        var parser = parsers[source] ?? MIDIParser()
        let messages = parser.feed(bytes)
        parsers[source] = parser
        for message in messages { handle(message, from: source) }
    }

    private func handle(_ message: MIDIMessage, from source: String) {
        status.withLock {
            $0.last = "\(source) · \(message)"
            $0.lastAt = Date().timeIntervalSince1970
        }
        if let learning = status.withLock({ $0.learning }), var mapping = learner.feed(message, from: source) {
            mapping.target = learning.target
            mapping.cue = learning.cue
            if case .parameter = MIDITarget(learning.target, cue: nil), mapping.kind == .note { mapping.curve = .toggle }
            let refusal = onLearn?(mapping)
            status.withLock {
                $0.learning = nil
                $0.learned = refusal.map { "not stored: \($0)" } ?? "\(Self.control(mapping)) → \(learning.target)\(learning.cue.map { " \($0)" } ?? "")"
            }
        }
        let dmx = dmx
        let actions = mapper.handle(message, from: source) { dmx.resolvedRaw($0, $1) }
        for action in actions {
            if case .set(let fixture, let parameter, let raw) = action {
                dmx.setMIDI(fixture, parameter, raw: raw)
            } else {
                onCue?(action)
            }
        }
    }

    static func control(_ m: MIDIMapping) -> String {
        let what: String
        switch m.kind {
        case .note: what = "note \(m.number ?? 0)"
        case .cc: what = "CC \(m.number ?? 0)"
        case .cc14: what = "CC \(m.number ?? 0)/\((m.number ?? 0) + 32)"
        case .pc: what = m.number.map { "program \($0)" } ?? "any program"
        }
        return "ch \(m.channel == 0 ? "any" : String(m.channel)) · \(what)"
    }

    public func stop() {
        queue.sync {
            if port != 0 { MIDIPortDispose(port) }
            if client != 0 { MIDIClientDispose(client) }
            port = 0
            client = 0
        }
    }
}
