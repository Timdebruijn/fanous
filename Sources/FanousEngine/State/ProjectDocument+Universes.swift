// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation

/// Per-universe settings in the project (B28): `/universes` is a list of
/// `{"id":"artnet:0.0.1","protocol":"artnet","interface":"any","holdOnLoss":"hold","lossTimeout":2.5,"sacnPriorityMode":"highest","pair":"sacn:2"}`.
/// A universe without an entry runs the defaults (the behaviour before B28), so projects without the list are unchanged;
/// an entry set back to the defaults is removed.
extension ProjectDocument {
    static let universeFields = ["protocol", "interface", "holdOnLoss", "lossTimeout", "sacnPriorityMode", "pair"]

    /// The settings the engine runs (`universeEntries`).
    public static func universeSettings(from project: JSONValue) -> [UniverseID: UniverseSettings] { universeEntries(from: project).settings }

    /// The first entry per universe, when valid. An invalid entry (hand-edited file) runs the defaults and a later entry
    /// for the same universe is ignored; `issues` has one line per such entry, naming the universe and the field.
    public static func universeEntries(from project: JSONValue) -> (settings: [UniverseID: UniverseSettings], issues: [String]) {
        var settings: [UniverseID: UniverseSettings] = [:]
        var seen: Set<UniverseID> = []
        var issues: [String] = []
        for (i, entry) in (project["universes"]?.array ?? []).enumerated() {
            guard let id = entry["id"]?.string.flatMap(UniverseID.init(parsing:)) else {
                issues.append("universes[\(i)]: id must be artnet:net.subnet.universe or sacn:n; entry ignored")
                continue
            }
            guard seen.insert(id).inserted else {
                issues.append("\(id): duplicate entry ignored; the first one applies")
                continue
            }
            do {
                settings[id] = try universeSettings(entry, for: id)
            } catch {
                issues.append("\(id): \((error as? CommandError)?.message ?? "\(error)"); runs the defaults")
            }
        }
        return (settings, issues)
    }

    /// One entry, validated; missing fields take their defaults.
    static func universeSettings(_ entry: JSONValue, for id: UniverseID) throws -> UniverseSettings {
        var s = UniverseSettings(for: id)
        func pick<T: RawRepresentable>(_ field: String, _ type: T.Type, _ message: String) throws -> T? where T.RawValue == String {
            guard let value = entry[field] else { return nil }
            guard let parsed = value.string.flatMap(T.init(rawValue:)) else { throw CommandError.invalidArgs(message) }
            return parsed
        }
        s.protocols = try pick("protocol", UniverseSettings.Protocols.self, "protocol must be artnet, sacn or both") ?? s.protocols
        s.holdOnLoss = try pick("holdOnLoss", UniverseSettings.Loss.self, "holdOnLoss must be hold, zero or internal") ?? s.holdOnLoss
        s.priorityMode = try pick("sacnPriorityMode", UniverseSettings.PriorityMode.self, "sacnPriorityMode must be highest or htp") ?? s.priorityMode
        if let value = entry["interface"] {
            guard let text = value.string, UniverseSettings.isValidInterface(text) else {
                throw CommandError.invalidArgs("interface must be any, an interface name such as en0, or an IPv4 address")
            }
            s.interface = text
        }
        if let value = entry["lossTimeout"] {
            let range = UniverseSettings.lossTimeoutRange
            guard let seconds = value.double, range.contains(seconds) else {
                throw CommandError.invalidArgs("lossTimeout must be \(range.lowerBound)–\(range.upperBound) seconds")
            }
            s.lossTimeout = seconds
        }
        if let value = entry["pair"], value != .null {
            guard let pair = value.string.flatMap(UniverseID.init(parsing:)), pair.transport != id.transport else {
                throw CommandError.invalidArgs("pair must be a universe of the other protocol (\(id.transport == .artnet ? "sacn:n" : "artnet:net.subnet.universe"))")
            }
            s.pair = pair
        }
        return s
    }

    static func universeValue(_ id: UniverseID, _ s: UniverseSettings) -> JSONValue {
        [
            "id": .string(id.description), "protocol": .string(s.protocols.rawValue), "interface": .string(s.interface),
            "holdOnLoss": .string(s.holdOnLoss.rawValue), "lossTimeout": .number(s.lossTimeout),
            "sacnPriorityMode": .string(s.priorityMode.rawValue), "pair": .string(s.pair.description),
        ]
    }

    static func registerUniverseCommands(on store: StateStore) {
        store.register(
            CommandSpec(
                name: "universe.set", role: .programmer,
                summary: "Set one receive setting of a universe: protocol (artnet, sacn, both), interface (any, en0, an IPv4 address), holdOnLoss (hold, zero, internal), lossTimeout (1–60 s; the sACN source timeout stays 2.5 s), sacnPriorityMode (highest, htp), pair (the other protocol's universe; null = default); applies live.",
                argsType: "{ id: string; path: '/protocol' | '/interface' | '/holdOnLoss' | '/lossTimeout' | '/sacnPriorityMode' | '/pair'; value: JSONValue }"
            ) { project, args in
                guard let id = args["id"]?.string.flatMap(UniverseID.init(parsing:)) else {
                    throw CommandError.invalidArgs("id must be artnet:net.subnet.universe or sacn:n")
                }
                guard let path = args["path"]?.string, universeFields.contains(String(path.dropFirst())), path.hasPrefix("/"), let value = args["value"] else {
                    throw CommandError.invalidArgs("args: { id, path: /\(universeFields.joined(separator: " | /")), value }")
                }
                // start from what the engine runs (the first valid entry, else the defaults), so the edit never revives
                // an ignored duplicate or keeps an invalid field; the result is one entry for the universe, or none
                let current = project["universes"]?.array ?? []
                var entry = universeValue(id, universeSettings(from: project)[id] ?? UniverseSettings(for: id))
                try entry.set(value, at: JSONPointer(path))
                let settings = try universeSettings(entry, for: id)
                var list = current.filter { $0["id"]?.string.flatMap(UniverseID.init(parsing:)) != id }
                if settings != UniverseSettings(for: id) { list.append(universeValue(id, settings)) }
                list.sort { ($0["id"]?.string.flatMap(UniverseID.init(parsing:)) ?? id) < ($1["id"]?.string.flatMap(UniverseID.init(parsing:)) ?? id) }
                guard list != current else { return nil }
                try project.set(.array(list), at: "/universes")
                return nil
            })
    }
}
