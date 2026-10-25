// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging

/// The project's cue list and timecode settings as the UI sees them, plus the show-control commands
/// (DESIGN.md §14–15). Cues are stored UI-friendly (fixture and parameter by name) and converted to
/// `FanousCore.Cue` for the engine.
public enum ShowCommands {
    public struct TimecodeSettings: Codable, Equatable, Sendable {
        public enum Source: String, Codable, Sendable { case off, ltc, mtc }
        public var source: Source = .off
        /// Audio input device name (LTC) or MIDI source name (MTC); nil = default / all.
        public var device: String? = nil
        public var channel: Int = 0
        /// Frames of the incoming rate.
        public var offset: Double = 0
        public var freewheel: Double = 2
        /// Per-layer chase offsets in frames, keyed by the layer number as a string.
        public var layerOffsets: [String: Double] = [:]
        /// The operator's switch (`timecode.enable`, allowed under show lock); nil = on. The source stays configured.
        public var enabled: Bool? = nil
        public init() {}
    }

    // MARK: Cues ⇄ JSON

    /// `{"fixture":"Layer 3","parameter":"intensity","raw":65535,"fade":2}`
    static func cueValue(from value: JSONValue) -> CueValue? {
        guard let fixture = value["fixture"]?.string.flatMap(FixtureRef.init(parsing:)), let key = value["parameter"]?.string,
            let spec = ChannelMap.specs(for: fixture.mode).first(where: { $0.id.key == key }), let raw = value["raw"]?.int
        else { return nil }
        return CueValue(fixture: fixture, parameter: spec.id, raw: UInt16(clamping: raw), fadeTime: value["fade"]?.double)
    }

    static func cue(from value: JSONValue) -> Cue? {
        guard let number = value["number"]?.double, let name = value["name"]?.string else { return nil }
        let values = (value["values"]?.array ?? []).compactMap(cueValue(from:))
        let trigger = value["trigger"]?.string.flatMap(parseTimecode)
        return Cue(
            id: value["id"]?.string.flatMap(UUID.init(uuidString:)) ?? UUID(), number: number, name: name, fadeTime: value["fade"]?.double ?? 0,
            values: values, timecodeTrigger: trigger, followTime: value["follow"]?.double)
    }

    public static func cueList(from project: JSONValue) -> CueList {
        CueList(cues: (project["cues"]?.array ?? []).compactMap(cue(from:)))
    }

    /// "hh:mm:ss:ff@25", "@29.97df", "@30", "@24"
    static func parseTimecode(_ text: String) -> Timecode? {
        let parts = text.split(separator: "@")
        guard let time = parts.first else { return nil }
        let rate = parts.count > 1 ? TimecodeRate(rawValue: String(parts[1])) ?? TimecodeRate.allCases.first { $0.label == String(parts[1]) } : .fps25
        let fields = time.split(separator: ":").map { Int($0) }
        guard fields.count == 4, let h = fields[0], let m = fields[1], let s = fields[2], let f = fields[3], let rate else { return nil }
        return Timecode(hours: h, minutes: m, seconds: s, frames: f, rate: rate)
    }

    /// The stored shape the UI relies on: every key present, `values` an array, `trigger`/`follow` null when unset.
    static func normalizedCue(_ value: JSONValue, id: String) -> JSONValue {
        [
            "id": .string(id), "number": value["number"] ?? 0, "name": value["name"] ?? "", "fade": value["fade"] ?? 0,
            "values": .array((value["values"]?.array ?? []).map { ["fixture": $0["fixture"] ?? "", "parameter": $0["parameter"] ?? "", "raw": $0["raw"] ?? 0, "fade": $0["fade"] ?? .null] }),
            "trigger": value["trigger"] ?? .null, "follow": value["follow"] ?? .null,
        ]
    }

    static func validateCue(_ value: JSONValue) throws {
        guard cue(from: value) != nil else { throw CommandError.invalidArgs("a cue needs number, name and valid values ({fixture, parameter, raw, fade?})") }
        if let values = value["values"]?.array, values.count != values.compactMap(cueValue(from:)).count {
            throw CommandError.invalidArgs("every value needs fixture (\"Layer n\" / \"Master\" / \"Output n\"), a parameter key and raw")
        }
    }

    public static func timecodeSettings(from project: JSONValue) -> TimecodeSettings {
        guard let value = project["timecode"], let data = try? JSONEncoder().encode(value) else { return TimecodeSettings() }
        return (try? JSONDecoder().decode(TimecodeSettings.self, from: data)) ?? TimecodeSettings()
    }

    // MARK: Commands

    public struct Hooks: Sendable {
        public var go: @Sendable () -> Void
        public var back: @Sendable () -> Void
        public var goto: @Sendable (Double) -> Void
        /// Enter (true) or leave show mode; returns the ids of the readiness items that block, or nil when it happened.
        public var showMode: @Sendable (Bool) -> [String]?
        public var acknowledge: @Sendable (String) -> Void
        public var runReadiness: @Sendable () -> Void
        public init(
            go: @escaping @Sendable () -> Void, back: @escaping @Sendable () -> Void, goto: @escaping @Sendable (Double) -> Void,
            showMode: @escaping @Sendable (Bool) -> [String]?, acknowledge: @escaping @Sendable (String) -> Void, runReadiness: @escaping @Sendable () -> Void
        ) {
            self.go = go
            self.back = back
            self.goto = goto
            self.showMode = showMode
            self.acknowledge = acknowledge
            self.runReadiness = runReadiness
        }
    }

