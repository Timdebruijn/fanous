// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// docs/channel-map.md, generated from `ChannelMap` (`fanousd channel-map`).
public enum ChannelMapDocument {
    public static func markdown() -> String {
        var md = "# Fanous DMX channel map\n\n"
        md += "Generated from `Sources/FanousCore/Parameters/ChannelMap.swift` by `fanousd channel-map`; do not edit by hand. "
        md += "16-bit parameters use coarse/fine on adjacent channels. OSC: `\(OSCAddressMap.prefix)/layer/{n}/{key}`, `/master/{key}`, `/output/{n}/{key}`, `/keystone/{n}/{key}` (float = normalized 0–1, int = raw).\n\n"
        for mode in FixtureMode.allCases {
            md += "## \(mode.displayName) mode (\(mode.footprint) channels)\n\n"
            md += "| Ch | Parameter | Bits | Default | Mapping | OSC key |\n|---|---|---|---|---|---|\n"
            for spec in ChannelMap.specs(for: mode) {
                let channels = spec.bits == 16 ? "\(spec.channel)–\(spec.channel + 1)" : "\(spec.channel)"
                md += "| \(channels) | \(spec.name) | \(spec.bits) | \(spec.defaultRaw) | \(mapping(spec)) | `\(spec.oscKey)` |\n"
            }
            if let reserved = ChannelMap.reserved(for: mode) {
                md += "| \(reserved.lowerBound)–\(reserved.upperBound) | Reserved | — | 0 | ignored | — |\n"
            }
            md += "\n"
        }
        md += "## Effect parameters\n\n"
        md += "Effect 1 and Effect 2 (layer channels 38–43) share these meanings; both slots run in series, slot 1 first.\n\n"
        md += "| Effect | Param A | Param B |\n|---|---|---|\n"
        for spec in EffectSpec.all {
            md += "| \(ChannelMap.spec(.layer(.effect1)).label(forRaw: UInt16(spec.effect.rawValue * 16))) | \(spec.paramA) | \(spec.paramB) |\n"
        }
        md += "\n"
        return md
    }

    static func mapping(_ spec: ParameterSpec) -> String {
        switch spec.kind {
        case .curve(let points, let unit):
            return points.map { "\(Int($0.raw)) → \(number($0.value))\(unit == "°" ? "°" : " " + unit)" }.joined(separator: " · ")
        case .bands(let bands, let fallback):
            let fallbackName = bands.first { $0.value == fallback }?.name ?? "?"
            return bands.map { "\($0.from)–\($0.to) \($0.name)" }.joined(separator: " · ") + " · rest = \(fallbackName)"
        case .index(let max):
            // Output ch 6: 0 is the mapping as edited (DESIGN.md §6.4), not nothing
            return "0 = \(spec.id == .output(.preset) ? "as edited" : "none") · 1–\(max)"
        }
    }

    static func number(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
}

extension ChannelMapDocument {
    /// The same specs as the markdown, for the UI (DMX monitor labels, Patch screen): per mode a list of
    /// parameters with their channels and bands. Names are the ones `docs/channel-map.md` prints.
    public static func json() -> JSONValue {
        var modes: [String: JSONValue] = [:]
        for mode in FixtureMode.allCases {
            modes[mode.rawValue] = .array(
                ChannelMap.specs(for: mode).map { spec in
                    var entry: [String: JSONValue] = [
                        "name": .string(spec.name), "key": .string(spec.id.key), "channel": .number(Double(spec.channel)),
                        "bits": .number(Double(spec.bits)), "default": .number(Double(spec.defaultRaw)), "group": .string(spec.group),
                        "unit": .string(spec.unit),
                    ]
                    if case .bands(let bands, _) = spec.kind {
                        entry["bands"] = .array(bands.map { ["from": .number(Double($0.from)), "to": .number(Double($0.to)), "name": .string($0.name)] })
                    }
                    return .object(entry)
                })
        }
        return ["footprints": .object(Dictionary(uniqueKeysWithValues: FixtureMode.allCases.map { ($0.rawValue, JSONValue.number(Double($0.footprint))) })), "modes": .object(modes)]
    }
}
