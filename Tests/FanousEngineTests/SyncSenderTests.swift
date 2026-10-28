// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Testing

@testable import FanousEngine

/// The packet slot the compositor fills and the thread that sends it (DESIGN.md §23.2).
@Suite(.serialized)
struct SyncSenderTests {
    static let machine = UUID(uuidString: "20000000-0000-0000-0000-000000000000")!
    static let clocks: [SyncPacket.Layer] = {
        var clocks: [SyncPacket.Layer] = []
        for i in 0..<SyncPacket.maxLayers {
            let group = UInt8(i % 8 + 1)
            let layer = UInt8(i + 1)
            let position = Double(i)
            clocks.append(
                SyncPacket.Layer(
                    group: group, layer: layer, mediaKey: 0x0101, fps: 50, position: position, direction: 1,
                    finished: false,
                    rate: 50))
        }
        return clocks
    }()

    static func sender(port: UInt16) -> SyncSender {
        var settings = SyncSettings()
        settings.target = "127.0.0.1:\(port)"
        return SyncSender(machine: machine, settings: settings, network: false, logger: Logger(label: "sync-test"))
    }

    /// The compositor's write: 32 masters into each of the three slots, then never a new buffer (DESIGN.md §4.6).
    @Test func thirtyTwoMastersFillTheSlotWithoutAllocating() {
        let sender = Self.sender(port: 9)
        var buffers: Set<UnsafeRawPointer?> = []
        var encoded: [UInt8] = []
        encoded.reserveCapacity(SyncPacket.maxSize)
        let encodedBase = encoded.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        for round in 0..<100 {
            sender.slots.write { slot in
                slot.packet.tick = UInt32(round)
                slot.packet.layers.removeAll(keepingCapacity: true)
                slot.packet.layers.append(contentsOf: Self.clocks)
            }
            let slot = sender.slots.read()
            #expect(slot.packet.tick == UInt32(round))
            slot.packet.encode(into: &encoded)
            let base = slot.packet.layers.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
            if round < 3 {
                buffers.insert(base)
            } else {
                #expect(buffers.contains(base), "round \(round): the slot's layers moved")
            }
        }
        #expect(buffers.count == 3, "one buffer per slot")
        #expect(encoded.count == SyncPacket.maxSize)
        #expect(
            encoded.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) } == encodedBase,
            "the send buffer was not reallocated")
    }

    @Test func theThreadSendsWhatTheSlotHolds() throws {
        let port = try freeUDPPort()
        let catcher = try UDPCatcher(port: port, timeout: 2)
        let sender = Self.sender(port: port)
        sender.start()
        defer { sender.stop() }
        sender.slots.write { slot in
            slot.packet.tick = 77
            slot.packet.sendTime = 1234.5
            slot.packet.layers.append(contentsOf: Self.clocks.prefix(3))
        }
        sender.wake.signal()
        let packet = try SyncPacket.decode(try #require(catcher.receive()))
        #expect(
            packet
                == SyncPacket(machineID: Self.machine, tick: 77, sendTime: 1234.5, layers: Array(Self.clocks.prefix(3)))
        )
        // the same tick again is not sent again
        sender.wake.signal()
        let again = catcher.receive().flatMap { try? SyncPacket.decode($0) }
        #expect(again?.layers.isEmpty ?? true, "only a keepalive may follow, never the same tick twice")
        #expect(sender.packetsOut.load(ordering: .relaxed) >= 1)
    }

    @Test func withoutMastersOnlyAKeepaliveOnceASecond() throws {
        let port = try freeUDPPort()
        let catcher = try UDPCatcher(port: port, timeout: 0.5)
        let sender = Self.sender(port: port)
        sender.start()
        defer { sender.stop() }
        let start = Date()
        var packets: [SyncPacket] = []
        while Date().timeIntervalSince(start) < 2.3 {
            sender.wake.signal()  // as a compositor tick would, with nothing new in the slot
            if let bytes = catcher.receive() { packets.append(try SyncPacket.decode(bytes)) }
        }
        #expect((2...3).contains(packets.count), "one per second, got \(packets.count)")
        #expect(packets.allSatisfy { $0.layers.isEmpty && $0.machineID == Self.machine })
    }

    @Test func noNetworkSendsOnlyToLoopback() throws {
        var settings = SyncSettings()
        #expect(settings.port == 8002 && settings.target == "broadcast" && settings.interface == "any")
        let port = try freeUDPPort()
        let catcher = try UDPCatcher(port: port, timeout: 1.5)
        settings.port = port  // broadcast would go to this port on the LAN
        let sender = SyncSender(
            machine: Self.machine, settings: settings, network: false, logger: Logger(label: "sync-test"))
        sender.start()
        defer { sender.stop() }
        #expect(catcher.receive() == nil)
        #expect(sender.packetsOut.load(ordering: .relaxed) == 0, "a broadcast target is ignored with the network off")
    }

    @Test func settingsReadFieldByField() throws {
        let settings = try JSONDecoder().decode(
            MachineSettings.self, from: Data(#"{"sync": {"port": 48802, "target": "127.0.0.1:48812"}}"#.utf8))
        #expect(settings.sync?.port == 48802)
        #expect(settings.sync?.target == "127.0.0.1:48812")
        #expect(settings.sync?.interface == "any", "a missing field keeps its default")
        let written = try JSONEncoder().encode(settings)
        #expect(
            try JSONDecoder().decode(MachineSettings.self, from: written).sync == settings.sync,
            "kept when the passwords are saved")
        // a bad field keeps its default, the others are still read, and the problem is reported
        let bad = try JSONDecoder().decode(
            MachineSettings.self,
            from: Data(#"{"sync": {"port": "x", "interface": "en0", "target": "127.0.0.1:48812"}}"#.utf8))
        #expect(bad.sync?.port == 8002 && bad.sync?.interface == "en0" && bad.sync?.target == "127.0.0.1:48812")
        #expect(bad.problems.contains { $0.hasPrefix("sync.port") })
        let zero = try JSONDecoder().decode(MachineSettings.self, from: Data(#"{"sync": {"port": 0}}"#.utf8))
        #expect(zero.sync?.port == 8002, "port 0 would bind an ephemeral port")
    }

    /// A target that is not an address with an optional port sends nothing and does not crash the engine.
    @Test func badTargetsSendNothing() async throws {
        let targets = ["", ":", "127.0.0.1:", "127.0.0.1:abc", "127.0.0.1:0", "127.0.0.1:1:2", "not-an-address"]
        let senders = targets.map { (target: String) -> SyncSender in
            var settings = SyncSettings()
            settings.target = target
            return SyncSender(
                machine: Self.machine, settings: settings, network: false, logger: Logger(label: "sync-test"))
        }
        for sender in senders {
            sender.start()
            sender.start()  // a second start does nothing
        }
        defer { for sender in senders { sender.stop() } }
        try await Task.sleep(for: .milliseconds(1300))  // the first keepalive resolves the target
        #expect(senders.allSatisfy { $0.packetsOut.load(ordering: .relaxed) == 0 })
    }
}