    public static func register(on store: StateStore, hooks: Hooks) {
        store.register(CommandSpec(name: "cue.go", role: .operator, mutatesConfig: false, undoable: false, summary: "Fire the next cue.") { _, _ in
            hooks.go()
            return nil
        })
        store.register(CommandSpec(name: "cue.back", role: .operator, mutatesConfig: false, undoable: false, summary: "Fire the previous cue.") { _, _ in
            hooks.back()
            return nil
        })
        store.register(CommandSpec(name: "cue.goto", role: .operator, mutatesConfig: false, undoable: false, summary: "Fire the cue with this number.", argsType: "{ number: number }") { _, args in
            guard let number = args["number"]?.double else { throw CommandError.invalidArgs("args: { number }") }
            hooks.goto(number)
            return nil
        })
        store.register(
            CommandSpec(
                name: "cue.add", role: .programmer, summary: "Add a cue: { number, name, fade?, values?: [{fixture, parameter, raw, fade?}], trigger?: \"hh:mm:ss:ff@rate\", follow? }.",
                argsType: "{ number: number; name: string; fade?: number; values?: { fixture: string; parameter: string; raw: number; fade?: number }[]; trigger?: string | null; follow?: number | null }"
            ) { project, args in
                let id = UUID().uuidString
                let cue = normalizedCue(args, id: id)
                try validateCue(cue)
                var cues = project["cues"]?.array ?? []
                if cues.contains(where: { $0["number"]?.double == args["number"]?.double }) { throw CommandError.invalidArgs("cue number exists") }
                cues.append(cue)
                cues.sort { ($0["number"]?.double ?? 0) < ($1["number"]?.double ?? 0) }
                try project.set(.array(cues), at: "/cues")
                return .string(id)
            })
        store.register(
            CommandSpec(name: "cue.set", role: .programmer, summary: "Replace one cue by id (whole object, validated).", argsType: "{ id: string; cue: JSONValue }") { project, args in
                guard let id = args["id"]?.string, let given = args["cue"] else { throw CommandError.invalidArgs("args: { id, cue }") }
                let cue = normalizedCue(given, id: id)
                try validateCue(cue)
                var cues = project["cues"]?.array ?? []
                guard let index = cues.firstIndex(where: { $0["id"]?.string == id }) else { throw CommandError.invalidArgs("no cue \(id)") }
                if cues.contains(where: { $0["id"]?.string != id && $0["number"]?.double == cue["number"]?.double }) { throw CommandError.invalidArgs("cue number exists") }
                cues[index] = cue
                cues.sort { ($0["number"]?.double ?? 0) < ($1["number"]?.double ?? 0) }
                try project.set(.array(cues), at: "/cues")
                return nil
            })
        store.register(CommandSpec(name: "cue.remove", role: .programmer, summary: "Remove a cue by id.", argsType: "{ id: string }") { project, args in
            guard let id = args["id"]?.string else { throw CommandError.invalidArgs("args: { id }") }
            var cues = project["cues"]?.array ?? []
            guard cues.contains(where: { $0["id"]?.string == id }) else { throw CommandError.invalidArgs("no cue \(id)") }
            cues.removeAll { $0["id"]?.string == id }
            try project.set(.array(cues), at: "/cues")
            return nil
        })
        store.register(
            CommandSpec(
                name: "timecode.set", role: .programmer, summary: "Timecode settings: source (off|ltc|mtc), device, channel, offset (frames), freewheel (s), layerOffsets.",
                argsType: "{ path: string; value: JSONValue }"
            ) { project, args in
                guard let path = args["path"]?.string, let pointer = try? JSONPointer(path), let value = args["value"] else { throw CommandError.invalidArgs("args: { path, value }") }
                var settings = try project["timecode"] ?? JSONValue(encoding: TimecodeSettings())
                try settings.set(value, at: pointer)
                guard let data = try? JSONEncoder().encode(settings), let decoded = try? JSONDecoder().decode(TimecodeSettings.self, from: data) else {
                    throw CommandError.invalidArgs("\(path) does not fit the timecode settings")
                }
                try project.set(try JSONValue(encoding: decoded), at: "/timecode")
                return nil
            })
        store.register(
            CommandSpec(name: "timecode.enable", role: .operator, mutatesConfig: false, undoable: false, summary: "Operator switch: chase the configured timecode source (true) or ignore it (false).", argsType: "{ on: boolean }") { project, args in
                guard let on = args["on"]?.bool else { throw CommandError.invalidArgs("args: { on }") }
                var settings = try project["timecode"] ?? JSONValue(encoding: TimecodeSettings())
                try settings.set(.bool(on), at: "/enabled")
                try project.set(settings, at: "/timecode")
                return nil
            })
        store.register(
            CommandSpec(name: "show.mode", role: .operator, mutatesConfig: false, undoable: false, summary: "Enter (true) or leave show mode; refused with the blocking readiness items.", argsType: "{ on: boolean }") { _, args in
                guard let on = args["on"]?.bool else { throw CommandError.invalidArgs("args: { on }") }
                if let blocking = hooks.showMode(on) { throw CommandError("notReady", "readiness: \(blocking.joined(separator: ", "))") }
                return nil
            })
        store.register(CommandSpec(name: "readiness.run", role: .operator, mutatesConfig: false, undoable: false, summary: "Run the readiness checks now.") { _, _ in
            hooks.runReadiness()
            return nil
        })
        store.register(CommandSpec(name: "readiness.acknowledge", role: .programmer, mutatesConfig: false, undoable: false, summary: "Acknowledge a failed readiness item so show mode can be entered.", argsType: "{ id: string }") { _, args in
            guard let id = args["id"]?.string else { throw CommandError.invalidArgs("args: { id }") }
            hooks.acknowledge(id)
            return nil
        })
    }
}
