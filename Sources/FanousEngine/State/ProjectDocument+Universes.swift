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

    /// Every valid entry; an invalid one (hand-edited file) runs the defaults.
    public static func universeSettings(from project: JSONValue) -> [UniverseID: UniverseSettings] {
        var result: [UniverseID: UniverseSettings] = [:]
        for entry in project["universes"]?.array ?? [] {
            guard let id = entry["id"]?.string.flatMap(UniverseID.init(parsing:)), let settings = try? universeSettings(entry, for: id) else { continue }
            result[id] = settings
        }
        return result
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
                summary: "Set one receive setting of a universe: protocol (artnet, sacn, both), interface (any, en0, an IPv4 address), holdOnLoss (hold, zero, internal), lossTimeout (0.5–60 s), sacnPriorityMode (highest, htp), pair (the other protocol's universe; null = default); applies live.",
                argsType: "{ id: string; path: '/protocol' | '/interface' | '/holdOnLoss' | '/lossTimeout' | '/sacnPriorityMode' | '/pair'; value: JSONValue }"
            ) { project, args in
                guard let id = args["id"]?.string.flatMap(UniverseID.init(parsing:)) else {
                    throw CommandError.invalidArgs("id must be artnet:net.subnet.universe or sacn:n")
                }
                guard let path = args["path"]?.string, universeFields.contains(String(path.dropFirst())), path.hasPrefix("/"), let value = args["value"] else {
                    throw CommandError.invalidArgs("args: { id, path: /\(universeFields.joined(separator: " | /")), value }")
                }
                let current = project["universes"]?.array ?? []
                var list = current
                let index = list.firstIndex { $0["id"]?.string.flatMap(UniverseID.init(parsing:)) == id }
                var entry = index.map { list[$0] } ?? universeValue(id, UniverseSettings(for: id))
                try entry.set(value, at: JSONPointer(path))
                let settings = try universeSettings(entry, for: id)
                let stored: JSONValue? = settings == UniverseSettings(for: id) ? .none : universeValue(id, settings)
                switch (index, stored) {
                case (let i?, let v?): list[i] = v
                case (let i?, nil): list.remove(at: i)
                case (nil, let v?): list.append(v)
                case (nil, nil): break
                }
                guard list != current else { return nil }
                list.sort { ($0["id"]?.string.flatMap(UniverseID.init(parsing:)) ?? id) < ($1["id"]?.string.flatMap(UniverseID.init(parsing:)) ?? id) }
                try project.set(.array(list), at: "/universes")
                return nil
            })
    }
}
