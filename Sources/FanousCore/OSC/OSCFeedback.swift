// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// OSC feedback (B36, DESIGN.md §15.3): query and subscribe/notify over a flat map of readable addresses.
/// The engine builds the map (`OSCFeedback.State`); this file decides what goes to whom.
public enum OSCFeedbackRequest: Equatable, Sendable {
    /// `/fanous/get` (prefix nil: the engine summary) or `/fanous/<path>/get`; `port` = reply to the sender's host on that port.
    case get(prefix: String?, port: UInt16?)
    case subscribe(host: String, port: UInt16, prefix: String)
    /// No arguments: every subscription of the sender's host.
    case unsubscribe(host: String?, port: UInt16?, prefix: String?)
    case ping
}

/// A fixed feedback target from settings.json, for controllers that cannot subscribe.
public struct OSCFeedbackTarget: Codable, Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var prefix: String?

    public init(host: String, port: UInt16, prefix: String? = nil) {
        self.host = host
        self.port = port
        self.prefix = prefix
    }
}

public enum OSCFeedback {
    public typealias State = [String: [OSCArgument]]

    static let prefix = OSCAddressMap.prefix
    /// `/fanous/get` with no path: what a controller shows on its status page.
    public static let summaryAddresses = [
        "/fanous/engine/version", "/fanous/show/mode", "/fanous/show/lock", "/fanous/show/ready", "/fanous/cue/current",
        "/fanous/engine/fps",
        "/fanous/engine/missed",
    ]
    /// One query answers at most this many addresses (a spoofed UDP query must not turn into a flood); ask per layer.
    public static let maxQueryMessages = 256
    /// Bundles stay under one Ethernet frame, so no IP fragmentation.
    public static let maxBundleBytes = 1200

    /// nil when the message is not a feedback request (it may still be a command).
    public static func request(for message: OSCMessage) -> OSCFeedbackRequest? {
        let address = message.address
        let args = message.arguments
        switch address {
        case prefix + "/get":
            return .get(prefix: nil, port: port(args.first))
        case prefix + "/ping":
            return .ping
        case prefix + "/subscribe":
            guard args.count >= 2, case .string(let host) = args[0], let port = port(args[1]) else { return nil }
            guard let path = path(args.count > 2 ? args[2] : nil) else { return nil }
            return .subscribe(host: host, port: port, prefix: path)
        case prefix + "/unsubscribe":
            var host: String?
            if case .string(let h)? = args.first { host = h }
            let path = args.count > 2 ? self.path(args[2]) : nil
            return .unsubscribe(host: host, port: args.count > 1 ? port(args[1]) : nil, prefix: path)
        default:
            guard address.hasPrefix(prefix + "/"), address.hasSuffix("/get") else { return nil }
            return .get(prefix: String(address.dropLast(4)), port: port(args.first))
        }
    }

    /// A subscription prefix: `/fanous` or below; a trailing slash is dropped.
    static func path(_ argument: OSCArgument?) -> String? {
        guard let argument else { return prefix }
        guard case .string(var s) = argument else { return nil }
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s == prefix || s.hasPrefix(prefix + "/") ? s : nil
    }

    static func port(_ argument: OSCArgument?) -> UInt16? {
        guard let d = argument?.asDouble, d.isFinite, d >= 1, d <= 65535 else { return nil }
        return UInt16(d)
    }

    public static func matches(_ address: String, prefix: String) -> Bool {
        address == prefix || address.hasPrefix(prefix + "/")
    }

    /// The reply to a `get`: the summary, or every address at or below the prefix (sorted, capped).
    public static func query(_ prefix: String?, in state: State) -> [OSCMessage] {
        guard let prefix else { return summaryAddresses.compactMap { a in state[a].map { OSCMessage(a, $0) } } }
        return state.keys.filter { matches($0, prefix: prefix) }.sorted().prefix(maxQueryMessages).map {
            OSCMessage($0, state[$0]!)
        }
    }

    /// Parameter values in the units OSC sets them with: float 0…1 of the raw range (a layer also gets `media ii`).
    public static func parameterValues(_ fixture: FixtureRef, raw: [UInt16], into state: inout State) {
        let specs = ChannelMap.specs(for: fixture.mode)
        var media: (folder: UInt16, file: UInt16) = (0, 0)
        for (spec, value) in zip(specs, raw) {
            state[OSCAddressMap.address(fixture, spec.id)] = [.float32(Float(Double(value) / Double(spec.rawMax)))]
            if spec.id == .layer(.folder) { media.folder = value }
            if spec.id == .layer(.file) { media.file = value }
        }
        if case .layer(let n) = fixture {
            state["\(prefix)/layer/\(n)/media"] = [.int32(Int32(media.folder)), .int32(Int32(media.file))]
        }
    }

    /// Greedy packing into bundles of at most `maxBytes` (a single bigger message goes alone). Timetag "immediately":
    /// the values are current when sent, and a real timestamp would be delayed by a receiver whose clock runs behind.
    public static func bundles(_ messages: [OSCMessage], maxBytes: Int = maxBundleBytes) -> [OSCBundle] {
        var bundles: [OSCBundle] = []
        var current: [OSCPacket] = []
        var size = 16  // "#bundle\0" + timetag
        for message in messages {
            let bytes = message.encoded().count + 4
            if !current.isEmpty, size + bytes > maxBytes {
                bundles.append(OSCBundle(elements: current))
                current = []
                size = 16
            }
            current.append(.message(message))
            size += bytes
        }
        if !current.isEmpty { bundles.append(OSCBundle(elements: current)) }
        return bundles
    }
}

