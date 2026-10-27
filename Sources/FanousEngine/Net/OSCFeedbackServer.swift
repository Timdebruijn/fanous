// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Network
import QuartzCore

/// Where an OSC packet came from and how to answer on the same flow (UDP datagram back to host:port, or SLIP on TCP).
/// `host` keeps an IPv6 scope (`fe80::1%en0`), so a connection to it leaves on the right interface.
struct OSCSource: Sendable {
    var host: String
    var port: UInt16
    var reply: @Sendable ([UInt8]) -> Void
}

/// OSC feedback (B36): answers `get` queries and notifies confirmed subscribers of changed values every 50 ms.
/// Feedback only goes to the requesting host, to a host:port that confirmed a subscription with its cookie, or to the
/// fixed target from settings.json. Requests are rate-limited per host (`OSCRateLimiter`).
public final class OSCFeedbackServer: @unchecked Sendable {
    static let tick: Double = 0.05
    private let queue = DispatchQueue(label: "org.fanous.osc-feedback", qos: .utility)
    private let fixtures: @Sendable () -> [FixtureRef: [UInt16]]
    private let engine: @Sendable () -> OSCFeedback.State
    private let fixed: OSCFeedbackTarget?
    private let logger: Logger
    // queue only
    private var started = false
    private var table: OSCSubscriptions
    private var limiter = OSCRateLimiter()
    private var connections: [OSCSubscriptions.Key: NWConnection] = [:]
    /// Subscribers that listen on the port they send from (TouchOSC, the fixed target sending commands): answered on
    /// their inbound flow, from port 8000. An outbound connection to the same host:port fails with EADDRINUSE.
    private var flows: [OSCSubscriptions.Key: @Sendable ([UInt8]) -> Void] = [:]
    private var timer: DispatchSourceTimer?
    private var addresses: [FixtureRef: [String]] = [:]
    private var cache: (state: OSCFeedback.State, at: Double)?

    /// - Parameters:
    ///   - fixtures: resolved raw values per fixture, copied under the DMX lock and nothing more; called on the feedback queue.
    ///   - engine: the other readable addresses (cues, show, timecode, outputs, engine) from cheap cached copies.
    public init(
        fixed: OSCFeedbackTarget?, logger: Logger, fixtures: @escaping @Sendable () -> [FixtureRef: [UInt16]],
        engine: @escaping @Sendable () -> OSCFeedback.State
    ) {
        self.fixed = fixed
        self.logger = logger
        self.fixtures = fixtures
        self.engine = engine
        table = OSCSubscriptions(fixed: fixed)
        if let fixed, OSCFeedback.path(fixed.prefix.map { .string($0) }) == nil {
            logger.warning(
                "OSC feedback target ignored: its prefix is not under /fanous",
                metadata: ["prefix": "\(fixed.prefix ?? "")"])
        }
    }

    /// Notifications start here (the engine calls it at the end of its start); queries are answered before.
    public func start() {
        queue.async { [self] in
            started = true
            updateTimer()
        }
    }

    func handle(_ request: OSCFeedbackRequest, from source: OSCSource) {
        queue.async { [self] in
            let now = CACurrentMediaTime()
            guard limiter.allow(Self.unscoped(source.host), now: now) else { return }
            switch request {
            case .get(let prefix, let port):
                // to the sender; to another port of its host only once that port confirmed a subscription
                var target = OSCSubscriptions.Key(host: source.host, port: source.port)
                if let port, table.isConfirmed(.init(host: source.host, port: port)) { target.port = port }
                let fixedKey = fixed.map { OSCSubscriptions.Key(host: $0.host, port: $0.port) }
                let packets = OSCFeedback.bundles(OSCFeedback.query(prefix, in: state(now: now))).map { $0.encoded() }
                for bytes in packets {
                    if target.port == source.port { source.reply(bytes) } else { send(bytes, to: target) }
                    if let fixedKey, fixedKey != target { send(bytes, to: fixedKey) }
                }
            case .subscribe(let host, let port, let prefix):
                // only to the sender itself: a subscribe must not turn Fanous into a sender towards a third party
                guard Self.sameHost(host, source.host) else {
                    logger.warning(
                        "OSC subscribe refused: host is not the sender",
                        metadata: ["host": "\(host)", "sender": "\(source.host)"])
                    source.reply(
                        Self.error("subscribe: host must be the sender's address \(Self.unscoped(source.host))"))
                    return
                }
                let key = OSCSubscriptions.Key(host: source.host, port: port)
                let cookie = String(UInt64.random(in: 1...UInt64.max), radix: 16)
                switch table.subscribe(key, prefix: prefix, cookie: cookie, now: now) {
                case .renewed:
                    if port == source.port { useFlow(source) }
                case .pending(let cookie):
                    // step two is the ack from that host: a spoofed subscribe never reaches the confirmed table
                    let confirm = OSCMessage("/fanous/subscribe/confirm", [.string(cookie)]).encoded()
                    if port == source.port { source.reply(confirm) } else { sendOnce([confirm], to: key) }
                case .full:
                    logger.warning("OSC subscribe refused: too many subscribers", metadata: ["sender": "\(key)"])
                    source.reply(Self.error("subscribe: \(OSCSubscriptions.limit) subscribers at most"))
                }
            case .ack(let cookie):
                guard let key = table.confirm(host: source.host, cookie: cookie, now: now) else {
                    source.reply(Self.error("subscribe/ack: unknown or expired cookie, or no free subscription"))
                    return
                }
                if key.port == source.port { useFlow(source) }
                logger.info("OSC feedback subscriber", metadata: ["subscriber": "\(key)"])
            case .unsubscribe(let host, let port, let prefix):
                guard host.map({ Self.sameHost($0, source.host) }) ?? true else { return }
                table.unsubscribe(host: source.host, port: port, prefix: prefix)
                dropUnused()
            case .ping:
                table.renew(host: source.host, now: now)
                if table.isConfirmed(.init(host: source.host, port: source.port)) { useFlow(source) }
                source.reply(OSCMessage("/fanous/pong").encoded())
            }
            updateTimer()
        }
    }

