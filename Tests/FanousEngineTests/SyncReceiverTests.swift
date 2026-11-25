// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import QuartzCore
import Synchronization
import Testing

@testable import FanousEngine

/// Clock packets into the group table (DESIGN.md §23.2), over loopback with the network off.
@Suite(.serialized)
struct SyncReceiverTests {
    static let low = UUID(uuidString: "10000000-0000-0000-0000-000000000000")!
    static let high = UUID(uuidString: "F0000000-0000-0000-0000-000000000000")!
    static let own = UUID(uuidString: "80000000-0000-0000-0000-000000000000")!

    static func clock(group: UInt8, position: Double = 12.5) -> SyncPacket.Layer {
        SyncPacket.Layer(
            group: group, layer: 3, mediaKey: 0x0102, fps: 25, position: position, direction: 1, finished: false,
            rate: 25)
    }

    static func packet(from machine: UUID, tick: UInt32 = 1, _ layers: [SyncPacket.Layer]) -> [UInt8] {
        var bytes: [UInt8] = []
        SyncPacket(machineID: machine, tick: tick, sendTime: 0, layers: layers).encode(into: &bytes)
        return bytes
    }

    /// A receiver on 127.0.0.1, on a port the kernel picks.
    static func receiver() throws -> (SyncReceiver, UInt16) {
        let receiver = SyncReceiver(machine: own, logger: testLogger)
        return (receiver, try receiver.start(port: 0, loopbackOnly: true))
    }

