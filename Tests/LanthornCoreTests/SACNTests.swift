// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import LanthornCore

@Suite struct SACNTests {
    static let cidA: [UInt8] = (1...16).map { UInt8($0) }
    static let cidB: [UInt8] = (17...32).map { UInt8($0) }

    @Test func dataPacketRoundTrip() throws {
        let slots = (0..<512).map { UInt8($0 & 0xFF) }
        let packet = SACNData(cid: Self.cidA, sourceName: "Console A", priority: 120, sequence: 9, universe: 300, slots: slots)
        let bytes = packet.encoded()
        #expect(bytes.count == 638)
        #expect(Array(bytes[0..<4]) == [0, 0x10, 0, 0])
        #expect(Int(bytes[16] & 0x0F) << 8 | Int(bytes[17]) == bytes.count - 16)  // root PDU length
        #expect(Int(bytes[38] & 0x0F) << 8 | Int(bytes[39]) == bytes.count - 38)  // framing PDU length
        #expect(Int(bytes[115] & 0x0F) << 8 | Int(bytes[116]) == bytes.count - 115)  // DMP PDU length
        #expect(bytes[108] == 120 && bytes[111] == 9)
        #expect(bytes[113] == 1 && bytes[114] == 44)  // universe 300
        #expect(try SACN.parse(bytes) == .data(packet))
        let small = SACNData(cid: Self.cidA, sourceName: "x", universe: 1, slots: [255])
        #expect(try SACN.parse(small.encoded()) == .data(small))
    }

    @Test func syncAndDiscoveryRoundTrip() throws {
        let sync = SACNSync(cid: Self.cidA, sequence: 3, syncAddress: 7999)
        #expect(sync.encoded().count == 49)
        #expect(try SACN.parse(sync.encoded()) == .sync(sync))
        let discovery = SACNDiscovery(cid: Self.cidB, sourceName: "Console B", page: 0, lastPage: 0, universes: [1, 2, 63999])
        #expect(try SACN.parse(discovery.encoded()) == .discovery(discovery))
    }

    @Test func rejectsBadPackets() {
        let good = SACNData(cid: Self.cidA, sourceName: "x", universe: 1, slots: [0]).encoded()
        #expect(throws: SACN.ParseError.tooShort) { try SACN.parse(Array(good.prefix(40))) }
        var preamble = good
        preamble[1] = 0x11
        #expect(throws: SACN.ParseError.badPreamble) { try SACN.parse(preamble) }
        var identifier = good
        identifier[4] = UInt8(ascii: "B")
        #expect(throws: SACN.ParseError.badIdentifier) { try SACN.parse(identifier) }
        var vector = good
        vector[21] = 0x09
        #expect(throws: SACN.ParseError.badVector) { try SACN.parse(vector) }
        var address = good
        address[118] = 0xA2
        #expect(throws: SACN.ParseError.badAddressType) { try SACN.parse(address) }
        var count = good
        count[124] = 200  // claims 200 property values, only 2 present
        #expect(throws: SACN.ParseError.badLength) { try SACN.parse(count) }
    }

    @Test func multicastAddresses() {
        #expect(SACN.multicastAddress(universe: 1) == "239.255.0.1")
        #expect(SACN.multicastAddress(universe: 300) == "239.255.1.44")
        #expect(SACN.multicastAddress(universe: 63999) == "239.255.249.255")
    }

