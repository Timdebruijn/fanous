// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import FanousCore

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

    @Test func syncAndDiscoveryAreNotData() {
        // E1.31 synchronization and universe discovery packets: extended root vector 0x08, framing vector 0x01 / 0x02.
        let sync = SACN.flagsLength(11) + [0, 0, 0, 1, 3] + UInt16(7999).bigEndianBytes + [0, 0]
        let list = [UInt16(1), 2, 63999].flatMap(\.bigEndianBytes)
        let discovery = SACN.flagsLength(8 + list.count) + [0, 0, 0, 1, 0, 0] + list
        let framing = SACN.flagsLength(74 + discovery.count) + [0, 0, 0, 2] + [UInt8].fixed("Console B", 64) + [0, 0, 0, 0]
        for body in [sync, framing + discovery] {
            let bytes = SACN.root(cid: Self.cidA, vector: 0x0000_0008, bodyLength: body.count) + body
            #expect(throws: SACN.ParseError.badVector) { try SACN.parse(bytes) }
        }
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
        do { let outcome = table.apply(artnet: artnet, from: "10.0.0.5", at: 0) == [UniverseID(.artnet, 0)]; #expect(outcome) }
        do { let outcome = table.apply(artnet: artnet, from: "10.0.0.5", at: 0.1).isEmpty; #expect(outcome) }  // repeated sequence 1
        do { let outcome = table.apply(artnet: ArtDmx(sequence: 0, portAddress: 0, data: [3, 4]), from: "10.0.0.6", at: 0.2).count == 1; #expect(outcome) }
        #expect(table.slots(for: UniverseID(.artnet, 0))?.prefix(2) == [3, 4])
        #expect(table.slots(for: UniverseID(.artnet, 0))?.count == 512)
        let sacn = SACNData(cid: Self.cidA, sourceName: "A", universe: 5, slots: [9])
        do { let outcome = table.apply(sacn: sacn, at: 0.3) == [UniverseID(.sacn, 5)]; #expect(outcome) }
        #expect(table.knownUniverses == [UniverseID(.artnet, 0), UniverseID(.sacn, 5)])
        let status = table.status(for: UniverseID(.artnet, 0), at: 1.0)
        #expect(status.active && status.packets == 2 && status.source == "10.0.0.6")
        #expect(!table.status(for: UniverseID(.artnet, 0), at: 4.0).active)
        #expect(table.status(for: UniverseID(.sacn, 5), at: 1.0).source == "A (p100)")
        table.expire(at: 10)
        #expect(table.slots(for: UniverseID(.sacn, 5)) == nil)
    }

    // MARK: B271, bounded DMX state

    static func cid(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: 12) + withUnsafeBytes(of: UInt32(n).bigEndian, Array.init) }

    /// E1.31 universes run 1–63999; 0 and 64000–65535 are reserved and refused at parse.
    @Test func outOfRangeUniverseIsRefusedAtParse() throws {
        for universe in [UInt16(0), 64000, 65535] {
            let bytes = SACNData(cid: Self.cidA, sourceName: "x", universe: universe, slots: [1]).encoded()
            #expect(throws: SACN.ParseError.self, "universe \(universe)") { try SACN.parse(bytes) }
        }
        for universe in [UInt16(1), 63999] {
            let packet = SACNData(cid: Self.cidA, sourceName: "x", universe: universe, slots: [1])
            #expect(try SACN.parse(packet.encoded()) == .data(packet))
        }
    }

    /// A burst naming every universe leaves at most 256 universes held; one the settings use always gets in, and once the
    /// burst has been silent for its loss timeout a newly heard universe takes a freed place.
    @Test func aBurstOfUniversesLeavesABoundedTable() {
        var table = UniverseTable()
        let kept = UniverseID(.sacn, 63999)
        var settings = UniverseSettings(for: kept)
        settings.lossTimeout = 10
        table.configure([kept: settings], at: 0)
        for universe in 1...63998 { _ = table.apply(sacn: SACNData(cid: Self.cidA, sourceName: "burst", universe: UInt16(universe), slots: [1]), at: 0) }
        for port in 0...32767 { _ = table.apply(artnet: ArtDmx(portAddress: UInt16(port), data: [1]), from: "10.0.0.9", at: 0) }
        #expect(table.knownUniverses.count <= 256, "\(table.knownUniverses.count) universes held")
        #expect(table.apply(sacn: SACNData(cid: Self.cidB, sourceName: "desk", universe: 63999, slots: [7]), at: 1) == [kept])
        #expect(table.apply(sacn: SACNData(cid: Self.cidB, sourceName: "desk", universe: 7000, slots: [7]), at: 1).isEmpty, "the table is full")
        table.expire(at: 3)  // the burst has been silent for 3 s, more than its 2.5 s loss timeout
        #expect(table.apply(sacn: SACNData(cid: Self.cidB, sourceName: "desk", universe: 7000, slots: [7]), at: 3) == [UniverseID(.sacn, 7000)])
        #expect(table.status(for: kept, at: 3).active, "the universe with settings is not forgotten")
        #expect(table.knownUniverses.count <= 256)
    }

    /// Rotating CIDs on one universe: at most 16 sources are tracked, a new one beyond that is refused (never the winner
    /// evicted), and a source silent for the 2.5 s source timeout frees its place.
    @Test func rotatingSourcesLeaveABoundedSetAndTheWinner() {
        var merger = SACNUniverseMerger()
        _ = merger.apply(SACNData(cid: Self.cidA, sourceName: "desk", priority: 120, universe: 1, slots: [50]), at: 0)
        for n in 1...1000 { _ = merger.apply(SACNData(cid: Self.cid(n), sourceName: "rogue \(n)", priority: 200, universe: 1, slots: [9]), at: 1) }
        #expect(merger.sources.count <= 16, "\(merger.sources.count) sources")
        #expect(merger.sources[Self.cidA] != nil)
        // the first 15 rogues got in at priority 200 and win, as before; when they fall silent the desk wins again
        _ = merger.apply(SACNData(cid: Self.cidA, sourceName: "desk", priority: 120, sequence: 1, universe: 1, slots: [51]), at: 3)
        merger.expire(at: 3.6)
        #expect(merger.winner?.cid == Self.cidA && merger.slots?[0] == 51)
        #expect(merger.sources.count == 1)
        do { let outcome = merger.apply(SACNData(cid: Self.cidB, sourceName: "backup", priority: 100, universe: 1, slots: [3]), at: 3.7); #expect(outcome) }
        #expect(merger.sources.count == 2 && merger.winner?.cid == Self.cidA)
    }

    /// A full source set never evicts the current winner: a 17th source, even at a higher priority, is refused.
    @Test func aFullSourceSetKeepsTheWinner() {
        var merger = SACNUniverseMerger()
        _ = merger.apply(SACNData(cid: Self.cidA, sourceName: "desk", priority: 150, universe: 1, slots: [50]), at: 0)
        for n in 1...15 { _ = merger.apply(SACNData(cid: Self.cid(n), sourceName: "node \(n)", priority: 100, universe: 1, slots: [9]), at: 0) }
        #expect(merger.sources.count == 16)
        do { let outcome = !merger.apply(SACNData(cid: Self.cidB, sourceName: "late", priority: 199, universe: 1, slots: [1]), at: 0.1); #expect(outcome) }
        #expect(merger.winner?.cid == Self.cidA && merger.slots?[0] == 50)
    }
}