/// Subscribers keyed by host:port, each with its prefixes and what it was last sent. Changes are diffed per tick
/// (the engine ticks every 50 ms), so every address reaches a subscriber at most 20 times a second, latest value
/// wins, and a flooding desk costs at most `maxMessagesPerTick` messages per subscriber per tick.
public struct OSCSubscriptions: Sendable {
    public struct Key: Hashable, Sendable, CustomStringConvertible {
        public var host: String
        public var port: UInt16
        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
        public var description: String { "\(host):\(port)" }
    }

    struct Subscriber: Sendable {
        var prefixes: Set<String>
        /// nil: the fixed target, never expires.
        var expires: Double?
        var sent: OSCFeedback.State = [:]
        var cursor = 0
    }

    public static let lifetime: Double = 60
    public static let limit = 16
    public static let maxPrefixes = 8
    public static let maxMessagesPerTick = 200

    private(set) var subscribers: [Key: Subscriber] = [:]

    public init(fixed: OSCFeedbackTarget? = nil) {
        if let fixed {
            subscribers[Key(host: fixed.host, port: fixed.port)] = Subscriber(
                prefixes: [OSCFeedback.path(fixed.prefix.map { .string($0) }) ?? OSCFeedback.prefix], expires: nil)
        }
    }

    public var isEmpty: Bool { subscribers.isEmpty }
    public var keys: [Key] { Array(subscribers.keys) }

    /// false when the table is full (or the subscriber has too many prefixes); renews an existing subscription.
    public mutating func subscribe(_ key: Key, prefix: String, now: Double) -> Bool {
        if var s = subscribers[key] {
            guard s.prefixes.contains(prefix) || s.prefixes.count < Self.maxPrefixes else { return false }
            // a new prefix starts with a full sync
            if s.prefixes.insert(prefix).inserted {
                s.sent = s.sent.filter { a, _ in !OSCFeedback.matches(a, prefix: prefix) }
            }
            if s.expires != nil { s.expires = now + Self.lifetime }
            subscribers[key] = s
            return true
        }
        guard subscribers.values.filter({ $0.expires != nil }).count < Self.limit else { return false }
        subscribers[key] = Subscriber(prefixes: [prefix], expires: now + Self.lifetime)
        return true
    }

    /// Port nil: every port of the host; prefix nil: the whole subscription. The fixed target stays.
    public mutating func unsubscribe(host: String, port: UInt16?, prefix: String?) {
        for (key, s) in subscribers where key.host == host && (port == nil || key.port == port) && s.expires != nil {
            if let prefix {
                subscribers[key]?.prefixes.remove(prefix)
                if subscribers[key]?.prefixes.isEmpty == true { subscribers[key] = nil }
            } else {
                subscribers[key] = nil
            }
        }
    }

    /// `/fanous/ping`: every subscription of the host lives another 60 s.
    public mutating func renew(host: String, now: Double) {
        for (key, s) in subscribers where key.host == host && s.expires != nil {
            subscribers[key]?.expires = now + Self.lifetime
        }
    }

    /// Drops expired subscribers and returns them (their connections can go).
    public mutating func expire(now: Double) -> [Key] {
        let gone = subscribers.filter { _, s in s.expires.map { $0 <= now } ?? false }.map(\.key)
        for key in gone { subscribers[key] = nil }
        return gone
    }

    /// Everything at or below the prefix is sent again at the next tick (a cue go with the same cue as before).
    public mutating func invalidate(prefix: String) {
        for (key, s) in subscribers {
            subscribers[key]?.sent = s.sent.filter { a, _ in !OSCFeedback.matches(a, prefix: prefix) }
        }
    }

    /// One tick: per subscriber, the addresses whose value differs from what it was last sent.
    /// ponytail: diffs the whole state per subscriber per tick (≈ 1 300 addresses at 32 layers); keep a change list if it shows in a profile.
    public mutating func changes(in state: OSCFeedback.State) -> [Key: [OSCMessage]] {
        var out: [Key: [OSCMessage]] = [:]
        for (key, var s) in subscribers {
            var changed = state.keys.filter { a in
                s.sent[a] != state[a] && s.prefixes.contains { OSCFeedback.matches(a, prefix: $0) }
            }.sorted()
            guard !changed.isEmpty else { continue }
            if changed.count > Self.maxMessagesPerTick {
                // rotate, so a flood does not starve the addresses late in the sort order; the rest go next tick
                let start = s.cursor % changed.count
                changed = Array((changed[start...] + changed[..<start]).prefix(Self.maxMessagesPerTick))
                s.cursor = start + Self.maxMessagesPerTick
            }
            for a in changed { s.sent[a] = state[a] }
            subscribers[key] = s
            out[key] = changed.map { OSCMessage($0, state[$0]!) }
        }
        return out
    }
}
