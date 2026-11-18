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

        /// `layerOffsets` by layer number. `timecode.set` refuses a new key that is not the canonical spelling of a number
        /// (B262), so "01" or "+1" come only from an older build or a hand edit. Where two keys name one layer the
        /// canonical one wins, else the lowest key as a string ("001" beats "01", "+1" beats "01"); a key `Int` cannot
        /// parse is dropped. A loaded project never traps and its winner does not hang on hash order.
        public var layerOffsetsByNumber: [Int: Double] {
            var byNumber: [Int: Double] = [:]
            for (key, value) in layerOffsets.sorted(by: { $0.key < $1.key }) {
                if let number = Int(key), byNumber[number] == nil || String(number) == key { byNumber[number] = value }
            }
            return byNumber
        }
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
        let trigger = value["trigger"]?.string.flatMap { parseTimecode($0) }
        return Cue(
            id: value["id"]?.string.flatMap(UUID.init(uuidString:)) ?? UUID(), number: number, name: name, fadeTime: value["fade"]?.double ?? 0,
            values: values, timecodeTrigger: trigger, followTime: value["follow"]?.double)
    }

    public static func cueList(from project: JSONValue) -> CueList {
        CueList(cues: (project["cues"]?.array ?? []).compactMap(cue(from:)))
    }

    /// "hh:mm:ss:ff@25", 25 without "@rate"; the rate as the guide writes it ("29.97df", "29.97ndf") or the engine's label
    /// ("29.97 DF"), case and spaces ignored. `strict` (cue.add, cue.set) is the web's `parseTrigger` minus the conveniences
    /// it normalizes before sending (`;`, spaces before `@`, surrounding whitespace): one or two digits per field, at most
    /// one `@`. Not strict (loading a project) also takes what older builds stored: a sign or more digits (`Int`), empty
    /// fields, more `@`s (only the first two parts read) and the raw rate value ("fps2997df"). Field ranges are not checked
    /// here: `validateCue` refuses an out-of-range trigger (`Timecode.isValid`), while a stored project keeps its trigger armed.
    static func parseTimecode(_ text: String, strict: Bool = false) -> Timecode? {
        let parts = text.split(separator: "@", omittingEmptySubsequences: !strict)
        guard let time = parts.first, !strict || parts.count <= 2 else { return nil }
        func key(_ s: some StringProtocol) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }
        let rate = parts.count > 1 ? TimecodeRate.allCases.first { ([key($0.label)] + (strict ? [] : [$0.rawValue.lowercased()])).contains(key(parts[1])) } : .fps25
        let fields = time.split(separator: ":", omittingEmptySubsequences: !strict).map { field in
            !strict || ((1...2).contains(field.count) && field.allSatisfy { ("0"..."9").contains($0) }) ? Int(field) : nil
        }
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
            throw CommandError.invalidArgs("every value needs fixture (\"Layer n\" / \"Master\" / \"Output n\" / \"Keystone n\"), a parameter key and raw")
        }
        if let trigger = value["trigger"], trigger != .null {
            guard let text = trigger.string, let timecode = parseTimecode(text, strict: true) else {
                throw CommandError.invalidArgs("trigger is hh:mm:ss:ff@rate, the rate 24, 25, 29.97df, 29.97ndf or 30")
            }
            guard timecode.isValid else {
                throw CommandError.invalidArgs("trigger \(text) out of range: hours go to 23, minutes and seconds to 59, frames to one below the rate; 29.97df skips frames 00 and 01 of each minute except every tenth")
            }
        }
    }

    /// `cue` (normalized) in place of `cues[index]` (appended when nil), the list sorted by number into `/cues`;
    /// refused when another cue already has its number (a numberless cue.add is cue 0).
    static func storeCues(_ cues: [JSONValue], _ cue: JSONValue, at index: Int?, in project: inout JSONValue) throws {
        if cues.contains(where: { $0["id"]?.string != cue["id"]?.string && $0["number"]?.double == cue["number"]?.double }) { throw CommandError.invalidArgs("cue number exists") }
        var cues = cues
        if let index { cues[index] = cue } else { cues.append(cue) }
        cues.sort { ($0["number"]?.double ?? 0) < ($1["number"]?.double ?? 0) }
        try project.set(.array(cues), at: "/cues")
    }

    public static func timecodeSettings(from project: JSONValue) -> TimecodeSettings {
        (try? project["timecode"]?.decoded(as: TimecodeSettings.self)) ?? TimecodeSettings()
    }

    // MARK: Commands

    public struct Hooks: Sendable {
        public var go: @Sendable () -> Void
        public var back: @Sendable () -> Void
        public var goto: @Sendable (Double) -> Void
        /// Enter (true) or leave show mode; returns the ids of the readiness items that block, or nil when it happened.
        /// Entering is called off the control queue (B200).
        public var showMode: @Sendable (Bool) -> [String]?
        /// Acknowledge (true) or take back (false) a readiness item's acknowledgement.
        public var acknowledge: @Sendable (_ id: String, _ on: Bool) -> Void
        public var runReadiness: @Sendable () -> Void
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
                try storeCues(project["cues"]?.array ?? [], cue, at: nil, in: &project)
                return .string(id)
            })
        store.register(
            CommandSpec(name: "cue.set", role: .programmer, summary: "Replace one cue by id (whole object, validated).", argsType: "{ id: string; cue: JSONValue }") { project, args in
                guard let id = args["id"]?.string, let given = args["cue"] else { throw CommandError.invalidArgs("args: { id, cue }") }
                let cue = normalizedCue(given, id: id)
                try validateCue(cue)
                let cues = project["cues"]?.array ?? []
                guard let index = cues.firstIndex(where: { $0["id"]?.string == id }) else { throw CommandError.invalidArgs("no cue \(id)") }
                try storeCues(cues, cue, at: index, in: &project)
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
                guard let decoded = try? settings.decoded(as: TimecodeSettings.self) else {
                    throw CommandError.invalidArgs("\(path) does not fit the timecode settings")
                }
                // only a key this command adds: one an older build stored stays (layerOffsetsByNumber resolves it), so
                // the other settings remain editable
                let stored = timecodeSettings(from: project).layerOffsets
                if let key = decoded.layerOffsets.keys.first(where: { stored[$0] == nil && Int($0).map(String.init) != $0 }) {
                    throw CommandError.invalidArgs("layerOffsets key \"\(key)\" is not a layer number")
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
            CommandSpec(
                name: "show.mode", role: .operator, mutatesConfig: false, undoable: false, summary: "Enter (true) or leave show mode; refused with the blocking readiness items.", argsType: "{ on: boolean }",
                // B200: the entry runs here, off the control queue (its readiness checks take up to seconds); `run`
                // answers with its outcome. A `blocking` sent by the client is overwritten.
                prepare: { args in
                    guard args["on"]?.bool == true else { return args }
                    return ["on": true, "blocking": .array((hooks.showMode(true) ?? []).map { .string($0) })]
                }
            ) { _, args in
                guard let on = args["on"]?.bool else { throw CommandError.invalidArgs("args: { on }") }
                // no `blocking`: a caller that went around `execute`, so no entry ran
                guard !on || args["blocking"] != nil else { throw CommandError("failed", "show mode entry did not run") }
                let blocking = on ? (args["blocking"]?.array ?? []).compactMap(\.string) : hooks.showMode(false) ?? []
                if !blocking.isEmpty { throw CommandError("notReady", "readiness: \(blocking.joined(separator: ", "))") }
                return nil
            })
        store.register(CommandSpec(name: "readiness.run", role: .operator, mutatesConfig: false, undoable: false, summary: "Run the readiness checks now.") { _, _ in
            hooks.runReadiness()
            return nil
        })
        store.register(CommandSpec(name: "readiness.acknowledge", role: .programmer, mutatesConfig: false, undoable: false, summary: "Acknowledge a failed readiness item so show mode can be entered.", argsType: "{ id: string }") { _, args in
            guard let id = args["id"]?.string else { throw CommandError.invalidArgs("args: { id }") }
            hooks.acknowledge(id, true)
            return nil
        })
        store.register(CommandSpec(name: "readiness.unacknowledge", role: .programmer, mutatesConfig: false, undoable: false, summary: "Take back a readiness item's acknowledgement; a failed item blocks show mode again.", argsType: "{ id: string }") { _, args in
            guard let id = args["id"]?.string else { throw CommandError.invalidArgs("args: { id }") }
            hooks.acknowledge(id, false)
            return nil
        })
    }
}
