// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
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

    /// An OSC receiver on a kernel-picked port that records every `cue/goto` in arrival order, with flows silent for
    /// `idle` seconds cancelled and at most `cap` of them; returns it with its store, its port and the listener's own socket count.
    static func osc(idle: Double = UDPFlows.idle, cap: Int = UDPFlows.cap) async throws -> (OSCReceiver, DMXStore, UInt16, Int, Seen) {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        let seen = Seen()
        store.onCommand = { if case .cueGoto(let n) = $0 { seen.list.withLock { $0.append(n) } } }
        let receiver = OSCReceiver(store: store, logger: testLogger, port: 0)
        receiver.flows.idle = UInt64(idle * 1e9)
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

    /// 200 senders that each send one datagram from a port of their own (an OSC app that rebinds its socket): their
    /// flows hold 200 descriptors while they are new and none once they have been silent for the idle time.
    @Test func silentOSCFlowsAreReleased() async throws {
        let (receiver, _, port, listener, seen) = try await Self.osc(idle: 1)
        defer { receiver.stop() }
        for n in 1...200 { sendUDP(Self.goto(n), to: port) }
        #expect(await waitUntil { seen.list.withLock { Set($0).isSuperset(of: (1...200).map(Double.init)) } })
        let held = Self.sockets(on: port) - listener
        #expect(held >= 150, "\(held) flow sockets right after 200 senders")  // a few may already be swept on a slow run
        #expect(await waitUntil { Self.sockets(on: port) == listener }, "\(Self.sockets(on: port) - listener) flow sockets left")
    }

    /// A burst of 300 new source ports against a cap of 16: once the burst is read, 16 flows and 16 descriptors are
    /// left. During the burst the count runs higher: Network.framework sets a flow's socket up before it hands the
    /// flow over, and a flow is not dropped before its first datagram is read. A burst this far over the cap loses
    /// datagrams (measured: 268 to 292 of 300 read in 20 runs; all 300 in 6 runs without the cap), so only the cap is asserted.
    @Test func flowCapHoldsUnderABurstOfSourcePorts() async throws {
        let (receiver, store, port, listener, seen) = try await Self.osc(cap: 16)
        defer { receiver.stop() }
        seen.list.withLock { $0 = [] }
        var most = 0
        for n in 1...300 {
            sendUDP(Self.goto(n), to: port)
            if n % 10 == 0 { most = max(most, Self.sockets(on: port) - listener) }
        }
        #expect(await waitUntil { Self.sockets(on: port) - listener == 16 }, "\(Self.sockets(on: port) - listener) flow sockets with a cap of 16")
        #expect(store.queue.sync { receiver.flows.flows.count } == 16)
        print("UDP flow cap 16, burst of 300 source ports: at most \(most) flow sockets during it, \(seen.list.withLock { Set($0).count }) of 300 read")
    }

    /// A console on one socket keeps its flow while others are swept around it: it sends one datagram, 50 senders send
    /// one each and fall silent, then the console sends 199 more 10 ms apart. With a flow idle after 0.3 s (a sweep
    /// every 75 ms, about 25 during the run) the 50 are swept in the middle of the stream; every datagram of the
    /// console arrives in the order sent, on the flow it had at the start.
    @Test func aSenderThatKeepsSendingKeepsItsFlow() async throws {
        let (receiver, store, port, listener, seen) = try await Self.osc(idle: 0.3)
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
        for n in 2...200 {
            send(n)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await waitUntil { seen.list.withLock { $0.contains(200) } })
        #expect(seen.list.withLock { $0.filter { $0 < 10_000 } } == (1...200).map(Double.init))
        #expect(await waitUntil { Self.sockets(on: port) - listener == 1 }, "\(Self.sockets(on: port) - listener) flow sockets left")
        #expect(store.queue.sync { receiver.flows.flows.count == 1 && receiver.flows.flows[0] === flow }, "the console's flow was replaced")
    }

    /// Art-Net has the same flows: 100 senders of one ArtDmx frame each from ports of their own, released after the idle
    /// time. (Not ArtPoll: the reply to a socket that is closed already ends the flow with a receive error.)
    @Test func silentArtNetFlowsAreReleased() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        let receiver = ArtNetReceiver(store: store, logger: testLogger, nodeName: "test", port: 0)
        receiver.flows.idle = 1_000_000_000
        try receiver.start()
        defer { receiver.stop() }
        let port = try await listeningPort { receiver.boundPort }
        let listener = Self.sockets(on: port)
        #expect(await waitUntil { sendUDP([ArtPoll().encoded()], to: port, reply: 0.1).replied })
        for _ in 1...100 { sendUDP(UniverseSettingsEngineTests.artnet(255), to: port) }
        // >= 90: the kernel may hand a closed sender's port to the next one, which is then the same flow
        #expect(await waitUntil { Self.sockets(on: port) - listener >= 90 }, "\(Self.sockets(on: port) - listener) flow sockets")
        #expect(await waitUntil { Self.sockets(on: port) == listener }, "\(Self.sockets(on: port) - listener) flow sockets left")
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
}
