// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import FanousCore

/// B28: per-universe protocol, interface, loss timeout and sACN priority mode, routed by the universe table.
@Suite struct UniverseSettingsTests {
    static let a0 = UniverseID(.artnet, 0)
    static let s1 = UniverseID(.sacn, 1)
    static let cidA: [UInt8] = (1...16).map { UInt8($0) }
    static let cidB: [UInt8] = (17...32).map { UInt8($0) }

    static func art(_ level: UInt8, port: Int = 0, sequence: UInt8 = 0) -> ArtDmx { ArtDmx(sequence: sequence, portAddress: UInt16(port), data: [level, level]) }
    static func sacn(_ slots: [UInt8], universe: UInt16 = 1, priority: UInt8 = 100, cid: [UInt8] = cidA, sequence: UInt8 = 1) -> SACNData {
        SACNData(cid: cid, sourceName: cid == cidA ? "A" : "B", priority: priority, sequence: sequence, universe: universe, slots: slots)
    }

    @Test func defaultsAreTheBehaviourBeforeB28() {
        let art = UniverseSettings(for: Self.a0)
        #expect(art.protocols == .artnet && art.interface == "any" && art.holdOnLoss == .hold && art.lossTimeout == 2.5 && art.priorityMode == .highest)
        #expect(art.pair == Self.s1 && UniverseSettings.defaultPair(of: Self.s1) == Self.a0)
        #expect(UniverseSettings(for: Self.s1).protocols == .sacn)
        #expect(art.listens(to: .artnet) && !art.listens(to: .sacn))
        // a table with no settings routes, times out and names sources as before
        var table = UniverseTable()
        #expect(table.apply(artnet: Self.art(7), from: "10.0.0.5", at: 1) == [Self.a0])
        #expect(table.apply(sacn: Self.sacn([9]), at: 0) == [Self.s1])
        #expect(table.status(for: Self.a0, at: 3.5).active && !table.status(for: Self.a0, at: 3.6).active)
    }

