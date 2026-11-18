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

        mutating func take(_ packet: SACNData, at time: TimeInterval) -> Bool {
            guard gate.accept(packet.sequence) else { return false }
            name = packet.sourceName
            priority = packet.priority
            lastSeen = time
            slots = packet.slots + [UInt8](repeating: 0, count: 512 - packet.slots.count)
            return true
        }
    }

    public static let timeout: TimeInterval = 2.5
    /// Sources tracked per universe (B271): enough for any rig's main, backup and a few nodes. A new source with a full
    /// set replaces the lowest-priority source that is not the winner (the oldest on a tie) when its priority is strictly
    /// higher, and is refused otherwise; a place also frees when a source times out.
    public static let maxSources = 16
    public private(set) var sources: [[UInt8]: Source] = [:]
    /// New sources refused, and sources replaced, by `maxSources`; `UniverseTable` collects them.
    var refused = 0
    var replaced = 0

    public init() {}

    /// Returns false when the packet was rejected (preview, non-DMX start code, out of sequence, too many sources).
    public mutating func apply(_ packet: SACNData, at time: TimeInterval) -> Bool {
        guard packet.startCode == 0, !packet.isPreview else { return false }
        if packet.isTerminated {
            sources[packet.cid] = nil
            return true
        }
        if sources.index(forKey: packet.cid) == nil, sources.count >= Self.maxSources {
            // The winner is never replaced, and the merge (highest or htp) is the one without the cap: the replaced
            // source has a lower priority than the newcomer, so it would not be merged or win next to it. A scan of 16,
            // only for a new source with a full set; a flood below every tracked priority is refused.
            let winner = self.winner?.cid
            var weakest: Source?
            for source in sources.values where source.cid != winner {
                if let w = weakest, (w.priority, w.lastSeen) <= (source.priority, source.lastSeen) { continue }
                weakest = source
            }
            guard let weakest, packet.priority > weakest.priority else {
                refused += 1
                return false
            }
            sources[weakest.cid] = nil
            replaced += 1
        }
        // in place: a copy taken out and stored back would copy the dictionary on every packet
        return sources[packet.cid, default: Source(cid: packet.cid, name: packet.sourceName, priority: packet.priority, lastSeen: time, slots: [])]
            .take(packet, at: time)
    }

    public mutating func expire(at time: TimeInterval) {
        sources = sources.filter { time - $0.value.lastSeen <= Self.timeout }
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
    /// Senders whose sequence numbers are checked, per universe (B271): Art-Net has no source timeout, so the set is
    /// capped instead; a universe has a console, a backup and a few nodes. A new sender past the cap replaces the one
    /// seen longest ago. Its own constant: Art-Net merging is last-wins, so this cap only bounds memory.
    public static let maxSenders = 16
    private struct Sender: Equatable {
        var gate = SequenceGate()
        var lastSeen: TimeInterval = 0

        /// Sequence 0 means "not used" (Art-Net 4): accepted without touching the gate.
        mutating func take(_ sequence: UInt8, at time: TimeInterval) -> Bool {
            lastSeen = time
            return sequence == 0 || gate.accept(sequence)
        }
    }
    private var senders: [String: Sender] = [:]
    /// Senders replaced by `maxSenders`; `UniverseTable` collects them.
    var replaced = 0
    public private(set) var slots: [UInt8]?
    public private(set) var lastSeen: TimeInterval = 0
    public private(set) var lastSource = ""

    public init() {}

    public mutating func apply(_ packet: ArtDmx, from source: String, at time: TimeInterval) -> Bool {
        if senders.index(forKey: source) == nil, senders.count >= Self.maxSenders,
            let oldest = senders.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key
        {
            senders[oldest] = nil
            replaced += 1
        }
        guard senders[source, default: Sender()].take(packet.sequence, at: time) else { return false }
        slots = packet.data + [UInt8](repeating: 0, count: 512 - packet.data.count)
        lastSeen = time
        lastSource = source
        return true
    }

    /// Whether `source` is one of the senders tracked.
    public func tracks(_ source: String) -> Bool { senders.index(forKey: source) != nil }
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
/// At most `maxEntries` universes hold state (B271): one the patch or the settings use always gets in; any other (heard,
/// nothing patched: the Patch screen's warning, the DMX monitor) only while fewer are held, and such a universe is
/// forgotten once it has been silent for its loss timeout while the table is full.
public struct UniverseTable: Sendable {
    public static let maxEntries = 256
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
    /// The universes the patch uses: always held, never forgotten.
    public var patched: Set<UniverseID> = []
    /// What the caps did since the last `takeRefused()`.
    public struct Refusals: Equatable, Sendable {
        /// Packets of universes refused by `maxEntries`, of new sACN sources refused by `SACNUniverseMerger.maxSources`,
        /// sACN sources replaced by a higher-priority newcomer, and Art-Net senders replaced past
        /// `ArtNetUniverseState.maxSenders`.
        public var universes = 0, sources = 0, replaced = 0, senders = 0
        public init() {}
        public var isEmpty: Bool { self == Refusals() }
        public mutating func add(_ other: Refusals) {
            (universes, sources, replaced, senders) = (universes + other.universes, sources + other.sources, replaced + other.replaced, senders + other.senders)
        }
    }
    private var refused = Refusals()

    public init() {}

    private func isKept(_ id: UniverseID) -> Bool { patched.contains(id) || settings[id] != nil || routes[id] != nil }

    /// What the caps refused or replaced since the last call (sources: up to the last `expire`).
    public mutating func takeRefused() -> Refusals {
        defer { refused = Refusals() }
        return refused
    }

    /// Whether the universe is held and `source` still feeds it: an sACN source by name, an Art-Net sender by address.
    public func has(_ id: UniverseID, source: String, sacn: Bool) -> Bool {
        guard let entry = entries[id] else { return false }
        return sacn ? entry.sacn.sources.values.contains { $0.name == source } : entry.artnet.tracks(source)
    }

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
    public mutating func apply(artnet packet: ArtDmx, from source: String, at time: TimeInterval) -> [UniverseID] {
        feed(packet.universeID, from: source, at: time) { $0.artnet.apply(packet, from: source, at: time) }
    }

    public mutating func apply(sacn packet: SACNData, from sender: String = "", at time: TimeInterval) -> [UniverseID] {
        feed(packet.universeID, from: sender, at: time) { $0.sacn.apply(packet, at: time) }
    }

    private mutating func feed(
        _ wire: UniverseID, from sender: String, at time: TimeInterval, _ accept: (inout Entry) -> Bool
    ) -> [UniverseID] {
        var fed: [UniverseID] = []
        for id in targets(of: wire) where accepts(id, from: sender) {
            guard entries.index(forKey: id) != nil || entries.count < Self.maxEntries || isKept(id) else {
                refused.universes += 1
                continue
            }
            if accept(&entries[id, default: Entry()]) { fed.append(id) }
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
    /// A full table also forgets the universes nobody uses that have been silent for their loss timeout (B271).
    public mutating func expire(at time: TimeInterval) {
        let full = entries.count >= Self.maxEntries
        for id in entries.keys {
            refused.sources += entries[id]?.sacn.refused ?? 0
            refused.replaced += entries[id]?.sacn.replaced ?? 0
            refused.senders += entries[id]?.artnet.replaced ?? 0
            entries[id]?.sacn.refused = 0
            entries[id]?.sacn.replaced = 0
            entries[id]?.artnet.replaced = 0
            if full, !isKept(id), let seen = entries[id]?.lastSeen, time - seen > settings(for: id).lossTimeout {
                entries[id] = nil
                continue
            }
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

