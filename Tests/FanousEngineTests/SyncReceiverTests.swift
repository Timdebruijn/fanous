// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import QuartzCore
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

    static func packet(from machine: UUID, _ layers: [SyncPacket.Layer]) -> [UInt8] {
        var bytes: [UInt8] = []
        SyncPacket(machineID: machine, tick: 1, sendTime: 0, layers: layers).encode(into: &bytes)
        return bytes
    }

    /// A receiver on a free port, bound to 127.0.0.1.
    static func receiver() throws -> (SyncReceiver, UInt16) {
        let port = try freeUDPPort()
        let receiver = SyncReceiver(machine: own, logger: Logger(label: "sync-test"))
        try receiver.start(port: port, loopbackOnly: true)
        return (receiver, port)
    }

    /// Waits until `group` has an entry (the queue handles datagrams in order, so everything sent before it is done).
    static func entry(_ receiver: SyncReceiver, group: Int) async throws -> SyncTable.Entry? {
        for _ in 0..<200 {
            if let entry = receiver.table.withLock({ $0.entries[group - 1] }) { return entry }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func aSendersClockArrives() async throws {
        let (receiver, port) = try Self.receiver()
        defer { receiver.stop() }
        var settings = SyncSettings()
        settings.target = "127.0.0.1:\(port)"
        let sender = SyncSender(
            machine: Self.low, settings: settings, network: false, logger: Logger(label: "sync-test"))
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
        // not == 1: a sender idle for 1 s sends a keepalive, which a loaded run reaches before this line (B101)
        #expect(receiver.packetsIn.load(ordering: .relaxed) >= 1)
    }

    @Test func ownPacketsGarbageAndKeepalivesTouchNothing() async throws {
        let (receiver, port) = try Self.receiver()
        defer { receiver.stop() }
        sendUDP(Self.packet(from: Self.own, [Self.clock(group: 1)]), to: port)
        sendUDP(Array("not a sync packet".utf8), to: port)
        sendUDP(Array("FSYN".utf8) + [9] + [UInt8](repeating: 0, count: 40), to: port)  // a version we do not speak
        sendUDP(Self.packet(from: Self.high, []), to: port)  // keepalive
        sendUDP(Self.packet(from: Self.low, [Self.clock(group: 2)]), to: port)
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
        sendUDP(Self.packet(from: Self.high, [Self.clock(group: 1, position: 1)]), to: port)
        sendUDP(Self.packet(from: Self.low, [Self.clock(group: 1, position: 2)]), to: port)
        sendUDP(Self.packet(from: Self.high, [Self.clock(group: 1, position: 3)]), to: port)
        sendUDP(Self.packet(from: Self.low, [Self.clock(group: 3)]), to: port)  // marks the end
        _ = try await Self.entry(receiver, group: 3)
        let table = receiver.table.withLock { $0 }
        #expect(table.entries[0]?.machine == Self.low)
        #expect(table.entries[0]?.clock.position == 2, "the higher id's later packet is ignored")
        #expect(table.conflict(group: 1, now: CACurrentMediaTime()) == Self.high)
        #expect(table.conflict(group: 3, now: CACurrentMediaTime()) == nil)
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

    @Test func machineOrderIsTheOrderOfTheUUIDString() {
        let ids = (0..<64).map { _ in UUID() }
        for a in ids.prefix(8) {
            for b in ids { #expect(SyncTable.precedes(a, b) == (a.uuidString < b.uuidString)) }
        }
    }
}