    /// Waits until `group` has an entry (the queue handles datagrams in order, so everything sent before it is done).
    static func entry(_ receiver: SyncReceiver, group: Int) async throws -> SyncTable.Entry? {
        for _ in 0..<200 {
            if let entry = receiver.table.withLock({ $0.entries[group - 1] }) { return entry }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// B337, the receiver's call site (`startSync` and `sync.set` both bind through `start(port:network:)`): with
    /// `--no-network` the default port is not bound, another port is. Binds nothing on 8002 while the rule holds.
    @Test func noNetworkDoesNotListenOnTheDefaultPort() throws {
        let refused = SyncReceiver(machine: Self.own, logger: testLogger)
        #expect(try refused.start(port: SyncSettings.defaultPort, network: false) == false)
        #expect(!refused.listening)
        let other = SyncReceiver(machine: Self.own, logger: testLogger)
        defer { other.stop() }
        #expect(try other.start(port: 0, network: false))  // port 0: the kernel picks one
        #expect(other.listening)
    }

    @Test func aSendersClockArrives() async throws {
        let (receiver, port) = try Self.receiver()
        defer { receiver.stop() }
        var settings = SyncSettings()
        settings.target = "127.0.0.1:\(port)"
        let sender = SyncSender(
            machine: Self.low, settings: settings, network: false, logger: testLogger)
        sender.start()
        defer { sender.stop() }
        let before = CACurrentMediaTime()
        sender.slots.write { slot in
            slot.packet.tick = 9
            slot.packet.layers.append(Self.clock(group: 4))
        }
        sender.wake.signal()
        let entry = try #require(try await Self.entry(receiver, group: 4))
        #expect(entry.machine == Self.low)
        #expect(entry.clock == Self.clock(group: 4))
        #expect(entry.receivedAt >= before && entry.receivedAt <= CACurrentMediaTime())
        // not packetsIn == 1 (B101): a keepalive follows the data packet after 1 s, or precedes it when this test is held
        // up for 1 s between start and signal (`lastSent` is 0 and `CACurrentMediaTime` is uptime). It sets no entry.
        #expect(receiver.table.withLock { $0.entries.compactMap { $0 }.count } == 1, "only A's group 4 is in the table")
    }

    @Test func ownPacketsGarbageAndKeepalivesTouchNothing() async throws {
        let (receiver, port) = try Self.receiver()
        defer { receiver.stop() }
        let datagrams = [
            Self.packet(from: Self.own, [Self.clock(group: 1)]),
            Array("not a sync packet".utf8),
            Array("FSYN".utf8) + [9] + [UInt8](repeating: 0, count: 40),  // a version we do not speak
            Self.packet(from: Self.high, []),  // keepalive
            Self.packet(from: Self.low, [Self.clock(group: 2)]),
        ]
        #expect(sendUDP(datagrams, to: port).sent == datagrams.map(\.count))
        #expect(try await Self.entry(receiver, group: 2) != nil, "still receiving after the garbage")
        let table = receiver.table.withLock { $0 }
        #expect(table.entries[0] == nil, "our own id is dropped")
        #expect(table.entries.compactMap { $0 }.count == 1, "the keepalive set nothing")
        #expect(receiver.decodeErrors.load(ordering: .relaxed) == 2)
        #expect(receiver.packetsIn.load(ordering: .relaxed) == 2, "the keepalive and the clock; not our own")
    }

    @Test func theLowerMachineIdWinsAGroup() async throws {
        let (receiver, port) = try Self.receiver()
        defer { receiver.stop() }
        // one socket: one flow, read in order, as a console sends
        let datagrams = [
            Self.packet(from: Self.high, [Self.clock(group: 1, position: 1)]),
            Self.packet(from: Self.low, [Self.clock(group: 1, position: 2)]),
            Self.packet(from: Self.high, [Self.clock(group: 1, position: 3)]),
            Self.packet(from: Self.low, [Self.clock(group: 3)]),  // marks the end
        ]
        #expect(sendUDP(datagrams, to: port).sent == datagrams.map(\.count))
        _ = try #require(try await Self.entry(receiver, group: 3))
        let table = receiver.table.withLock { $0 }
        #expect(table.entries[0]?.machine == Self.low)
        #expect(table.entries[0]?.clock.position == 2, "the higher id's later packet is ignored")
        // asked at the conflict's own time: the hosted CI runner once stalled past the 2 s freewheel window between
        // receiving the packets and reading the table (2026-11-04), which made the conflict look expired
        let recorded = try #require(table.conflicts[0]?.at)
        #expect(table.conflict(group: 1, now: recorded) == Self.high)
        #expect(table.conflict(group: 3, now: recorded) == nil)
    }

    /// After the freewheel time without the winner, the other machine takes the group over.
    @Test func aStaleWinnerIsReplaced() {
        var table = SyncTable()
        table.offer(Self.clock(group: 5, position: 1), from: Self.low, at: 100)
        table.offer(Self.clock(group: 5, position: 2), from: Self.high, at: 101.9)
        #expect(table.entries[4]?.machine == Self.low)
        table.offer(Self.clock(group: 5, position: 3), from: Self.high, at: 102.1)
        #expect(table.entries[4]?.machine == Self.high)
        #expect(table.entries[4]?.clock.position == 3)
        #expect(table.conflict(group: 5, now: 102.1) == Self.high, "recorded at 101.9, still within the freewheel time")
        #expect(table.conflict(group: 5, now: 104.0) == nil)
        // and back: the lower id wins again as soon as it sends, and the replaced one is the conflict
        table.offer(Self.clock(group: 5, position: 4), from: Self.high, at: 104.0)
        table.offer(Self.clock(group: 5, position: 5), from: Self.low, at: 104.5)
        #expect(table.entries[4]?.machine == Self.low)
        #expect(table.conflict(group: 5, now: 104.5) == Self.high)
    }

    /// B317: from one machine, a duplicate tick or a packet that arrives behind a newer one never replaces it.
    @Test func aDuplicateOrReorderedPacketDoesNotReplaceANewerOne() async throws {
        let (receiver, port) = try Self.receiver()
        defer { receiver.stop() }
        let datagrams = [
            Self.packet(from: Self.low, tick: 10, [Self.clock(group: 1, position: 10)]),
            Self.packet(from: Self.low, tick: 9, [Self.clock(group: 1, position: 9)]),  // reordered
            Self.packet(from: Self.low, tick: 10, [Self.clock(group: 1, position: 99)]),  // the same tick again
            Self.packet(from: Self.low, tick: 11, [Self.clock(group: 3)]),  // marks the end
        ]
        #expect(sendUDP(datagrams, to: port).sent == datagrams.map(\.count))
        _ = try #require(try await Self.entry(receiver, group: 3))
        #expect(receiver.table.withLock { $0.entries[0]?.clock.position } == 10)
    }

    /// The tick check holds only within a window behind a fresh entry of the same machine: a master that restarted
    /// (ticks from 0), a tick that wraps, a stale entry and a master on this machine (no tick) all replace it.
    @Test func aRestartedMasterAWrapAStaleEntryAndLocalMastersReplaceTheEntry() {
        var table = SyncTable()
        table.offer(Self.clock(group: 2, position: 1), from: Self.low, tick: 100_000, at: 10)
        table.offer(Self.clock(group: 2, position: 2), from: Self.low, tick: 0, at: 10.1)
        #expect(table.entries[1]?.clock.position == 2, "restarted")
        table.offer(Self.clock(group: 2, position: 3), from: Self.low, tick: .max, at: 10.2)
        #expect(table.entries[1]?.clock.position == 2, "one tick behind 0 across the wrap")
        table.offer(Self.clock(group: 2, position: 4), from: Self.low, tick: .max, at: 12.2)
        #expect(table.entries[1]?.clock.position == 4, "the entry was stale")
        table.offer(Self.clock(group: 2, position: 5), from: Self.low, tick: 0, at: 12.3)
        #expect(table.entries[1]?.clock.position == 5, "the wrap forward")
        table.offer(Self.clock(group: 4, position: 1), from: Self.own, at: 20)
        table.offer(Self.clock(group: 4, position: 2), from: Self.own, at: 20)
        #expect(table.entries[3]?.clock.position == 2, "a local master carries no tick")
    }

    /// B317: the arrival time is the kernel's, taken before the queue runs the handler; before, the handler stamped it,
    /// so a busy queue made the master look that much later.
    @Test func theArrivalTimeIsTakenBeforeTheHandlerRuns() async throws {
        let (receiver, port) = try Self.receiver()
        defer { receiver.stop() }
        let release = DispatchSemaphore(value: 0)
        receiver.queue.async { release.wait() }
        sendUDP(Self.packet(from: Self.low, [Self.clock(group: 6)]), to: port)
        try await Task.sleep(for: .milliseconds(30))
        let released = CACurrentMediaTime()
        release.signal()
        let entry = try #require(try await Self.entry(receiver, group: 6))
        #expect(entry.receivedAt < released - 0.02, "\((released - entry.receivedAt) * 1000) ms before the queue ran")
    }

    /// B318: the receive queue runs at the control plane's class, not the default.
    @Test func theReceiveQueueIsUserInitiated() {
        #expect(SyncReceiver(machine: Self.own, logger: testLogger).queue.qos == .userInitiated)
    }

    /// B317 measurement, `FANOUS_BENCH=1`: how much later than its `sendto` a packet's arrival time is, alone and with
    /// twice as many spinning `.userInitiated` threads as cores. Printed, not asserted.
    @Test(.offPool, .enabled(if: ProcessInfo.processInfo.environment["FANOUS_BENCH"] != nil))
    func printArrivalDelay() throws {
        let (receiver, port) = try Self.receiver()
        defer { receiver.stop() }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        func run(_ label: String, count: Int) {
            var delays: [Double] = []
            for i in 1...count {
                let bytes = Self.packet(from: Self.low, tick: UInt32(i), [Self.clock(group: 7, position: Double(i))])
                let sentAt = CACurrentMediaTime()
                _ = withSockaddr(port: port, host: "127.0.0.1") { sendto(fd, bytes, bytes.count, 0, $0, $1) }
                let deadline = sentAt + 0.5
                var entry: SyncTable.Entry?
                while CACurrentMediaTime() < deadline {
                    entry = receiver.table.withLock { $0.entries[6] }
                    if entry?.clock.position == Double(i) { break }
                    usleep(200)
                }
                if let entry, entry.clock.position == Double(i) { delays.append((entry.receivedAt - sentAt) * 1000) }
                usleep(3000)
            }
            delays.sort()
            func q(_ p: Double) -> String { String(format: "%.3f", delays[min(delays.count - 1, Int(Double(delays.count) * p))]) }
            print("B317 arrival delay \(label): n=\(delays.count) median \(q(0.5)) p90 \(q(0.9)) p99 \(q(0.99)) max \(q(1)) ms")
        }
        run("idle", count: 300)
        let spinning = Atomic<Bool>(true)
        let threads = ProcessInfo.processInfo.activeProcessorCount * 2
        let stopped = DispatchSemaphore(value: 0)
        for _ in 0..<threads {
            let thread = Thread {
                var x = 0.0
                while spinning.load(ordering: .relaxed) { x += 1 }
                if x < 0 { print(x) }
                stopped.signal()
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        run("\(threads) spinning threads", count: 300)
        spinning.store(false, ordering: .relaxed)
        for _ in 0..<threads { stopped.wait() }
    }

    @Test func machineOrderIsTheOrderOfTheUUIDString() {
        let ids = (0..<64).map { _ in UUID() }
        for a in ids.prefix(8) {
            for b in ids { #expect(SyncTable.precedes(a, b) == (a.uuidString < b.uuidString)) }
        }
    }
}
