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

/// All received universes, both transports. Used on the DMX queue; copies
/// are cheap enough for the UI's 20 Hz snapshots.
public struct UniverseTable: Sendable {
    public static let lossTimeout: TimeInterval = 2.5
    private var artnet: [Int: ArtNetUniverseState] = [:]
    private var sacn: [Int: SACNUniverseMerger] = [:]
    private var packets: [UniverseID: Int] = [:]
    private var lastSeen: [UniverseID: TimeInterval] = [:]

    public init() {}

    @discardableResult
    public mutating func apply(artnet packet: ArtDmx, from source: String, at time: TimeInterval) -> UniverseID? {
        let id = packet.universeID
        var state = artnet[id.number] ?? ArtNetUniverseState()
        let accepted = state.apply(packet, from: source, at: time)
        artnet[id.number] = state
        guard accepted else { return nil }
        packets[id, default: 0] += 1
        lastSeen[id] = time
        return id
    }

    @discardableResult
    public mutating func apply(sacn packet: SACNData, at time: TimeInterval) -> UniverseID? {
        let id = packet.universeID
        var merger = sacn[id.number] ?? SACNUniverseMerger()
        let accepted = merger.apply(packet, at: time)
        sacn[id.number] = merger
        guard accepted else { return nil }
        packets[id, default: 0] += 1
        lastSeen[id] = time
        return id
    }

    public mutating func expire(at time: TimeInterval) {
        for key in sacn.keys { sacn[key]?.expire(at: time) }
    }

    public func slots(for id: UniverseID) -> [UInt8]? {
        switch id.transport {
        case .artnet: artnet[id.number]?.slots
        case .sacn: sacn[id.number]?.slots
        }
    }

    public func status(for id: UniverseID, at time: TimeInterval) -> UniverseStatus {
        let seen = lastSeen[id] ?? 0
        let source: String
        switch id.transport {
        case .artnet: source = artnet[id.number]?.lastSource ?? ""
        case .sacn: source = sacn[id.number]?.winner.map { "\($0.name) (p\($0.priority))" } ?? ""
        }
        return UniverseStatus(
            universe: id, active: seen > 0 && time - seen <= Self.lossTimeout, lastSeen: seen, packets: packets[id] ?? 0,
            source: source)
    }

    public var knownUniverses: [UniverseID] { packets.keys.sorted() }
}
