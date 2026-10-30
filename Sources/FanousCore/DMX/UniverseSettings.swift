// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// Per-universe receive settings (B28, DESIGN.md §6.5), stored in the project's `universes` list. The defaults are
/// what the engine did before B28, so a project without the list receives exactly as before.
public struct UniverseSettings: Equatable, Sendable {
    /// Which transports feed the universe: its own (the id's) arrives on the id, the other one on `pair`.
    public enum Protocols: String, Sendable, CaseIterable { case artnet, sacn, both }
    /// What the universe's fixtures do once no packet arrived for `lossTimeout`: keep the last values, go to zero, or
    /// resolve as source policy `internal` (cues, OSC, UI) until packets return.
    public enum Loss: String, Sendable, CaseIterable { case hold, zero, `internal` }
    /// sACN sources at the same, highest priority: the latest packet wins (`highest`), or they merge per slot with the
    /// highest value winning (`htp`).
    public enum PriorityMode: String, Sendable, CaseIterable { case highest, htp }

    public static let anyInterface = "any"
    public static let defaultLossTimeout: TimeInterval = 2.5
    /// Above the 0.8–1 s DMX keep-alive interval of consoles that send only on change.
    public static let lossTimeoutRange: ClosedRange<TimeInterval> = 1...60
    /// Art-Net has no priority: where both transports feed a universe it competes as an sACN source at the default priority.
    public static let artnetPriority: UInt8 = 100

    public var protocols: Protocols
    /// "any", a BSD interface name ("en0") or one of the Mac's IPv4 addresses.
    public var interface: String
    public var holdOnLoss: Loss
    public var lossTimeout: TimeInterval
    public var priorityMode: PriorityMode
    /// The universe of the other transport (used when `protocols` is not the id's own).
    public var pair: UniverseID

    /// The defaults: the id's own transport on every interface, hold after 2.5 s, highest sACN priority wins.
    public init(for id: UniverseID) {
        protocols = id.transport == .artnet ? .artnet : .sacn
        interface = Self.anyInterface
        holdOnLoss = .hold
        lossTimeout = Self.defaultLossTimeout
        priorityMode = .highest
        pair = Self.defaultPair(of: id)
    }

    /// The other transport's universe by the default mapping sACN n ↔ Art-Net port-address n − 1 (S 1 ↔ A 0.0.0).
    public static func defaultPair(of id: UniverseID) -> UniverseID {
        switch id.transport {
        case .artnet: UniverseID(.sacn, min(id.number + 1, SACN.maxUniverse))
        case .sacn: UniverseID(.artnet, min(max(id.number - 1, 0), 0x7FFF))
        }
    }

    public func listens(to transport: UniverseID.Transport) -> Bool { protocols == .both || protocols.rawValue == transport.rawValue }

    /// The universe on the wire that feeds `id` over `transport`.
    public func wire(of id: UniverseID, over transport: UniverseID.Transport) -> UniverseID { transport == id.transport ? id : pair }

    /// Wire universe numbers to listen on for `ids` over `transport`, per interface asked for (sACN joins, ArtPollReply).
    public static func wire(_ ids: [UniverseID], over transport: UniverseID.Transport, settings: [UniverseID: UniverseSettings]) -> [String: [Int]] {
        var result: [String: Set<Int>] = [:]
        for id in ids {
            let s = settings[id] ?? UniverseSettings(for: id)
            if s.listens(to: transport) { result[s.interface, default: []].insert(s.wire(of: id, over: transport).number) }
        }
        return result.mapValues { $0.sorted() }
    }

    /// "any", an IPv4 address, or a BSD name: lowercase letters then digits ("en0", "bridge100", "lo0").
    public static func isValidInterface(_ text: String) -> Bool {
        if text == anyInterface || IPv4Subnet.parse(text) != nil { return true }
        let letters = text.prefix { $0.isASCII && $0.isLowercase }
        let digits = text.dropFirst(letters.count)
        return !letters.isEmpty && !digits.isEmpty && digits.count <= 4 && digits.allSatisfy { $0.isASCII && $0.isNumber } && text.count <= 15
    }

    /// The subnets of the interface `interface` names (by BSD name or one of its addresses): nil for "any" (every
    /// source), empty when no such interface is present (no source).
    /// ponytail: "arrived on the interface" is approximated by "sender is in the interface's subnet"; a routed console
    /// on another subnet is rejected. Per-packet receive interfaces (IP_RECVIF) if that is ever needed.
    public func subnets(in interfaces: [NetworkInterface]) -> [IPv4Subnet]? {
        guard interface != Self.anyInterface else { return nil }
        let names = Set(interfaces.filter { $0.name == interface || $0.address == interface }.map(\.name))
        return interfaces.filter { names.contains($0.name) }.compactMap { IPv4Subnet(address: $0.address, netmask: $0.netmask) }
    }
}

/// One IPv4 address of a network interface (getifaddrs).
public struct NetworkInterface: Equatable, Sendable {
    public var name: String
    public var address: String
    public var netmask: String
    /// IFF_MULTICAST and not loopback: where "any" joins sACN multicast.
    public var multicast: Bool
    /// IFF_BROADCAST: has a subnet broadcast address (the sync sender, DESIGN.md §23.2).
    public var broadcast: Bool
    /// IFF_LOOPBACK.
    public var loopback: Bool
    public init(name: String, address: String, netmask: String, multicast: Bool = false, broadcast: Bool = false, loopback: Bool = false) {
        self.name = name
        self.address = address
        self.netmask = netmask
        self.multicast = multicast
        self.broadcast = broadcast
        self.loopback = loopback
    }
}

public struct IPv4Subnet: Equatable, Sendable {
    public var network: UInt32
    public var mask: UInt32

    public init?(address: String, netmask: String) {
        guard let address = Self.parse(address), let mask = Self.parse(netmask) else { return nil }
        self.network = address & mask
        self.mask = mask
    }

    /// A sender host as Network.framework prints it ("10.0.0.5", "::ffff:10.0.0.5", "10.0.0.5%en0").
    public func contains(_ host: String) -> Bool {
        guard let address = Self.parse(host) else { return false }
        return address & mask == network
    }

    /// Dotted quad → host-order integer; an IPv4-mapped IPv6 prefix and a %scope suffix are ignored.
    public static func parse(_ text: String) -> UInt32? {
        var text = Substring(text)
        if text.hasPrefix("::ffff:") { text = text.dropFirst(7) }
        if let percent = text.firstIndex(of: "%") { text = text[..<percent] }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }), let byte = UInt8(part) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }
}
