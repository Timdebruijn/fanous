// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// OSC feedback (B36, DESIGN.md §15.3): query and subscribe/notify over a flat map of readable addresses.
/// The engine builds the map (`OSCFeedback.State`); this file decides what goes to whom.
public enum OSCFeedbackRequest: Equatable, Sendable {
    /// `/fanous/get` (prefix nil: the engine summary) or `/fanous/<path>/get`; `port` = reply to the sender's host on
    /// that port (only once the sender confirmed a subscription there).
    case get(prefix: String?, port: UInt16?)
    /// Step one: answered with `/fanous/subscribe/confirm <cookie>` to host:port; nothing streams before the ack.
    case subscribe(host: String, port: UInt16, prefix: String)
    /// Step two: `/fanous/subscribe/ack <cookie>` from the same host.
    case ack(cookie: String)
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
        "/fanous/engine/fps", "/fanous/engine/missed",
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
        case prefix + "/subscribe/ack":
            guard case .string(let cookie)? = args.first, !cookie.isEmpty else { return nil }
            return .ack(cookie: cookie)
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
    public static func path(_ argument: OSCArgument?) -> String? {
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

    /// The feedback addresses of a fixture in channel-map order, a layer's `media` last; built once and cached.
    public static func addresses(for fixture: FixtureRef) -> [String] {
        var addresses = ChannelMap.specs(for: fixture.mode).map { OSCAddressMap.address(fixture, $0.id) }
        if case .layer(let n) = fixture { addresses.append("\(prefix)/layer/\(n)/media") }
        return addresses
    }

    /// Parameter values in the units OSC sets them with: float 0…1 of the raw range (a layer also gets `media ii`).
    /// `addresses` is `addresses(for: fixture)`, passed in so a tick builds no strings.
    public static func parameterValues(
        _ fixture: FixtureRef, raw: [UInt16], addresses: [String]? = nil, into state: inout State
    ) {
        let addresses = addresses ?? self.addresses(for: fixture)
        let specs = ChannelMap.specs(for: fixture.mode)
        var media: (folder: UInt16, file: UInt16) = (0, 0)
        for (i, (spec, value)) in zip(specs, raw).enumerated() {
            state[addresses[i]] = [.float32(Float(Double(value) / Double(spec.rawMax)))]
            if spec.id == .layer(.folder) { media.folder = value }
            if spec.id == .layer(.file) { media.file = value }
        }
        if case .layer = fixture, addresses.count > specs.count {
            state[addresses[specs.count]] = [.int32(Int32(media.folder)), .int32(Int32(media.file))]
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

/// Token buckets per source host plus one for all hosts together, so spoofed requests cannot turn feedback into a
/// reflector: 10 requests a second per host (burst 20), 200 in all (burst 400).
public struct OSCRateLimiter: Sendable {
    struct Bucket: Sendable {
        var tokens: Double
        var at: Double
    }

    public static let perHost = (rate: 10.0, burst: 20.0)
    public static let total = (rate: 200.0, burst: 400.0)
    /// Hosts remembered at most; a full bucket carries no information and is dropped first.
    static let maxHosts = 1024

    private var hosts: [String: Bucket] = [:]
    private var all = Bucket(tokens: total.burst, at: 0)

    public init() {}

    public mutating func allow(_ host: String, now: Double) -> Bool {
        var bucket = hosts[host] ?? Bucket(tokens: Self.perHost.burst, at: now)
        Self.refill(&bucket, now: now, rate: Self.perHost.rate, burst: Self.perHost.burst)
        Self.refill(&all, now: now, rate: Self.total.rate, burst: Self.total.burst)
        guard bucket.tokens >= 1, all.tokens >= 1 else {
            if hosts[host] != nil { hosts[host] = bucket }  // a denied stranger is not remembered
            return false
        }
        bucket.tokens -= 1
        all.tokens -= 1
        if hosts[host] == nil, hosts.count >= Self.maxHosts { prune(now: now) }
        hosts[host] = bucket
        return true
    }

    private mutating func prune(now: Double) {
        hosts = hosts.filter { _, b in b.tokens + (now - b.at) * Self.perHost.rate < Self.perHost.burst }
        // ponytail: under a spoofed flood from more than 1024 hosts every bucket is busy; forgetting them all is safe
        // because the shared bucket still caps the total
        if hosts.count >= Self.maxHosts { hosts = [:] }
    }

    static func refill(_ bucket: inout Bucket, now: Double, rate: Double, burst: Double) {
        bucket.tokens = min(burst, bucket.tokens + max(0, now - bucket.at) * rate)
        bucket.at = now
    }
}

/// Subscribers keyed by host:port, each with its prefixes and what it was last sent. A new subscription is pending
/// until its cookie comes back (`confirm`): pending ones take no slot and are gone after 5 s. Changes are diffed per
/// tick (the engine ticks every 50 ms), so every address reaches a subscriber at most 20 times a second, latest value
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

    public enum SubscribeResult: Equatable, Sendable {
        /// Already confirmed: renewed (and the prefix added).
        case renewed
        /// Send the cookie to the key; streaming starts with the ack.
        case pending(cookie: String)
        /// All slots taken, or too many prefixes.
        case full
    }

    struct Subscriber: Sendable {
        var prefixes: Set<String>
        /// nil: the fixed target, never expires.
        var expires: Double?
        var sent: OSCFeedback.State = [:]
        var cursor = 0
    }

    struct Pending: Sendable {
        var key: Key
        var prefix: String
        var expires: Double
    }

    public static let lifetime: Double = 60
    public static let pendingLifetime: Double = 5
    public static let limit = 16
    public static let maxPending = 64
    public static let maxPrefixes = 8
    public static let maxMessagesPerTick = 200

    private(set) var subscribers: [Key: Subscriber] = [:]
    /// Keyed by cookie.
    private(set) var pending: [String: Pending] = [:]

    /// A fixed target whose prefix is not under `/fanous` is left out (the engine logs it).
    public init(fixed: OSCFeedbackTarget? = nil) {
        if let fixed, let prefix = OSCFeedback.path(fixed.prefix.map { .string($0) }) {
            subscribers[Key(host: fixed.host, port: fixed.port)] = Subscriber(prefixes: [prefix], expires: nil)
        }
    }

    /// Confirmed subscribers (the fixed target included): what the notify tick serves.
    public var isEmpty: Bool { subscribers.isEmpty }
    public var keys: [Key] { Array(subscribers.keys) }
    public func isConfirmed(_ key: Key) -> Bool { subscribers[key] != nil }

    /// A confirmed key is renewed at once; a new one gets `cookie` and waits for `confirm`.
    public mutating func subscribe(_ key: Key, prefix: String, cookie: String, now: Double) -> SubscribeResult {
        if var s = subscribers[key] {
            guard s.prefixes.contains(prefix) || s.prefixes.count < Self.maxPrefixes else { return .full }
            // a new prefix starts with a full sync
            if s.prefixes.insert(prefix).inserted {
                s.sent = s.sent.filter { a, _ in !OSCFeedback.matches(a, prefix: prefix) }
            }
            if s.expires != nil { s.expires = now + Self.lifetime }
            subscribers[key] = s
            return .renewed
        }
        pending = pending.filter { $0.value.expires > now }
        guard confirmedCount < Self.limit, pending.count < Self.maxPending else { return .full }
        pending[cookie] = Pending(key: key, prefix: prefix, expires: now + Self.pendingLifetime)
        return .pending(cookie: cookie)
    }

    /// The ack: the pending subscription with this cookie from this host becomes a subscriber. nil when the cookie is
    /// unknown, expired, from another host, or every slot was taken meanwhile.
    public mutating func confirm(host: String, cookie: String, now: Double) -> Key? {
        guard let p = pending[cookie], p.key.host == host else { return nil }
        pending[cookie] = nil
        guard p.expires > now else { return nil }
        if subscribers[p.key] != nil {
            return subscribe(p.key, prefix: p.prefix, cookie: cookie, now: now) == .renewed ? p.key : nil
        }
        guard confirmedCount < Self.limit else { return nil }
        subscribers[p.key] = Subscriber(prefixes: [p.prefix], expires: now + Self.lifetime)
        return p.key
    }

    private var confirmedCount: Int { subscribers.values.filter { $0.expires != nil }.count }

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

    /// `/fanous/ping`: every confirmed subscription of the host lives another 60 s.
    public mutating func renew(host: String, now: Double) {
        for (key, s) in subscribers where key.host == host && s.expires != nil {
            subscribers[key]?.expires = now + Self.lifetime
        }
    }

    /// Drops expired subscribers (and pending ones) and returns the subscribers (their connections can go).
    public mutating func expire(now: Double) -> [Key] {
        pending = pending.filter { $0.value.expires > now }
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
    /// ponytail: diffs the whole state per subscriber per tick (≈ 1 300 addresses at 32 layers); keep a change list
    /// if it shows in a profile.
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
