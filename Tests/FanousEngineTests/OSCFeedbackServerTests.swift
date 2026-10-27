// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Network
import Synchronization
import Testing

@testable import FanousEngine

/// Query and subscribe/notify over loopback, on random ports (never 8000: an engine may be running).
@Suite(.serialized) struct OSCFeedbackServerTests {
    final class StateBox: Sendable {
        let state = Mutex<OSCFeedback.State>([:])
    }

    /// A controller: a UDP socket on 127.0.0.1 with a port of its own.
    struct Client {
        let fd: Int32
        let port: UInt16

        init() throws {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            self.fd = fd
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            let bound = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            try #require(bound == 0)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            port = UInt16(bigEndian: address.sin_port)
        }

        func close() { _ = Darwin.close(fd) }

        func send(_ message: OSCMessage, to port: UInt16) {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            let bytes = message.encoded()
            _ = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        /// The next datagram, or nil after the timeout.
        func receive(timeout: Double = 2) -> OSCPacket? {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1e6))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let n = recv(fd, &buffer, buffer.count, 0)
            return n > 0 ? try? OSCPacket.parse(Array(buffer[0..<n])) : nil
        }

        /// Messages from bundles and plain messages received within the window.
        func messages(for seconds: Double) -> [OSCMessage] {
            var out: [OSCMessage] = []
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, let packet = receive(timeout: max(0.01, end.timeIntervalSinceNow)) {
                out += Self.flatten(packet)
            }
            return out
        }