    @Test func interfaceSyntax() {
        for good in ["any", "en0", "en10", "bridge100", "lo0", "utun3", "10.0.0.5", "192.168.1.200"] { #expect(UniverseSettings.isValidInterface(good), "\(good)") }
        for bad in ["", "en", "0", "En0", "en0 ", "eth-0", "10.0.0", "10.0.0.256", "en12345", "::1"] { #expect(!UniverseSettings.isValidInterface(bad), "\(bad)") }
    }

    @Test func subnetsMatchSenders() throws {
        let subnet = try #require(IPv4Subnet(address: "10.0.0.5", netmask: "255.255.255.0"))
        #expect(subnet.contains("10.0.0.77") && subnet.contains("::ffff:10.0.0.1") && subnet.contains("10.0.0.9%en0"))
        #expect(!subnet.contains("10.0.1.1") && !subnet.contains("desk") && !subnet.contains(""))
        let interfaces = [
            NetworkInterface(name: "lo0", address: "127.0.0.1", netmask: "255.0.0.0"),
            NetworkInterface(name: "en1", address: "2.0.0.10", netmask: "255.0.0.0"),
            NetworkInterface(name: "en1", address: "10.0.0.5", netmask: "255.255.255.0"),
        ]
        var s = UniverseSettings(for: Self.a0)
        #expect(s.subnets(in: interfaces) == nil)  // any
        s.interface = "en1"
        #expect(s.subnets(in: interfaces)?.count == 2)
        s.interface = "10.0.0.5"  // by address: every subnet of the interface that has it
        #expect(s.subnets(in: interfaces)?.count == 2)
        s.interface = "en5"
        #expect(s.subnets(in: interfaces) == [])  // not present: no sender
    }

    @Test func interfaceFiltersSenders() throws {
        var table = UniverseTable()
        var s = UniverseSettings(for: Self.a0)
        s.interface = "en1"
        table.configure([Self.a0: s], at: 0)
        table.setFilters([Self.a0: [try #require(IPv4Subnet(address: "2.0.0.10", netmask: "255.0.0.0"))]])
        #expect(table.apply(artnet: Self.art(1), from: "10.0.0.5", at: 0).isEmpty)
        #expect(table.apply(artnet: Self.art(2), from: "2.0.0.1", at: 0.1) == [Self.a0])
        #expect(table.slots(for: Self.a0)?.first == 2)
        // other universes are not filtered
        #expect(table.apply(artnet: Self.art(3, port: 1), from: "10.0.0.5", at: 0.2) == [UniverseID(.artnet, 1)])
        table.setFilters([Self.a0: []])  // interface gone
        #expect(table.apply(artnet: Self.art(4), from: "2.0.0.1", at: 0.3).isEmpty)
    }

    @Test func protocolRoutesTheOtherTransportByPair() {
        var table = UniverseTable()
        var s = UniverseSettings(for: Self.a0)
        s.protocols = .sacn
        table.configure([Self.a0: s], at: 0)
        // A 0.0.0 now listens to S 1 only: its own Art-Net packets go nowhere, S 1 feeds both S 1 and A 0.0.0
        #expect(table.apply(artnet: Self.art(1), from: "desk", at: 0).isEmpty)
        #expect(Set(table.apply(sacn: Self.sacn([5]), at: 0.1)) == [Self.a0, Self.s1])
        #expect(table.slots(for: Self.a0)?.first == 5 && table.status(for: Self.a0, at: 0.2).source == "A (p100)")
        // an explicit pair (1-based console): A 0.0.0 ← S 7
        s.pair = UniverseID(.sacn, 7)
        table.configure([Self.a0: s], at: 0.3)
        #expect(table.apply(sacn: Self.sacn([6], sequence: 2), at: 0.4) == [Self.s1])
        #expect(Set(table.apply(sacn: Self.sacn([8], universe: 7), at: 0.5)) == [Self.a0, UniverseID(.sacn, 7)])
        #expect(UniverseSettings.wire([Self.a0, Self.s1], over: .sacn, settings: [Self.a0: s]) == ["any": [1, 7]])
        #expect(UniverseSettings.wire([Self.a0, Self.s1], over: .artnet, settings: [Self.a0: s]).isEmpty)
    }

    @Test func bothTransportsMergeByPriority() {
        var table = UniverseTable()
        var s = UniverseSettings(for: Self.a0)
        s.protocols = .both
        table.configure([Self.a0: s], at: 0)
        _ = table.apply(artnet: Self.art(10), from: "desk", at: 0)
        _ = table.apply(sacn: Self.sacn([20], priority: 90), at: 0.1)
        #expect(table.slots(for: Self.a0)?.first == 10)  // Art-Net counts as 100
        _ = table.apply(sacn: Self.sacn([30], priority: 120, sequence: 2), at: 0.2)
        #expect(table.slots(for: Self.a0)?.first == 30)
        _ = table.apply(sacn: Self.sacn([40], priority: 100, sequence: 3), at: 0.3)
        #expect(table.slots(for: Self.a0)?.first == 40)  // equal priority: latest
        _ = table.apply(artnet: Self.art(15), from: "desk", at: 0.4)
        #expect(table.slots(for: Self.a0)?.first == 15 && table.status(for: Self.a0, at: 0.4).source == "desk")
        s.priorityMode = .htp
        table.configure([Self.a0: s], at: 0.5)
        #expect(table.slots(for: Self.a0)?.first == 40)  // equal priority, HTP per slot
        // Art-Net silent past the timeout: sACN alone, even at a lower priority
        s.priorityMode = .highest
        table.configure([Self.a0: s], at: 0.6)
        _ = table.apply(sacn: Self.sacn([50], priority: 50, sequence: 4), at: 3.0)
        #expect(table.slots(for: Self.a0)?.first == 50)
    }

    @Test func sacnHTPMergesSourcesAtTheTopPriority() {
        var merger = SACNUniverseMerger()
        _ = merger.apply(Self.sacn([10, 200, 0]), at: 0)
        _ = merger.apply(Self.sacn([50, 100, 0], cid: Self.cidB), at: 0.1)
        #expect(merger.slots(.highest)?.prefix(3) == [50, 100, 0])
        #expect(merger.slots(.htp)?.prefix(3) == [50, 200, 0])
        #expect(merger.sourceName(.htp) == "A + B (p100)" && merger.sourceName(.highest) == "B (p100)")
        _ = merger.apply(Self.sacn([1, 1, 1], priority: 150, sequence: 2), at: 0.2)
        #expect(merger.slots(.htp)?.prefix(3) == [1, 1, 1])  // only the highest priority merges
    }

    /// The loss timeout decides when a universe counts as lost; the sACN source timeout stays 2.5 s (E1.31), so a
    /// backup console at a lower priority takes over on time whatever the loss timeout.
    @Test func lossTimeoutPerUniverseSourceTimeoutFixed() {
        var table = UniverseTable()
        var s = UniverseSettings(for: Self.s1)
        s.lossTimeout = 10
        table.configure([Self.s1: s], at: 0)
        _ = table.apply(sacn: Self.sacn([1], priority: 150), at: 0.5)
        _ = table.apply(sacn: Self.sacn([2], priority: 100, cid: Self.cidB), at: 0.5)
        _ = table.apply(sacn: Self.sacn([1], universe: 2), at: 0.5)
        _ = table.apply(sacn: Self.sacn([2], priority: 100, cid: Self.cidB, sequence: 2), at: 4)  // the backup keeps sending
        table.expire(at: 4)
        #expect(table.slots(for: Self.s1)?.first == 2)  // primary dropped after 2.5 s
        #expect(table.status(for: Self.s1, at: 4).active)
        table.expire(at: 8)
        #expect(table.status(for: Self.s1, at: 8).active && table.slots(for: Self.s1) == nil)  // no source, not lost yet
        #expect(!table.status(for: UniverseID(.sacn, 2), at: 5).active)
        #expect(!table.status(for: Self.s1, at: 14.5).active)
        #expect(UniverseSettings.lossTimeoutRange == 1...60)
    }

    @Test func resolverFallsBackToInternalWithoutDMX() {
        var resolver = FixtureResolver(mode: .layer)
        resolver.setInternal(.layer(.intensity), raw: 1000, source: .cue, at: 1)
        resolver.updateDMX(ChannelMap.rawValues(mode: .layer, slots: [UInt8](repeating: 255, count: 512), address: 1)!, at: 2)
        resolver.internalWithoutDMX = true
        #expect(resolver.resolved(.layer(.intensity)).source == .dmx)  // policy dmx while DMX arrives
        resolver.markDMXLost()
        #expect(resolver.resolved(.layer(.intensity)) == ResolvedValue(raw: 1000, source: .cue, changedAt: 1))
        resolver.internalWithoutDMX = false
        #expect(resolver.resolved(.layer(.intensity)).source == .dmx)  // hold
    }
}
