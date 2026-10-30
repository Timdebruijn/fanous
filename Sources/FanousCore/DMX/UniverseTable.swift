// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// E1.31 §6.7.2 sequence rule (also applied to Art-Net sequence numbers):
/// a packet is out of sequence when (new − last) as Int8 is in −19…0.
public struct SequenceGate: Sendable, Equatable {
    private var last: UInt8?

    public init() {}

    public mutating func accept(_ sequence: UInt8) -> Bool {
        defer { last = sequence }
        guard let last else { return true }
        let diff = Int8(bitPattern: sequence &- last)
        return !(diff <= 0 && diff > -20)
    }
}

/// One sACN universe: sources keyed by CID, highest priority wins, equal
/// priorities LTP by arrival, 2.5 s timeout (ADR-0009).
public struct SACNUniverseMerger: Sendable {
    public struct Source: Sendable, Equatable {
        public var cid: [UInt8]
        public var name: String
        public var priority: UInt8
        public var lastSeen: TimeInterval
        public var slots: [UInt8]
        var gate = SequenceGate()
    }

    public static let timeout: TimeInterval = 2.5
    public private(set) var sources: [[UInt8]: Source] = [:]

    public init() {}

    /// Returns false when the packet was rejected (preview, non-DMX start code, out of sequence).
    public mutating func apply(_ packet: SACNData, at time: TimeInterval) -> Bool {
        guard packet.startCode == 0, !packet.isPreview else { return false }
        if packet.isTerminated {
            sources[packet.cid] = nil
            return true
        }
        var source = sources[packet.cid] ?? Source(cid: packet.cid, name: packet.sourceName, priority: packet.priority, lastSeen: time, slots: [])
        let accepted = source.gate.accept(packet.sequence)
        if accepted {
            source.name = packet.sourceName
            source.priority = packet.priority
            source.lastSeen = time
            source.slots = packet.slots + [UInt8](repeating: 0, count: 512 - packet.slots.count)
        }
        sources[packet.cid] = source
        return accepted
    }

    @discardableResult
    public mutating func expire(at time: TimeInterval) -> Bool {
        let before = sources.count
        sources = sources.filter { time - $0.value.lastSeen <= Self.timeout }
        return sources.count != before
    }

    public var winner: Source? {
        sources.values.max { a, b in a.priority != b.priority ? a.priority < b.priority : a.lastSeen < b.lastSeen }
    }

    public var slots: [UInt8]? { winner?.slots }

    /// The sources at the highest priority, oldest first.
    private var top: [Source] {
        guard let priority = winner?.priority else { return [] }
        return sources.values.filter { $0.priority == priority }.sorted { $0.lastSeen < $1.lastSeen }
    }

    /// `highest`: the winner's slots. `htp`: the sources at the highest priority merged, highest value per slot.
    public func slots(_ mode: UniverseSettings.PriorityMode) -> [UInt8]? {
        let top = mode == .htp ? self.top : []
        guard top.count > 1 else { return slots }
        return top.dropFirst().reduce(top[0].slots) { merged, source in zip(merged, source.slots).map { max($0, $1) } }
    }

    /// "Console A (p100)", or "Console A + Console B (p100)" for an HTP merge.
    public func sourceName(_ mode: UniverseSettings.PriorityMode) -> String {
        guard let winner else { return "" }
        let names = mode == .htp ? top.map(\.name) : [winner.name]
        return "\(names.joined(separator: " + ")) (p\(winner.priority))"
    }
}

public struct ArtNetUniverseState: Sendable, Equatable {
    private var gates: [String: SequenceGate] = [:]
    public private(set) var slots: [UInt8]?
    public private(set) var lastSeen: TimeInterval = 0
    public private(set) var lastSource = ""

    public init() {}

    public mutating func apply(_ packet: ArtDmx, from source: String, at time: TimeInterval) -> Bool {
        var gate = gates[source] ?? SequenceGate()
        let accepted = packet.sequence == 0 || gate.accept(packet.sequence)
        gates[source] = gate
        guard accepted else { return false }
        slots = packet.data + [UInt8](repeating: 0, count: 512 - packet.data.count)
        lastSeen = time
        lastSource = source
        return true
    }
}

public struct UniverseStatus: Equatable, Sendable {
    public var universe: UniverseID
    public var active: Bool
    public var lastSeen: TimeInterval
    public var packets: Int
    public var source: String
}

/// All received universes, both transports, routed by the per-universe settings (B28): a wire packet feeds its own
/// universe (unless that one listens only to the other transport) and every universe that has it as its `pair`.
/// Used on the DMX queue; copies are cheap enough for the UI's 20 Hz snapshots.
public struct UniverseTable: Sendable {
    private struct Entry: Sendable {
        var artnet = ArtNetUniverseState()
        var sacn = SACNUniverseMerger()
        var packets = 0
        var lastSeen: TimeInterval = 0
        var slots: [UInt8]?
        var source = ""
    }
    private var entries: [UniverseID: Entry] = [:]
    public private(set) var settings: [UniverseID: UniverseSettings] = [:]
    /// Wire universe → the universes with settings it feeds.
    private var routes: [UniverseID: [UniverseID]] = [:]
    /// Senders a universe accepts (its `interface`); no entry = every sender.
    private var filters: [UniverseID: [IPv4Subnet]] = [:]

