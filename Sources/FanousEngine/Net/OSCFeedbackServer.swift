// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Network
import QuartzCore

/// Where an OSC packet came from and how to answer on the same flow (UDP datagram back to host:port, or SLIP on TCP).
struct OSCSource: Sendable {
    var host: String
    var port: UInt16
    var reply: @Sendable ([UInt8]) -> Void
}

/// OSC feedback (B36): answers `get` queries and notifies subscribers of changed values every 50 ms.
/// Feedback only goes to the requesting host (any port it names) or to the fixed target from settings.json.
public final class OSCFeedbackServer: @unchecked Sendable {
    static let tick: Double = 0.05
    private let queue = DispatchQueue(label: "org.fanous.osc-feedback", qos: .utility)
    private let state: @Sendable () -> OSCFeedback.State
    private let fixed: OSCFeedbackTarget?
    private let logger: Logger
    // queue only
    private var table: OSCSubscriptions
    private var connections: [OSCSubscriptions.Key: NWConnection] = [:]
    /// Subscribers that listen on the port they send from (TouchOSC, the fixed target sending commands): answered on
    /// their inbound flow, from port 8000. An outbound connection to the same host:port fails with EADDRINUSE.
    private var flows: [OSCSubscriptions.Key: @Sendable ([UInt8]) -> Void] = [:]
    private var timer: DispatchSourceTimer?

    /// - Parameter state: every readable address and its current value; called on the feedback queue.
    public init(fixed: OSCFeedbackTarget?, logger: Logger, state: @escaping @Sendable () -> OSCFeedback.State) {
        self.fixed = fixed
        self.logger = logger
        self.state = state
        table = OSCSubscriptions(fixed: fixed)
        queue.async { [self] in updateTimer() }
    }

    func handle(_ request: OSCFeedbackRequest, from source: OSCSource) {
        queue.async { [self] in
            let now = CACurrentMediaTime()
            switch request {
            case .get(let prefix, let port):
                // to the sender (or the port it names on its host), and to the fixed target unless that is the same place
                let target = OSCSubscriptions.Key(host: source.host, port: port ?? source.port)
                let fixedKey = fixed.map { OSCSubscriptions.Key(host: $0.host, port: $0.port) }
                for bundle in OSCFeedback.bundles(OSCFeedback.query(prefix, in: state())) {
                    let bytes = bundle.encoded()
                    if target.port != source.port { sendOnce(bytes, to: target) } else { source.reply(bytes) }
                    if let fixedKey, fixedKey != target { send(bytes, to: fixedKey) }
                }
            case .subscribe(let host, let port, let prefix):
                // only to the sender itself: a subscribe must not turn Fanous into a sender towards a third party
                guard host == source.host || (host == "localhost" && Self.isLoopback(source.host)) else {
                    logger.warning(
                        "OSC subscribe refused: host is not the sender",
                        metadata: ["host": "\(host)", "sender": "\(source.host)"])
                    source.reply(
                        OSCMessage(
                            "/fanous/error", [.string("subscribe: host must be the sender's address \(source.host)")]
                        ).encoded())
                    return
                }
                guard table.subscribe(.init(host: source.host, port: port), prefix: prefix, now: now) else {
                    logger.warning(
                        "OSC subscribe refused: too many subscribers", metadata: ["sender": "\(source.host):\(port)"])
                    source.reply(
                        OSCMessage(
                            "/fanous/error", [.string("subscribe: \(OSCSubscriptions.limit) subscribers at most")]
                        ).encoded())
                    return
                }
                if port == source.port { useFlow(source) }
            case .unsubscribe(let host, let port, let prefix):
                guard host == nil || host == source.host || (host == "localhost" && Self.isLoopback(source.host)) else {
                    return
                }
                table.unsubscribe(host: source.host, port: port, prefix: prefix)
                dropUnused()
            case .ping:
                table.renew(host: source.host, now: now)
                if table.keys.contains(.init(host: source.host, port: source.port)) { useFlow(source) }
                source.reply(OSCMessage("/fanous/pong").encoded())
            }
            updateTimer()
        }
    }

    /// Every new inbound UDP flow: the fixed target's own one becomes the way to reach it.
    func adopt(_ source: OSCSource) {
        guard let fixed, fixed.host == source.host, fixed.port == source.port else { return }
        queue.async { [self] in useFlow(source) }
    }

    /// Everything at or below the prefix goes out again at the next tick, changed or not (every cue go).
    public func invalidate(prefix: String) {
        queue.async { [self] in table.invalidate(prefix: prefix) }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            for connection in connections.values { connection.cancel() }
            connections = [:]
        }
    }

    // MARK: queue

    private func updateTimer() {
        if table.isEmpty {
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
        if !table.expire(now: CACurrentMediaTime()).isEmpty {
            dropUnused()
            updateTimer()
        }
        guard !table.isEmpty else { return }
        for (key, messages) in table.changes(in: state()) {
            for bundle in OSCFeedback.bundles(messages) { send(bundle.encoded(), to: key) }
        }
    }

    private func useFlow(_ source: OSCSource) {
        let key = OSCSubscriptions.Key(host: source.host, port: source.port)
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

    private func sendOnce(_ bytes: [UInt8], to key: OSCSubscriptions.Key) {
        if let flow = flows[key] { return flow(bytes) }
        if let existing = connections[key] { return existing.send(content: Data(bytes), completion: .idempotent) }
        guard let port = NWEndpoint.Port(rawValue: key.port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(key.host), port: port, using: .udp)
        connection.start(queue: queue)
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Connections of keys that are no longer subscribed.
    private func dropUnused() {
        let live = Set(table.keys)
        for (key, connection) in connections where !live.contains(key) {
            connection.cancel()
            connections[key] = nil
        }
        flows = flows.filter { live.contains($0.key) }
    }

    static func isLoopback(_ host: String) -> Bool { host == "127.0.0.1" || host == "::1" }
}
