// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

public enum FixtureMode: String, CaseIterable, Codable, Sendable {
    case layer, master, output, keystone

    public var footprint: Int {
        switch self {
        case .layer: 64
        case .master, .output: 8
        case .keystone: 16
        }
    }

    /// What a fixture of this mode is patched per (DESIGN.md §6.6 item 3); the Patch screen groups by it.
    public enum Per: String, Sendable { case layer, machine, output }

    public var per: Per {
        switch self {
        case .layer: .layer
        case .master: .machine
        case .output, .keystone: .output
        }
    }

    /// A show runs fine without patching it; the other modes are required.
    public var optional: Bool { self == .keystone }

    public var displayName: String { rawValue.capitalized }
}

public enum LayerParameter: String, CaseIterable, Codable, Sendable {
    case intensity, folder, file, playMode, speed, inPoint, outPoint, dissolve
    case positionX, positionY, positionZ, scaleX, scaleY, fitMode, rotationX, rotationY, rotationZ
    case red, green, blue, brightness, contrast, saturation, hue, blendMode
    case effect1, effect1A, effect1B, effect2, effect2A, effect2B
    case cropLeft, cropRight, cropTop, cropBottom, audioVolume, audioPan, control, sync
}

public enum MasterParameter: String, CaseIterable, Codable, Sendable { case intensity, control, testPattern, speed }

public enum OutputParameter: String, CaseIterable, Codable, Sendable { case intensity, control, testPattern, blend, preset, fade }

/// Corner offsets in channel order: TL, TR, BR, BL as `WarpSettings.cornerPin`, X then Y (DESIGN.md §6.4a).
public enum KeystoneParameter: String, CaseIterable, Codable, Sendable {
    case topLeftX, topLeftY, topRightX, topRightY, bottomRightX, bottomRightY, bottomLeftX, bottomLeftY
}

public enum ParameterID: Hashable, Codable, Sendable, CustomStringConvertible {
    case layer(LayerParameter)
    case master(MasterParameter)
    case output(OutputParameter)
    case keystone(KeystoneParameter)

    public var mode: FixtureMode {
        switch self {
        case .layer: .layer
        case .master: .master
        case .output: .output
        case .keystone: .keystone
        }
    }

    /// Stable key used for OSC addresses, JSON and generated documentation.
    public var key: String {
        switch self {
        case .layer(let p): p.rawValue
        case .master(let p): p.rawValue
        case .output(let p): p.rawValue
        case .keystone(let p): p.rawValue
        }
    }

    public var description: String { "\(mode.rawValue).\(key)" }
}

/// A contiguous raw range with a meaning, e.g. 16–31 = "Loop rev".
public struct Band: Equatable, Sendable {
    public let from: UInt8
    public let to: UInt8
    public let name: String
    public let value: Int

    public init(from: UInt8, to: UInt8, name: String, value: Int) {
        self.from = from
        self.to = to
        self.name = name
        self.value = value
    }

    public func contains(_ raw: UInt16) -> Bool { raw >= UInt16(from) && raw <= UInt16(to) }
}

public struct CurvePoint: Equatable, Sendable {
    public let raw: Double
    public let value: Double
    public init(_ raw: Double, _ value: Double) {
        self.raw = raw
        self.value = value
    }
}

public enum ParameterKind: Equatable, Sendable {
    /// Piecewise-linear raw → physical, points sorted by raw, covering 0…rawMax.
    case curve([CurvePoint], unit: String)
    /// 8-bit bands; raw values outside every band take `fallback` (an enum raw value).
    case bands([Band], fallback: Int)
    /// Plain index (folder/file numbers): physical = raw.
    case index(max: Int)
}

public struct ParameterSpec: Equatable, Sendable {
    public let id: ParameterID
    public let name: String
    /// First channel, 1-based, within the fixture mode.
    public let channel: Int
    public let bits: Int
    public let defaultRaw: UInt16
    public let kind: ParameterKind
    public let group: String

    public init(id: ParameterID, name: String, channel: Int, bits: Int, defaultRaw: UInt16, kind: ParameterKind, group: String) {
        precondition(bits == 8 || bits == 16)
        self.id = id
        self.name = name
        self.channel = channel
        self.bits = bits
        self.defaultRaw = defaultRaw
        self.kind = kind
        self.group = group
    }

    public var rawMax: UInt16 { bits == 16 ? 65535 : 255 }
    public var channels: ClosedRange<Int> { channel...(channel + bits / 8 - 1) }
    public var oscKey: String { id.key }

    public var unit: String {
        if case .curve(_, let unit) = kind { return unit }
        return ""
    }

    /// Continuous parameters fade and merge HTP; bands and indices snap and merge LTP.
    public var isContinuous: Bool {
        if case .curve = kind { return true }
        return false
    }

    public func clamped(_ raw: UInt16) -> UInt16 { min(raw, rawMax) }

    /// Enum raw value for band parameters (fallback when no band matches), index value, or physical value.
    public func physical(fromRaw raw: UInt16) -> Double {
        let raw = clamped(raw)
        switch kind {
        case .curve(let points, _):
            let x = Double(raw)
            guard let first = points.first, let last = points.last else { return 0 }
            if x <= first.raw { return first.value }
            if x >= last.raw { return last.value }
            for (a, b) in zip(points, points.dropFirst()) where x >= a.raw && x <= b.raw {
                if b.raw == a.raw { return b.value }
                return a.value + (b.value - a.value) * (x - a.raw) / (b.raw - a.raw)
            }
            return last.value
        case .bands(let bands, let fallback):
            return Double(bands.first { $0.contains(raw) }?.value ?? fallback)
        case .index:
            return Double(raw)
        }
    }

    /// Inverse of `physical(fromRaw:)`; for bands returns the start of the band with that value.
    public func raw(fromPhysical value: Double) -> UInt16 {
        switch kind {
        case .curve(let points, _):
            guard let first = points.first, let last = points.last else { return 0 }
            if value <= first.value { return UInt16(first.raw) }
            if value >= last.value { return UInt16(last.raw) }
            for (a, b) in zip(points, points.dropFirst()) where value >= a.value && value <= b.value {
                if b.value == a.value { return UInt16(a.raw) }
                return UInt16((a.raw + (b.raw - a.raw) * (value - a.value) / (b.value - a.value)).rounded())
            }
            return UInt16(last.raw)
        case .bands(let bands, _):
            return UInt16(bands.first { $0.value == Int(value) }?.from ?? 0)
        case .index(let maxValue):
            return UInt16(max(0, min(Double(maxValue), value)))
        }
    }

    /// Human-readable value, e.g. "100 %", "-12.5°", "Loop rev", "12".
    public func label(forRaw raw: UInt16) -> String {
        switch kind {
        case .curve(_, let unit):
            let value = physical(fromRaw: raw)
            let text = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
            return unit == "°" ? text + unit : unit.isEmpty ? text : text + " " + unit
        case .bands(let bands, let fallback):
            return bands.first { $0.contains(raw) }?.name ?? bands.first { $0.value == fallback }?.name ?? "?"
        case .index:
            return String(raw)
        }
    }
}
