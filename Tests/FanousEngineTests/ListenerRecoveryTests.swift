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

/// B272: an `NWListener` that fails is made again on the same port, after a backoff that grows to a cap. The real
/// failure these tests cause is a port another socket holds exclusively at start (`.failed(EADDRINUSE)`, terminal: the
/// listener stays failed after the holder closes, measured). A ready listener that fails later (an interface gone, the
/// network stack restarting) could not be caused without changing system settings; that case is driven through
/// `RecoveringListener.stateChanged` with a `.failed` state. Backoffs are milliseconds here, 1 s to 5 s in the engine.
@Suite(.serialized) struct ListenerRecoveryTests {
    static let fast = (first: 0.01, max: 0.04)

    /// A UDP socket bound without SO_REUSEPORT on a port the kernel picks: a listener on that port fails.
    static func holdUDP() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        try #require(withSockaddr { bind(fd, $0, $1) } == 0)
        return (fd, try #require(UDPSend.localPort(fd)))
    }

    static func capture() -> (Logger, HTTPSServerLogTests.Lines) {
        let lines = HTTPSServerLogTests.Lines()
        return (Logger(label: "test") { _ in HTTPSServerLogTests.Capture(lines: lines) }, lines)
    }

    /// The Art-Net listener failed at start on a held port; once the holder lets go, it listens again on that port by
    /// itself and readiness turns green. On the old code the failure stayed until a restart: no reply ever came.
    @Test func aFailedArtNetListenerListensAgainOnItsPort() async throws {
        let holder = try Self.holdUDP()
        var held = true
        defer { if held { close(holder.fd) } }
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        let artnet = ArtNetReceiver(store: store, logger: testLogger, nodeName: "test", port: holder.port)
        artnet.listener.backoff = Self.fast
        try artnet.start()
        defer { artnet.stop() }
        #expect(await waitUntil { artnet.failure?.contains("Address already in use") == true })
        close(holder.fd)
        held = false
        let replied = try await offPool { (0..<100).contains { _ in sendUDP([ArtPoll().encoded()], to: holder.port, reply: 0.1).replied } }
        #expect(replied, "no ArtPollReply on \(holder.port)")
        #expect(await waitUntil { artnet.failure == nil })
        #expect(artnet.boundPort == holder.port)
    }

    /// The same for OSC: the UDP listener failed on a held port, readiness names it, and once the port is free a ping
    /// is answered on it.
    @Test func aFailedOSCListenerListensAgainAndReadinessShowsIt() async throws {
        let holder = try Self.holdUDP()
        var held = true
        defer { if held { close(holder.fd) } }
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        let feedback = OSCFeedbackServer(fixed: nil, logger: testLogger, fixtures: { [:] }, engine: { [:] })
        let osc = OSCReceiver(store: store, logger: testLogger, port: holder.port, feedback: feedback)
        osc.udp.backoff = Self.fast
        osc.tcp.backoff = Self.fast
        try osc.start()
        feedback.start()
        defer {
            osc.stop()
            feedback.stop()
        }
        #expect(await waitUntil { osc.failure?.hasPrefix("UDP: ") == true })
        var context = ReadinessContext()
        context.oscError = osc.failure
        let item = try #require(Readiness.check(context, acknowledged: []).first { $0.id == "oscport" })
        #expect(item.title == "OSC port 8000 available" && item.state == .warn && !item.blocks)
        #expect(item.detail.hasPrefix("not listening: UDP: ") && item.detail.contains("Address already in use, trying again"), "\(item.detail)")

        close(holder.fd)
        held = false
        let client = try OSCFeedbackServerTests.Client()
        defer { client.close() }
        #expect(await waitUntil { osc.failure == nil })
        let answered = try await offPool {
            for _ in 0..<50 {
                client.send(OSCMessage("/fanous/ping"), to: holder.port)
                if client.receive(timeout: 0.1) == OSCPacket.message(OSCMessage("/fanous/pong")) { return true }
            }
            return false
        }
        #expect(answered, "no pong on \(holder.port)")
    }

