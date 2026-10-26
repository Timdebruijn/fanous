// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

public enum SourcePolicy: String, Codable, Sendable, CaseIterable { case dmx, `internal`, ltp, htp }

public enum ValueSource: String, Codable, Sendable, Equatable { case none, dmx, cue, osc, ui }

public struct ResolvedValue: Equatable, Sendable {
    public var raw: UInt16
    public var source: ValueSource
    public var changedAt: TimeInterval
}

/// Combines DMX and internal sources for one fixture (DESIGN.md §7.2, ADR-0009).
/// Values are raw DMX units; `ChannelMap` converts them to physical units.
public struct FixtureResolver: Sendable {
    public let mode: FixtureMode
    public var policy: SourcePolicy
    public private(set) var hasDMX = false
    /// Hold on loss `internal` (B28): without DMX the fixture resolves as policy `internal`.
    public var internalWithoutDMX = false

    private let specs: [ParameterSpec]
    private var dmxRaw: [UInt16]
    private var dmxChangedAt: [TimeInterval]
    private var internalRaw: [UInt16?]
    private var internalSource: [ValueSource]
    private var internalChangedAt: [TimeInterval]

    public init(mode: FixtureMode, policy: SourcePolicy = .dmx) {
        self.mode = mode
        self.policy = policy
        specs = ChannelMap.specs(for: mode)
        dmxRaw = specs.map(\.defaultRaw)
        dmxChangedAt = Array(repeating: 0, count: specs.count)
        internalRaw = Array(repeating: nil, count: specs.count)
        internalSource = Array(repeating: .none, count: specs.count)
        internalChangedAt = Array(repeating: 0, count: specs.count)
    }

    /// New DMX frame (raw values in spec order, from `ChannelMap.rawValues`).
    /// Returns whether anything a reader can see changed: a value, or signal coming back after a loss.
    @discardableResult
    public mutating func updateDMX(_ raw: [UInt16], at time: TimeInterval) -> Bool {
        precondition(raw.count == specs.count)
        var changed = !hasDMX
        hasDMX = true
        for i in raw.indices where raw[i] != dmxRaw[i] {
            dmxRaw[i] = raw[i]
            dmxChangedAt[i] = time
            changed = true
        }
        return changed
    }

    /// Signal loss: values are held (Catalyst behaviour); only the flag changes.
    public mutating func markDMXLost() { hasDMX = false }

    public mutating func setInternal(_ id: ParameterID, raw: UInt16, source: ValueSource, at time: TimeInterval) {
        let i = ChannelMap.index(of: id)
        internalRaw[i] = specs[i].clamped(raw)
        internalSource[i] = source
        internalChangedAt[i] = time
    }

    public mutating func clearInternal(source: ValueSource) {
        for i in internalRaw.indices where internalSource[i] == source {
            internalRaw[i] = nil
            internalSource[i] = .none
        }
    }

    public func resolved(_ id: ParameterID) -> ResolvedValue { resolved(index: ChannelMap.index(of: id)) }

    /// Values internal sources have set, whether or not the policy lets them through (the UI greys them out).
    public func internalValues() -> [(parameter: ParameterID, raw: UInt16, source: ValueSource)] {
        specs.indices.compactMap { i in internalRaw[i].map { (specs[i].id, $0, internalSource[i]) } }
    }

    public func resolvedAll() -> [ResolvedValue] { specs.indices.map(resolved(index:)) }

    public func physical(_ id: ParameterID) -> Double {
        ChannelMap.spec(id).physical(fromRaw: resolved(id).raw)
    }

    private func resolved(index i: Int) -> ResolvedValue {
        let policy = internalWithoutDMX && !hasDMX ? .internal : self.policy
        let dmx = ResolvedValue(raw: dmxRaw[i], source: hasDMX || dmxChangedAt[i] > 0 ? .dmx : .none, changedAt: dmxChangedAt[i])
        guard let internalValue = internalRaw[i] else {
            return policy == .internal ? ResolvedValue(raw: specs[i].defaultRaw, source: .none, changedAt: 0) : dmx
        }
        let internalResolved = ResolvedValue(raw: internalValue, source: internalSource[i], changedAt: internalChangedAt[i])
        switch policy {
        case .dmx: return dmx
        case .internal: return internalResolved
        case .ltp: return internalResolved.changedAt >= dmx.changedAt ? internalResolved : dmx
        case .htp:
            guard specs[i].isContinuous else { return internalResolved.changedAt >= dmx.changedAt ? internalResolved : dmx }
            return internalResolved.raw >= dmx.raw ? internalResolved : dmx
        }
    }
}