    @Test func sequenceGate() {
        var gate = SequenceGate()
        do { let outcome = gate.accept(10); #expect(outcome) }
        do { let outcome = !gate.accept(5); #expect(outcome) }  // diff −5
        do { let outcome = gate.accept(100); #expect(outcome) }  // after 5: diff 95
        do { let outcome = gate.accept(101); #expect(outcome) }
        do { let outcome = !gate.accept(101); #expect(outcome) }  // diff 0
        do { let outcome = !gate.accept(85); #expect(outcome) }  // diff −16
        do { let outcome = gate.accept(60); #expect(outcome) }  // after 85: diff −25 → treated as a restart
    }

    @Test func priorityWinsThenLatestArrival() {
        var merger = SACNUniverseMerger()
        let a = SACNData(cid: Self.cidA, sourceName: "A", priority: 100, sequence: 1, universe: 1, slots: [10])
        let b = SACNData(cid: Self.cidB, sourceName: "B", priority: 150, sequence: 1, universe: 1, slots: [20])
        do { let outcome = merger.apply(a, at: 1.0); #expect(outcome) }
        do { let outcome = merger.apply(b, at: 1.1); #expect(outcome) }
        #expect(merger.slots?[0] == 20)
        var terminated = b
        terminated.sequence = 2
        terminated.options = 0x40
        do { let outcome = merger.apply(terminated, at: 1.2); #expect(outcome) }
        #expect(merger.slots?[0] == 10)
        var c = a
        c.cid = Self.cidB
        c.sourceName = "C"
        c.slots = [30]
        do { let outcome = merger.apply(c, at: 1.3); #expect(outcome) }  // equal priority, later → wins
        #expect(merger.slots?[0] == 30)
        var a2 = a
        a2.sequence = 2
        a2.slots = [11]
        do { let outcome = merger.apply(a2, at: 1.4); #expect(outcome) }
        #expect(merger.slots?[0] == 11)
        #expect(merger.slots?.count == 512)
    }

    @Test func rejectsOutOfSequencePreviewAndNonDMX() {
        var merger = SACNUniverseMerger()
        let a = SACNData(cid: Self.cidA, sourceName: "A", sequence: 10, universe: 1, slots: [1])
        do { let outcome = merger.apply(a, at: 0); #expect(outcome) }
        var stale = a
        stale.sequence = 8
        stale.slots = [2]
        do { let outcome = !merger.apply(stale, at: 0.1); #expect(outcome) }
        #expect(merger.slots?[0] == 1)
        var preview = a
        preview.sequence = 11
        preview.options = 0x80
        do { let outcome = !merger.apply(preview, at: 0.2); #expect(outcome) }
        var rdm = a
        rdm.sequence = 12
        rdm.startCode = 0xCC
        do { let outcome = !merger.apply(rdm, at: 0.3); #expect(outcome) }
    }

    @Test func sourcesExpire() {
        var merger = SACNUniverseMerger()
        _ = merger.apply(SACNData(cid: Self.cidA, sourceName: "A", universe: 1, slots: [1]), at: 0)
        merger.expire(at: 2.0)
        #expect(merger.slots != nil)
        merger.expire(at: 2.6)
        #expect(merger.slots == nil)
    }

    @Test func universeTableTracksBothTransports() {
        var table = UniverseTable()
        let artnet = ArtDmx(sequence: 1, portAddress: 0, data: [1, 2])
        do { let outcome = table.apply(artnet: artnet, from: "10.0.0.5", at: 0) == UniverseID(.artnet, 0); #expect(outcome) }
        do { let outcome = table.apply(artnet: artnet, from: "10.0.0.5", at: 0.1) == nil; #expect(outcome) }  // repeated sequence 1
        do { let outcome = table.apply(artnet: ArtDmx(sequence: 0, portAddress: 0, data: [3, 4]), from: "10.0.0.6", at: 0.2) != nil; #expect(outcome) }
        #expect(table.slots(for: UniverseID(.artnet, 0))?.prefix(2) == [3, 4])
        #expect(table.slots(for: UniverseID(.artnet, 0))?.count == 512)
        let sacn = SACNData(cid: Self.cidA, sourceName: "A", universe: 5, slots: [9])
        do { let outcome = table.apply(sacn: sacn, at: 0.3) == UniverseID(.sacn, 5); #expect(outcome) }
        #expect(table.knownUniverses == [UniverseID(.artnet, 0), UniverseID(.sacn, 5)])
        let status = table.status(for: UniverseID(.artnet, 0), at: 1.0)
        #expect(status.active && status.packets == 2 && status.source == "10.0.0.6")
        #expect(!table.status(for: UniverseID(.artnet, 0), at: 4.0).active)
        #expect(table.status(for: UniverseID(.sacn, 5), at: 1.0).source == "A (p100)")
        table.expire(at: 10)
        #expect(table.slots(for: UniverseID(.sacn, 5)) == nil)
    }
}