    /// Every new inbound UDP flow: the fixed target's own one becomes the way to reach it.
    func adopt(_ source: OSCSource) {
        guard let fixed, fixed.port == source.port, Self.sameHost(fixed.host, source.host) else { return }
        queue.async { [self] in useFlow(source, as: .init(host: fixed.host, port: fixed.port)) }
    }

    /// Everything at or below the prefix goes out again at the next tick, changed or not (every cue go).
    public func invalidate(prefix: String) {
        queue.async { [self] in table.invalidate(prefix: prefix) }
    }

    public func stop() {
        queue.sync {
            started = false
            timer?.cancel()
            timer = nil
            for connection in connections.values { connection.cancel() }
            connections = [:]
        }
    }

    // MARK: queue

    /// The readable state, built at most once per half tick: notifications and every `get` in between share it.
    private func state(now: Double) -> OSCFeedback.State {
        if let cache, now - cache.at < Self.tick / 2 { return cache.state }
        var state = engine()
        for (fixture, raw) in fixtures() {
            let list = addresses[fixture] ?? OSCFeedback.addresses(for: fixture)
            addresses[fixture] = list
            OSCFeedback.parameterValues(fixture, raw: raw, addresses: list, into: &state)
        }
        cache = (state, now)
        return state
    }

    /// The tick runs only while someone confirmed (or the fixed target) is listening.
    private func updateTimer() {
        if !started || table.isEmpty {
            timer?.cancel()
            timer = nil
        } else if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.tick, repeating: Self.tick, leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.notify() }
            timer.resume()
            self.timer = timer
        }
    }

    private func notify() {
        let now = CACurrentMediaTime()
        if !table.expire(now: now).isEmpty {
            dropUnused()
            updateTimer()
        }
        guard !table.isEmpty else { return }
        for (key, messages) in table.changes(in: state(now: now)) {
            for bundle in OSCFeedback.bundles(messages) { send(bundle.encoded(), to: key) }
        }
    }

    private func useFlow(_ source: OSCSource, as key: OSCSubscriptions.Key? = nil) {
        let key = key ?? OSCSubscriptions.Key(host: source.host, port: source.port)
        flows[key] = source.reply
        connections.removeValue(forKey: key)?.cancel()
    }

    private func send(_ bytes: [UInt8], to key: OSCSubscriptions.Key) {
        if let flow = flows[key] { return flow(bytes) }
        let connection: NWConnection
        if let existing = connections[key] {
            connection = existing
        } else {
            guard let port = NWEndpoint.Port(rawValue: key.port) else { return }
            connection = NWConnection(host: NWEndpoint.Host(key.host), port: port, using: .udp)
            connection.start(queue: queue)
            connections[key] = connection
        }
        connection.send(content: Data(bytes), completion: .idempotent)
    }

    /// One connection for the whole answer, cancelled after its last datagram.
    private func sendOnce(_ packets: [[UInt8]], to key: OSCSubscriptions.Key) {
        if flows[key] != nil || connections[key] != nil { return packets.forEach { send($0, to: key) } }
        guard let port = NWEndpoint.Port(rawValue: key.port), !packets.isEmpty else { return }
        let connection = NWConnection(host: NWEndpoint.Host(key.host), port: port, using: .udp)
        connection.start(queue: queue)
        for bytes in packets.dropLast() { connection.send(content: Data(bytes), completion: .idempotent) }
        connection.send(content: Data(packets.last!), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Connections and flows of keys that are no longer subscribed.
    private func dropUnused() {
        let live = Set(table.keys)
        for (key, connection) in connections where !live.contains(key) {
            connection.cancel()
            connections[key] = nil
        }
        flows = flows.filter { live.contains($0.key) }
    }

    static func error(_ text: String) -> [UInt8] { OSCMessage("/fanous/error", [.string(text)]).encoded() }

    static func unscoped(_ host: String) -> String { host.split(separator: "%").first.map(String.init) ?? host }

    /// A host named in a request against the sender's address: the scope does not matter, `localhost` is loopback.
    static func sameHost(_ named: String, _ sender: String) -> Bool {
        let sender = unscoped(sender)
        return unscoped(named) == sender || (named == "localhost" && (sender == "127.0.0.1" || sender == "::1"))
    }
}