    public init() {}

    public func settings(for id: UniverseID) -> UniverseSettings { settings[id] ?? UniverseSettings(for: id) }

    public mutating func configure(_ settings: [UniverseID: UniverseSettings], at time: TimeInterval) {
        // a universe fed from other wire universes starts clean (sequence numbers differ per wire universe)
        for id in entries.keys {
            let (old, new) = (self.settings(for: id), settings[id] ?? UniverseSettings(for: id))
            if old.protocols != new.protocols || old.pair != new.pair {
                entries[id]?.artnet = ArtNetUniverseState()
                entries[id]?.sacn = SACNUniverseMerger()
            }
        }
        self.settings = settings
        routes = [:]
        for (id, s) in settings {
            for transport in [UniverseID.Transport.artnet, .sacn] where s.listens(to: transport) {
                routes[s.wire(of: id, over: transport), default: []].append(id)
            }
        }
        for id in entries.keys { refresh(id, at: time) }
    }

    /// Per universe with an interface: the subnets of that interface (empty when it is not present).
    public mutating func setFilters(_ filters: [UniverseID: [IPv4Subnet]]) { self.filters = filters }

    private func targets(of wire: UniverseID) -> [UniverseID] {
        let routed = routes[wire] ?? []
        return settings[wire] == nil ? [wire] + routed : routed
    }

    private func accepts(_ id: UniverseID, from sender: String) -> Bool {
        guard let subnets = filters[id] else { return true }
        return subnets.contains { $0.contains(sender) }
    }

    /// The universes the packet fed (empty: wrong interface, out of sequence, or nobody listens).
    @discardableResult
    public mutating func apply(artnet packet: ArtDmx, from source: String, at time: TimeInterval) -> [UniverseID] {
        var fed: [UniverseID] = []
        for id in targets(of: packet.universeID) where accepts(id, from: source) {
            var entry = entries[id] ?? Entry()
            let accepted = entry.artnet.apply(packet, from: source, at: time)
            entries[id] = entry
            if accepted { fed.append(id) }
        }
        for id in fed { count(id, at: time) }
        return fed
    }

    @discardableResult
    public mutating func apply(sacn packet: SACNData, from sender: String = "", at time: TimeInterval) -> [UniverseID] {
        var fed: [UniverseID] = []
        for id in targets(of: packet.universeID) where accepts(id, from: sender) {
            var entry = entries[id] ?? Entry()
            let accepted = entry.sacn.apply(packet, at: time)
            entries[id] = entry
            if accepted { fed.append(id) }
        }
        for id in fed { count(id, at: time) }
        return fed
    }

    private mutating func count(_ id: UniverseID, at time: TimeInterval) {
        entries[id]?.packets += 1
        entries[id]?.lastSeen = time
        refresh(id, at: time)
    }

    /// Recomputes a universe's slots and source from what its transports hold. Both transports: the higher priority
    /// wins (Art-Net counts as 100 while it is not silent), equal priorities by the priority mode.
    private mutating func refresh(_ id: UniverseID, at time: TimeInterval) {
        guard var entry = entries[id] else { return }
        let s = settings(for: id)
        let artnet = s.listens(to: .artnet) && entry.artnet.slots != nil
        let winner = s.listens(to: .sacn) ? entry.sacn.winner : nil
        var useSACN = winner != nil
        var merge = false
        if artnet, let winner, time - entry.artnet.lastSeen <= SACNUniverseMerger.timeout {
            if winner.priority == UniverseSettings.artnetPriority {
                merge = s.priorityMode == .htp
                useSACN = winner.lastSeen >= entry.artnet.lastSeen
            } else {
                useSACN = winner.priority > UniverseSettings.artnetPriority
            }
        }
        if merge, let a = entry.artnet.slots, let b = entry.sacn.slots(s.priorityMode) {
            entry.slots = zip(a, b).map { max($0, $1) }
            entry.source = "\(entry.artnet.lastSource) + \(entry.sacn.sourceName(s.priorityMode))"
        } else if useSACN {
            entry.slots = entry.sacn.slots(s.priorityMode)
            entry.source = entry.sacn.sourceName(s.priorityMode)
        } else if artnet {
            entry.slots = entry.artnet.slots
            entry.source = entry.artnet.lastSource
        } else {
            entry.slots = nil
            entry.source = ""
        }
        entries[id] = entry
    }

    /// sACN sources silent for 2.5 s are dropped (the E1.31 source timeout, so a backup console takes over on time);
    /// a universe's `lossTimeout` decides only when the universe counts as lost.
    public mutating func expire(at time: TimeInterval) {
        for id in entries.keys {
            entries[id]?.sacn.expire(at: time)
            refresh(id, at: time)
        }
    }

    public func slots(for id: UniverseID) -> [UInt8]? { entries[id]?.slots }

    public func status(for id: UniverseID, at time: TimeInterval) -> UniverseStatus {
        let entry = entries[id]
        let seen = entry?.lastSeen ?? 0
        return UniverseStatus(
            universe: id, active: seen > 0 && time - seen <= settings(for: id).lossTimeout, lastSeen: seen, packets: entry?.packets ?? 0,
            source: entry?.source ?? "")
    }

    public var knownUniverses: [UniverseID] { entries.filter { $0.value.packets > 0 }.keys.sorted() }
}