        static func flatten(_ packet: OSCPacket) -> [OSCMessage] {
            switch packet {
            case .message(let m): [m]
            case .bundle(let b): b.elements.flatMap(flatten)
            }
        }
    }

    /// A random port that is free for UDP and TCP right now; another one when it is taken (EADDRINUSE).
    static func freePort() throws -> UInt16 {
        for _ in 0..<20 {
            let port = UInt16.random(in: 40_000..<60_000)
            let free = [SOCK_DGRAM, SOCK_STREAM].allSatisfy { type in
                let fd = socket(AF_INET, type, 0)
                defer { _ = Darwin.close(fd) }
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                return withUnsafePointer(to: &address) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                } == 0
            }
            if free { return port }
        }
        throw POSIXError(.EADDRINUSE)
    }

    static func start(
        store: DMXStore, fixed: OSCFeedbackTarget? = nil, state: @escaping @Sendable () -> OSCFeedback.State = { [:] },
        fixtures: @escaping @Sendable () -> [FixtureRef: [UInt16]] = { [:] }
    ) async throws -> (OSCReceiver, OSCFeedbackServer, UInt16) {
        let logger = Logger(label: "test")
        let feedback = OSCFeedbackServer(fixed: fixed, logger: logger, fixtures: fixtures, engine: state)
        let port = try freePort()
        let receiver = OSCReceiver(store: store, logger: logger, port: port, feedback: feedback)
        try receiver.start()
        feedback.start()
        try await Task.sleep(for: .milliseconds(300))
        return (receiver, feedback, port)
    }

    /// Subscribe step one; returns the cookie from `/fanous/subscribe/confirm`, which arrives at `listener`.
    static func subscribe(_ sender: Client, listener: Client, prefix: String, to port: UInt16) throws -> String {
        sender.send(
            OSCMessage("/fanous/subscribe", [.string("127.0.0.1"), .int32(Int32(listener.port)), .string(prefix)]),
            to: port)
        let confirm = listener.messages(for: 0.3)
        try #require(confirm.count == 1 && confirm[0].address == "/fanous/subscribe/confirm")
        guard case .string(let cookie)? = confirm[0].arguments.first else { throw POSIXError(.EPROTO) }
        return cookie
    }

    /// A value set over OSC is read back with `/get`, as a bundle to the sender's own port, in the units it was set in.
    @Test func queryAnswersTheSender() async throws {
        let store = DMXStore(patch: .standard(layers: 2, outputs: 1), logger: Logger(label: "test"))
        for n in 1...2 { store.setPolicy(.internal, for: .layer(n)) }  // OSC values win, as with a project set to internal
        let (receiver, feedback, port) = try await Self.start(store: store, fixtures: { store.resolvedRaw() })
        defer {
            receiver.stop()
            feedback.stop()
        }
        let client = try Client()
        defer { client.close() }

        client.send(OSCMessage("/fanous/layer/1/intensity", [.float32(0.5)]), to: port)
        client.send(OSCMessage("/fanous/layer/1/intensity/get"), to: port)
        let packet = try #require(client.receive())
        guard case .bundle(let bundle) = packet else {
            Issue.record("expected a bundle, got \(packet)")
            return
        }
        #expect(bundle.timetag == OSCPacket.immediately)
        // 0.5 lands on raw 32768 of 65535; the reply is that raw value as a fraction (sending it back sets the same raw)
        #expect(Client.flatten(packet) == [OSCMessage("/fanous/layer/1/intensity", [.float32(Float(32768.0 / 65535))])])

        // a whole layer, media included
        client.send(OSCMessage("/fanous/layer/2/media", [.int32(3), .int32(7)]), to: port)
        try await Task.sleep(for: .milliseconds(50))  // answers come from a state at most half a tick (25 ms) old
        client.send(OSCMessage("/fanous/layer/2/get"), to: port)
        let layer = client.messages(for: 0.5)
        #expect(layer.contains(OSCMessage("/fanous/layer/2/media", [.int32(3), .int32(7)])))
        #expect(layer.count == ChannelMap.specs(for: .layer).count + 1)
        #expect(layer.allSatisfy { $0.address.hasPrefix("/fanous/layer/2/") })

        // ping → pong
        client.send(OSCMessage("/fanous/ping"), to: port)
        #expect(client.messages(for: 0.3) == [OSCMessage("/fanous/pong")])

        // a port nobody confirmed: the answer still goes to the sender, never to that port
        let other = try Client()
        defer { other.close() }
        client.send(OSCMessage("/fanous/layer/1/intensity/get", [.int32(Int32(other.port))]), to: port)
        #expect(client.messages(for: 0.3).map(\.address) == ["/fanous/layer/1/intensity"])
        #expect(other.messages(for: 0.1).isEmpty)

        // a burst of 40 requests from one host: the bucket answers about 20 of them
        for _ in 0..<40 { client.send(OSCMessage("/fanous/ping"), to: port) }
        let pongs = client.messages(for: 0.5).count
        #expect(pongs >= 15 && pongs <= 25)
    }

    /// Subscribe: a full sync, then only changes, coalesced to one message per address per 50 ms tick; unsubscribe stops it.
    @Test func subscribersGetCoalescedChanges() async throws {
        let box = StateBox()
        box.state.withLock {
            $0 = [
                "/fanous/cue/current": [.float32(1)], "/fanous/cue/count": [.int32(4)],
                "/fanous/show/mode": [.int32(0)],
            ]
        }
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Logger(label: "test"))
        let (receiver, feedback, port) = try await Self.start(store: store) { box.state.withLock { $0 } }
        defer {
            receiver.stop()
            feedback.stop()
        }
        let client = try Client()
        defer { client.close() }

        // step one gets only the cookie; values stream after the ack
        let cookie = try Self.subscribe(client, listener: client, prefix: "/fanous/cue", to: port)
        client.send(OSCMessage("/fanous/subscribe/ack", [.string(cookie)]), to: port)
        let sync = client.messages(for: 0.3)
        #expect(Set(sync.map(\.address)) == ["/fanous/cue/current", "/fanous/cue/count"])

        // 300 changes in about 0.6 s: at most one message per tick, and the last value arrives
        let started = Date()
        let writer = Task.detached {
            for v in 1...300 {
                box.state.withLock { $0["/fanous/cue/current"] = [.float32(Float(v))] }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        var flood = client.messages(for: 0.5)
        await writer.value
        flood += client.messages(for: 0.3)
        flood = flood.filter { $0.address == "/fanous/cue/current" }
        #expect(flood.count >= 2)
        #expect(flood.count <= Int(Date().timeIntervalSince(started) / OSCFeedbackServer.tick) + 2)
        #expect(flood.last == OSCMessage("/fanous/cue/current", [.float32(300)]))

        // invalidate (every cue go) re-sends an unchanged value
        feedback.invalidate(prefix: "/fanous/cue")
        #expect(Set(client.messages(for: 0.3).map(\.address)) == ["/fanous/cue/current", "/fanous/cue/count"])

        client.send(OSCMessage("/fanous/unsubscribe"), to: port)
        try await Task.sleep(for: .milliseconds(100))
        box.state.withLock { $0["/fanous/cue/count"] = [.int32(5)] }
        #expect(client.messages(for: 0.3).isEmpty)
    }

    /// Feedback never goes to a third party: a subscribe naming another host is refused with an error to the sender.
    @Test func subscribeForAnotherHostIsRefused() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Logger(label: "test"))
        let (receiver, feedback, port) = try await Self.start(store: store) { ["/fanous/show/mode": [.int32(1)]] }
        defer {
            receiver.stop()
            feedback.stop()
        }
        let client = try Client()
        defer { client.close() }
        client.send(OSCMessage("/fanous/subscribe", [.string("10.1.2.3"), .int32(Int32(client.port))]), to: port)
        let replies = client.messages(for: 0.4)
        #expect(replies.map(\.address) == ["/fanous/error"])
    }

    /// The fixed target from settings.json gets notifications without subscribing; once it sends from that port,
    /// its own flow carries them and a query is answered once, not twice.
    @Test func fixedTargetIsNotifiedWithoutSubscribing() async throws {
        let box = StateBox()
        box.state.withLock { $0 = ["/fanous/show/mode": [.int32(0)]] }
        let client = try Client()
        defer { client.close() }
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Logger(label: "test"))
        let (receiver, feedback, port) = try await Self.start(
            store: store, fixed: OSCFeedbackTarget(host: "127.0.0.1", port: client.port)
        ) {
            box.state.withLock { $0 }
        }
        defer {
            receiver.stop()
            feedback.stop()
        }
        #expect(client.messages(for: 0.3) == [OSCMessage("/fanous/show/mode", [.int32(0)])])
        client.send(OSCMessage("/fanous/show/mode/get"), to: port)
        #expect(client.messages(for: 0.3) == [OSCMessage("/fanous/show/mode", [.int32(0)])])
        box.state.withLock { $0["/fanous/show/mode"] = [.int32(1)] }
        #expect(client.messages(for: 0.3) == [OSCMessage("/fanous/show/mode", [.int32(1)])])
    }

    /// Companion style: commands from one port, feedback to another. The cookie goes to the feedback port; the ack
    /// comes from the same host; only then does that port get values, and a `get` naming it is answered there.
    @Test func subscriptionToAnotherPortNeedsTheAck() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Logger(label: "test"))
        let (receiver, feedback, port) = try await Self.start(store: store) { ["/fanous/show/mode": [.int32(1)]] }
        defer {
            receiver.stop()
            feedback.stop()
        }
        let sender = try Client()
        let listener = try Client()
        defer {
            sender.close()
            listener.close()
        }
        let cookie = try Self.subscribe(sender, listener: listener, prefix: "/fanous", to: port)
        #expect(sender.messages(for: 0.1).isEmpty)
        #expect(listener.messages(for: 0.2).isEmpty)  // nothing before the ack
        sender.send(OSCMessage("/fanous/subscribe/ack", [.string("wrong")]), to: port)
        #expect(sender.messages(for: 0.3).map(\.address) == ["/fanous/error"])
        sender.send(OSCMessage("/fanous/subscribe/ack", [.string(cookie)]), to: port)
        #expect(listener.messages(for: 0.3) == [OSCMessage("/fanous/show/mode", [.int32(1)])])
        sender.send(OSCMessage("/fanous/show/mode/get", [.int32(Int32(listener.port))]), to: port)
        #expect(listener.messages(for: 0.3) == [OSCMessage("/fanous/show/mode", [.int32(1)])])
        #expect(sender.messages(for: 0.1).isEmpty)
    }

    /// Link-local IPv6 senders keep their scope for the connection back; the host a request names is compared without it.
    @Test func scopedHostsKeepTheirScope() {
        #expect("\(NWEndpoint.Host("fe80::1%lo0"))".hasSuffix("%lo0"))
        #expect(OSCFeedbackServer.sameHost("fe80::1", "fe80::1%lo0"))
        #expect(OSCFeedbackServer.sameHost("localhost", "127.0.0.1"))
        #expect(!OSCFeedbackServer.sameHost("10.0.0.5", "10.0.0.6"))
    }

    /// A missing or broken field never drops the others: the role passwords survive a typo in `oscFeedback`.
    @Test func settingsDecodeFieldByField() throws {
        let record = #"{"salt": "AAAA", "hash": "AAAA", "iterations": 1000}"#
        var json =
            #"{"passwords": {"programmer": \#(record)}, "oscFeedback": {"host": "10.0.0.5", "port": 9000, "prefix": "/fanous/cue"}}"#
        var settings = try JSONDecoder().decode(MachineSettings.self, from: Data(json.utf8))
        #expect(settings.oscFeedback == OSCFeedbackTarget(host: "10.0.0.5", port: 9000, prefix: "/fanous/cue"))
        #expect(settings.passwords["programmer"]?.iterations == 1000 && settings.problems.isEmpty)

        json =
            #"{"passwords": {"programmer": \#(record)}, "oscFeedback": {"host": "10.0.0.5", "port": "nine thousand"}}"#
        settings = try JSONDecoder().decode(MachineSettings.self, from: Data(json.utf8))
        #expect(settings.passwords["programmer"]?.iterations == 1000)
        #expect(settings.oscFeedback == nil && settings.problems.count == 1)

        json = #"{"oscFeedback": {"host": "10.0.0.5", "port": 9000}}"#
        settings = try JSONDecoder().decode(MachineSettings.self, from: Data(json.utf8))
        #expect(settings.passwords.isEmpty && settings.oscFeedback?.port == 9000 && settings.problems.isEmpty)

        // what is written back carries no problems list
        let written = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!written.contains("problems"))
    }
}