    /// Failures in a row wait 10, 20, 40, 40 … ms (at least: a timer never fires early) and log one line; once a listener
    /// was ready, the next failure logs again, also with the same text. `make` counts the attempts.
    @Test func repeatedFailuresBackOffAndLogOncePerChange() async throws {
        let holder = try Self.holdUDP()
        var held = true
        defer { if held { close(holder.fd) } }
        let (logger, lines) = Self.capture()
        let queue = DispatchQueue(label: "test.listener")
        let attempts = Mutex<[UInt64]>([])
        let keeper = RecoveringListener(name: "Test listener", queue: queue, logger: logger) {
            attempts.withLock { $0.append(DispatchTime.now().uptimeNanoseconds) }
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: holder.port)!)
            listener.newConnectionHandler = { $0.cancel() }
            return listener
        }
        keeper.backoff = (first: 0.01, max: 0.04)
        try keeper.start()
        defer { keeper.stop() }
        #expect(await waitUntil { attempts.withLock { $0.count } >= 6 })
        let times = attempts.withLock { $0 }
        for i in 1..<6 {
            let wanted = min(0.01 * pow(2, Double(i - 1)), 0.04)
            #expect(Double(times[i] - times[i - 1]) / 1e9 >= wanted * 0.95, "attempt \(i) came after \(Double(times[i] - times[i - 1]) / 1e6) ms")
        }
        let failedLines = { lines.all.withLock { $0.filter { $0.hasPrefix("Test listener failed; trying again") } } }
        #expect(failedLines().count == 1, "\(failedLines())")
        #expect(failedLines().first?.contains("Address already in use") == true)

        close(holder.fd)
        held = false
        #expect(await waitUntil { keeper.failure == nil && keeper.listener?.port?.rawValue == holder.port })
        // listening again: the next failure is a change and logs, also with the same error text as before
        let listener = try #require(keeper.listener)
        // read in the same block: the retry is 10 ms out and clears the failure once its listener is ready
        let failure = queue.sync {
            keeper.stateChanged(.failed(.posix(.ENETDOWN)), of: listener)
            return keeper.failure
        }
        #expect(failure == "\(NWError.posix(.ENETDOWN)), trying again")
        #expect(await waitUntil { keeper.failure == nil })
        #expect(failedLines().count == 2, "\(failedLines())")
    }

    /// `stop()` while a failed listener waits for its next attempt: no attempt follows, nothing holds the port.
    @Test func stopDuringTheBackoffMakesNoListener() async throws {
        let holder = try Self.holdUDP()
        var held = true
        defer { if held { close(holder.fd) } }
        let attempts = Mutex(0)
        let keeper = RecoveringListener(name: "Test listener", queue: DispatchQueue(label: "test.listener"), logger: testLogger) {
            attempts.withLock { $0 += 1 }
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: holder.port)!)
            listener.newConnectionHandler = { $0.cancel() }
            return listener
        }
        keeper.backoff = (first: 0.1, max: 0.1)
        try keeper.start()
        #expect(await waitUntil(every: .milliseconds(1)) { keeper.failure != nil })
        keeper.stop()
        close(holder.fd)
        held = false
        // a negative check needs a window: three backoffs, in which a live timer would have made a listener
        try await Task.sleep(for: .milliseconds(300))
        #expect(attempts.withLock { $0 } <= 2)  // the first, and one that may have begun before the stop
        #expect(keeper.listener == nil || keeper.listener?.state == .cancelled)
        #expect(await waitUntil { UDPFlowTests.sockets(on: holder.port) == 0 }, "\(UDPFlowTests.sockets(on: holder.port)) sockets on the port after stop")
    }

    /// A `.ready` that reaches the handler after `stop()` (an attempt that ran just before the stop) is not passed on:
    /// CITP would start its beacon and HTTPS register `_https._tcp` again with nothing left to cancel them. Only
    /// `.cancelled` passes. Driven through the handler: the order of a real retry and a stop cannot be forced.
    @Test func statesAfterStopReachOnlyCancelled() async throws {
        let picked = try Self.holdUDP()  // a free port, picked by the kernel
        close(picked.fd)
        let queue = DispatchQueue(label: "test.listener")
        let seen = Mutex<[String]>([])
        let keeper = RecoveringListener(name: "Test listener", queue: queue, logger: testLogger) {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: picked.port)!)
            listener.newConnectionHandler = { $0.cancel() }
            return listener
        } onState: { state, _ in
            seen.withLock { $0.append("\(state)") }
        }
        try keeper.start()
        #expect(await waitUntil { seen.withLock { $0.contains("ready") } })
        let listener = try #require(keeper.listener)
        queue.sync { keeper.stop() }  // from inside the queue, as CITP does: it only dispatches
        queue.sync { keeper.stateChanged(.ready, of: listener) }  // after the stop's block
        #expect(await waitUntil { seen.withLock { $0.last == "cancelled" } })
        #expect(seen.withLock { $0.filter { $0 == "ready" }.count } == 1, "\(seen.withLock { $0 })")
    }

    /// A subscribed controller across a failure of the OSC UDP listener after it was ready: the old listener's flows,
    /// the subscriber's among them, are cancelled; the new listener takes datagrams on the same port, and once the
    /// controller sends again its feedback comes from the OSC port, on its new flow.
    @Test func aSubscriberGetsFeedbackAgainAfterARecreate() async throws {
        let picked = try Self.holdUDP()  // a free port, picked by the kernel
        close(picked.fd)
        let port = picked.port
        let box = OSCFeedbackServerTests.StateBox()
        box.state.withLock { $0 = ["/fanous/cue/current": [.float32(1)]] }
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        let feedback = OSCFeedbackServer(fixed: nil, logger: testLogger, fixtures: { [:] }, engine: { box.state.withLock { $0 } })
        let osc = OSCReceiver(store: store, logger: testLogger, port: port, feedback: feedback)
        osc.udp.backoff = Self.fast
        try osc.start()
        feedback.start()
        defer {
            osc.stop()
            feedback.stop()
        }
        _ = try await listeningPort { osc.boundUDPPort }
        let p = try OSCFeedbackServerTests.Client()
        defer { p.close() }
        let cookie = try await offPool { try OSCFeedbackServerTests.subscribe(p, listener: p, prefix: "/fanous/cue", to: port) }
        p.send(OSCMessage("/fanous/subscribe/ack", [.string(cookie)]), to: port)
        #expect(try await offPool { p.messages(for: 0.3).map(\.address) } == ["/fanous/cue/current"])
        let key = OSCSubscriptions.Key(host: "127.0.0.1", port: p.port)
        #expect(await waitUntil { store.queue.sync { osc.flows.pinnedKeys == [key] && !osc.flows.flows.isEmpty } })

        let old = try #require(osc.udp.listener)
        store.queue.sync { osc.udp.stateChanged(.failed(.posix(.ENETDOWN)), of: old) }
        #expect(await waitUntil { store.queue.sync { osc.flows.flows.isEmpty } }, "flows of the failed listener left")
        #expect(await waitUntil { osc.failure == nil && osc.udp.listener !== old && osc.boundUDPPort == port })

        let (pong, from) = try await offPool { () -> (OSCPacket?, UInt16) in
            for _ in 0..<50 {
                p.send(OSCMessage("/fanous/ping"), to: port)
                if let reply = Self.receive(p, timeout: 0.1) { return reply }
            }
            return (nil, 0)
        }
        #expect(pong == .message(OSCMessage("/fanous/pong")) && from == port)
        box.state.withLock { $0["/fanous/cue/current"] = [.float32(2)] }
        let change = try await offPool { () -> (OSCPacket?, UInt16) in
            // the pongs of the probes before the first answered one may still come
            for _ in 0..<50 {
                let next = Self.receive(p, timeout: 0.1)
                if let next, next.0 != .message(OSCMessage("/fanous/pong")) { return next }
            }
            return (nil, 0)
        }
        #expect(change.0.map(OSCFeedbackServerTests.Client.flatten) == [OSCMessage("/fanous/cue/current", [.float32(2)])])
        #expect(change.1 == port, "feedback came from \(change.1), not from the OSC port \(port)")
    }

    /// The next datagram at `client` and the port it came from.
    static func receive(_ client: OSCFeedbackServerTests.Client, timeout: Double) -> (OSCPacket?, UInt16)? {
        setReceiveTimeout(client.fd, timeout)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { f in
            f.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(client.fd, &buffer, buffer.count, 0, $0, &length) }
        }
        guard n > 0 else { return nil }
        return (try? OSCPacket.parse(Array(buffer[0..<n])), UInt16(bigEndian: from.sin_port))
    }
}
