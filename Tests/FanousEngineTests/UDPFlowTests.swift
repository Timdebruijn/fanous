// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Network
import Synchronization
import Testing

@testable import FanousEngine

/// B268: the UDP receivers keep one `NWConnection`, and one descriptor, per source address and port. Silent flows are
/// cancelled and their number is capped, so senders that come and go cannot use up the process's open-file limit.
/// Descriptors are counted from the kernel: the sockets of this process bound to the receiver's port (its listener's
/// and one per live flow), which other tests running at the same time do not touch.
@Suite(.serialized) struct UDPFlowTests {
    final class Seen: Sendable { let list = Mutex<[Double]>([]) }

    /// Sockets of this process whose local port is `port`.
    static func sockets(on port: UInt16) -> Int {
        let pid = getpid()
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)) / stride + 64)
        let used = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))) / stride
        return fds.prefix(used).filter { fd in
            guard fd.proc_fdtype == PROX_FDTYPE_SOCKET else { return false }
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size)) > 0 else { return false }
            return UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_in.insi_lport)) == port
        }.count
    }

    /// An OSC receiver on a kernel-picked port that records every `cue/goto` in arrival order, with the flow rules
    /// given; returns it with its store, its port and the listener's own socket count.
    static func osc(idle: Double = UDPFlows.idle, floor: Double = UDPFlows.floor, cap: Int = UDPFlows.cap) async throws -> (OSCReceiver, DMXStore, UInt16, Int, Seen) {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        let seen = Seen()
        store.onCommand = { if case .cueGoto(let n) = $0 { seen.list.withLock { $0.append(n) } } }
        let receiver = OSCReceiver(store: store, logger: testLogger, port: 0)
        receiver.flows.idle = UInt64(idle * 1e9)
        receiver.flows.floor = UInt64(floor * 1e9)
        receiver.flows.cap = cap
        try receiver.start()
        let port = try await listeningPort { receiver.boundUDPPort }
        let listener = sockets(on: port)
        // listening once a goto 0 arrives; its flows (one per try) go with the others
        #expect(await waitUntil(every: .milliseconds(50)) {
            sendUDP(OSCMessage("/fanous/cue/goto", [.float32(0)]).encoded(), to: port)
            return seen.list.withLock { $0.contains(0) }
        })
        return (receiver, store, port, listener, seen)
    }

    static func goto(_ n: Int) -> [UInt8] { OSCMessage("/fanous/cue/goto", [.float32(Float(n))]).encoded() }

    /// 200 senders that each send one datagram from a port of their own (an OSC app that rebinds its socket): no flow
    /// and no descriptor of theirs is left once they have been silent for the idle time.
    @Test func silentOSCFlowsAreReleased() async throws {
        let (receiver, _, port, listener, seen) = try await Self.osc(idle: 3)
        defer { receiver.stop() }
        for n in 1...200 { sendUDP(Self.goto(n), to: port) }
        #expect(await waitUntil { seen.list.withLock { Set($0).isSuperset(of: (1...200).map(Double.init)) } })
        #expect(await waitUntil { Self.sockets(on: port) == listener }, "\(Self.sockets(on: port) - listener) flow sockets left")
    }

    /// A burst of 300 new source ports against a cap of 16 loses nothing: every sender has just delivered (inside the
    /// floor), so none may go and the table runs over the cap. Measured before the floor (cap 16, 5 runs): 274 to 290
    /// flows adopted, every one of them read, 280 to 287 datagrams arrived (as many as flows), so the datagrams that
    /// came out of a flow not their own were lost when that flow had gone for the cap; without a cap all 300 arrived.
    @Test func aBurstOfNewPortsLosesNothing() async throws {
        let (receiver, store, port, _, seen) = try await Self.osc(cap: 16)
        defer { receiver.stop() }
        seen.list.withLock { $0 = [] }
        for n in 1...300 { sendUDP(Self.goto(n), to: port) }
        let all = Set((1...300).map(Double.init))
        #expect(await waitUntil { seen.list.withLock { all.isSubset(of: $0) } }, "\(seen.list.withLock { all.intersection($0).count }) of 300 read")
        #expect(store.queue.sync { receiver.flows.flows.count } > 16)
    }

    /// The cap's rule on the table itself (unstarted connections, times set back): over the cap the flow silent longest
    /// goes, only among flows silent for at least the floor; with none left the table runs over; a pinned flow stays.
    @Test func capDropsTheFlowSilentLongestOutsideTheFloor() {
        let queue = DispatchQueue(label: "test.flows")
        let flows = UDPFlows(queue: queue, logger: testLogger, name: "test")
        flows.cap = 3
        defer { flows.stop() }
        let second: UInt64 = 1_000_000_000
        func flow(_ port: UInt16, pinned: Bool = false, silent seconds: UInt64 = 0) -> UDPFlows.Flow {
            let flow = flows.adopt(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp), pinned: pinned)
            flows.touch(flow)
            flow.lastSeen -= seconds * second
            return flow
        }
        queue.sync {
            let pinned = flow(1, pinned: true, silent: 3600)
            let a = flow(2, silent: 10)
            let b = flow(3, silent: 20)
            #expect(flows.flows.count == 3)
            let c = flow(4)  // over the cap: b goes (silent longest; the pinned one never)
            #expect(flows.flows.map(ObjectIdentifier.init) == [pinned, a, c].map(ObjectIdentifier.init))
            let d = flow(5)  // then a
            #expect(flows.flows.map(ObjectIdentifier.init) == [pinned, c, d].map(ObjectIdentifier.init))
            _ = b
            let e = flow(6)  // c, d and e inside the floor: nothing may go, the table runs over
            #expect(flows.flows.map(ObjectIdentifier.init) == [pinned, c, d, e].map(ObjectIdentifier.init))
        }
    }

    /// A console on one socket keeps its flow while others are swept around it: it sends one datagram, 50 senders send
    /// one each and fall silent, then the console sends 299 more 10 ms apart. With a flow idle after 2 s (a sweep every
    /// 0.5 s) the 50 are swept in the middle of the stream; every datagram of the console arrives in the order sent, on
    /// the flow it had at the start.
    @Test func aSenderThatKeepsSendingKeepsItsFlow() async throws {
        let (receiver, store, port, listener, seen) = try await Self.osc(idle: 2)
        defer { receiver.stop() }
        #expect(await waitUntil { Self.sockets(on: port) == listener })  // the probe's flows are gone
        seen.list.withLock { $0 = [] }
        let console = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(console) }
        func send(_ n: Int) {
            let bytes = Self.goto(n)
            _ = withSockaddr(port: port, host: "127.0.0.1") { sendto(console, bytes, bytes.count, 0, $0, $1) }
        }
        send(1)
        #expect(await waitUntil { seen.list.withLock { $0.count } == 1 })
        let consolePort = try #require(UDPSend.localPort(console))
        let flow = try #require(store.queue.sync {
            receiver.flows.flows.first { if case .hostPort(_, let p) = $0.connection.endpoint { p.rawValue == consolePort } else { false } }
        })
        for n in 1...50 { sendUDP(Self.goto(10_000 + n), to: port) }  // the silent ones
        for n in 2...300 {
            send(n)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await waitUntil { seen.list.withLock { $0.contains(300) } })
        #expect(seen.list.withLock { $0.filter { $0 < 10_000 } } == (1...300).map(Double.init))
        #expect(await waitUntil { Self.sockets(on: port) - listener == 1 }, "\(Self.sockets(on: port) - listener) flow sockets left")
        #expect(store.queue.sync { receiver.flows.flows.count == 1 && receiver.flows.flows[0] === flow }, "the console's flow was replaced")
    }

    /// `stop()` closes the listener and every flow: no socket on the port is left.
    @Test func stopClosesEveryFlow() async throws {
        let (receiver, _, port, listener, seen) = try await Self.osc()
        for n in 1...20 { sendUDP(Self.goto(n), to: port) }
        #expect(await waitUntil { seen.list.withLock { Set($0).count } >= 20 })
        #expect(Self.sockets(on: port) > listener)
        receiver.stop()
        #expect(await waitUntil { Self.sockets(on: port) == 0 }, "\(Self.sockets(on: port)) sockets left after stop")
    }

    /// Art-Net has the same flows: 100 senders of one ArtDmx frame each from ports of their own leave no flow once the
    /// idle time has passed (only the end state is asserted: a slow machine may sweep some before a count sees them). (Not ArtPoll: the reply to a socket that is closed already ends the flow with a receive error.)
    @Test func silentArtNetFlowsAreReleased() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        let receiver = ArtNetReceiver(store: store, logger: testLogger, nodeName: "test", port: 0)
        receiver.flows.idle = 3_000_000_000
        try receiver.start()
        defer { receiver.stop() }
        let port = try await listeningPort { receiver.boundPort }
        let listener = Self.sockets(on: port)
        #expect(await waitUntil { sendUDP([ArtPoll().encoded()], to: port, reply: 0.1).replied })
        for _ in 1...100 { sendUDP(UniverseSettingsEngineTests.artnet(255), to: port) }
        #expect(await waitUntil { store.queue.sync { receiver.flows.flows.count } >= 1 })
        #expect(await waitUntil { Self.sockets(on: port) == listener }, "\(Self.sockets(on: port) - listener) flow sockets left")
    }

    /// The Art-Net receiver keeps to its cap: 100 senders against a cap of 16 with no floor settle at 16 flows.
    @Test func artNetFlowsKeepToTheCap() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        let receiver = ArtNetReceiver(store: store, logger: testLogger, nodeName: "test", port: 0)
        receiver.flows.cap = 16
        receiver.flows.floor = 0
        try receiver.start()
        defer { receiver.stop() }
        let port = try await listeningPort { receiver.boundPort }
        let listener = Self.sockets(on: port)
        #expect(await waitUntil { sendUDP([ArtPoll().encoded()], to: port, reply: 0.1).replied })
        for _ in 1...100 { sendUDP(UniverseSettingsEngineTests.artnet(255), to: port) }
        // both settle once every flow is read; the kernel count can pass 16 on its way down before the table does
        #expect(
            await waitUntil { store.queue.sync { receiver.flows.flows.count } == 16 && Self.sockets(on: port) - listener == 16 },
            "\(store.queue.sync { receiver.flows.flows.count }) flows, \(Self.sockets(on: port) - listener) flow sockets with a cap of 16")
    }

    /// The fixed feedback target sends from the port it listens on, so its own flow carries its feedback (from port
    /// 8000). That flow is kept however long the target is silent: once it is cancelled, a connection of our own to
    /// the same host:port fails with EADDRINUSE and the target would get nothing more.
    @Test func fixedTargetKeepsItsFlowWhenSilent() async throws {
        let box = OSCFeedbackServerTests.StateBox()
        box.state.withLock { $0 = ["/fanous/show/mode": [.int32(0)]] }
        let client = try OSCFeedbackServerTests.Client()
        defer { client.close() }
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        let (receiver, feedback, port) = try await OSCFeedbackServerTests.start(
            store: store, fixed: OSCFeedbackTarget(host: "127.0.0.1", port: client.port), flowIdle: 0.2
        ) {
            box.state.withLock { $0 }
        }
        defer {
            receiver.stop()
            feedback.stop()
        }
        #expect(client.messages(for: 0.3) == [OSCMessage("/fanous/show/mode", [.int32(0)])])
        client.send(OSCMessage("/fanous/show/mode/get"), to: port)  // from now on its own flow carries its feedback
        #expect(client.messages(for: 0.3) == [OSCMessage("/fanous/show/mode", [.int32(0)])])
        // the probe's flows go; the target's stays
        #expect(await waitUntil { store.queue.sync { receiver.flows.flows.count } == 1 })
        try await Task.sleep(for: .milliseconds(500))  // silent for more than two idle times, about ten sweeps
        #expect(store.queue.sync { receiver.flows.flows.count } == 1)
        box.state.withLock { $0["/fanous/show/mode"] = [.int32(1)] }
        #expect(client.messages(for: 0.3) == [OSCMessage("/fanous/show/mode", [.int32(1)])])
    }

    /// A subscriber that listens on the port it sends from (P) and is renewed from another port of its host (Q): P's
    /// flow is pinned while the subscription lives, so feedback keeps arriving however long P is silent. Once the
    /// subscription is gone (here unsubscribed from Q; expiry takes the same path) the flow is an ordinary one again
    /// and is swept after the idle time.
    @Test func silentSubscriberKeepsItsFlowWhileSubscribed() async throws {
        let box = OSCFeedbackServerTests.StateBox()
        box.state.withLock { $0 = ["/fanous/cue/current": [.float32(1)]] }
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        // idle 1.5 s: longer than subscribe plus ack take (about 0.6 s), so the handshake itself is never swept
        let (receiver, feedback, port) = try await OSCFeedbackServerTests.start(store: store, flowIdle: 1.5) { box.state.withLock { $0 } }
        defer {
            receiver.stop()
            feedback.stop()
        }
        let p = try OSCFeedbackServerTests.Client()
        defer { p.close() }
        let q = try OSCFeedbackServerTests.Client()
        defer { q.close() }
        let cookie = try OSCFeedbackServerTests.subscribe(p, listener: p, prefix: "/fanous/cue", to: port)
        p.send(OSCMessage("/fanous/subscribe/ack", [.string(cookie)]), to: port)
        #expect(p.messages(for: 0.3).map(\.address) == ["/fanous/cue/current"])
        let key = OSCSubscriptions.Key(host: "127.0.0.1", port: p.port)
        #expect(await waitUntil { store.queue.sync { receiver.flows.pinnedKeys == [key] } })

        func flowOf(_ client: OSCFeedbackServerTests.Client) -> Bool {
            store.queue.sync {
                receiver.flows.flows.contains { if case .hostPort(_, let port) = $0.connection.endpoint { port.rawValue == client.port } else { false } }
            }
        }
        q.send(OSCMessage("/fanous/ping"), to: port)  // the host renews from Q
        #expect(q.messages(for: 0.3) == [OSCMessage("/fanous/pong")])
        try await Task.sleep(for: .seconds(4))  // P silent for more than two idle times, about ten sweeps
        #expect(flowOf(p))
        box.state.withLock { $0["/fanous/cue/current"] = [.float32(2)] }
        #expect(p.messages(for: 0.3) == [OSCMessage("/fanous/cue/current", [.float32(2)])])

        q.send(OSCMessage("/fanous/unsubscribe", [.string("127.0.0.1"), .int32(Int32(p.port))]), to: port)
        #expect(await waitUntil { store.queue.sync { receiver.flows.pinnedKeys.isEmpty } })
        #expect(await waitUntil { !flowOf(p) }, "the flow stayed after the subscription went")
    }

    /// Pins are bounded by the subscription table: 20 controllers ask, 16 (`OSCSubscriptions.limit`) are confirmed and
    /// pinned, the rest are refused and pin nothing.
    @Test func pinsStayWithinTheSubscriptionLimit() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        let (receiver, feedback, port) = try await OSCFeedbackServerTests.start(store: store) { [:] }
        defer {
            receiver.stop()
            feedback.stop()
        }
        let clients = try (0..<20).map { _ in try OSCFeedbackServerTests.Client() }
        defer { for c in clients { c.close() } }
        for c in clients {
            // 10 requests a second per host at most (OSCRateLimiter): two per controller, paced
            c.send(OSCMessage("/fanous/subscribe", [.string("127.0.0.1"), .int32(Int32(c.port)), .string("/fanous/cue")]), to: port)
            if let reply = c.messages(for: 0.05, first: 1).first, reply.address == "/fanous/subscribe/confirm", case .string(let cookie)? = reply.arguments.first {
                try await Task.sleep(for: .milliseconds(120))
                c.send(OSCMessage("/fanous/subscribe/ack", [.string(cookie)]), to: port)
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        #expect(await waitUntil { store.queue.sync { receiver.flows.pinnedKeys.count } == OSCSubscriptions.limit })
        #expect(store.queue.sync { receiver.flows.pinnedKeys.count } == OSCSubscriptions.limit)
    }
}
