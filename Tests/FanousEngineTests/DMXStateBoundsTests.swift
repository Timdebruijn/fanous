// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Testing

@testable import FanousEngine

/// B271: a burst of packets naming every universe, or rotating sACN sources, leaves bounded DMX state, a bounded log and
/// a patched universe that still works. Packets go to the store directly (no socket); all times are injected.
struct DMXStateBoundsTests {
    static let desk: [UInt8] = (1...16).map { UInt8($0) }

    static func cid(_ n: Int) -> [UInt8] { [UInt8](repeating: 0xEE, count: 12) + withUnsafeBytes(of: UInt32(n).bigEndian, Array.init) }

    static func milliseconds(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        return (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) * 1000
    }

    static func store(_ patch: Patch, _ lines: HTTPSServerLogTests.Lines) -> DMXStore {
        DMXStore(patch: patch, logger: Logger(label: "test") { _ in HTTPSServerLogTests.Capture(lines: lines) })
    }

    static func count(_ lines: HTTPSServerLogTests.Lines, _ prefix: String) -> Int { lines.all.withLock { $0.filter { $0.hasPrefix(prefix) }.count } }

    static func intensity(_ store: DMXStore, at now: Double) -> UInt16? {
        store.snapshot(at: now).fixtures["Layer 1"]?.first { $0.key == "intensity" }?.raw
    }

    /// Layer 1 is on A 0.0.0. The desk sends there; then one burst names every sACN universe, each from its own source.
    /// Times are printed, not asserted (machines differ); counts are asserted.
    @Test func aBurstOfUniversesLeavesBoundedStateAndLog() {
        let lines = HTTPSServerLogTests.Lines()
        let store = Self.store(.standard(layers: 1, outputs: 1), lines)
        var before = (snapshot: 0.0, tick: 0.0)
        var after = before
        store.queue.sync {
            store.receive(artnet: ArtDmx(portAddress: 0, data: [10, 0]), from: "desk", at: 0)
            before.tick = Self.milliseconds { store.tick(at: 0.1) }
        }
        before.snapshot = Self.milliseconds { _ = store.snapshot(at: 0.1) }
        store.queue.sync {
            for universe in 1...63999 {
                store.receive(sacn: SACNData(cid: Self.cid(universe), sourceName: "burst \(universe)", universe: UInt16(universe), slots: [1]), at: 0.5)
            }
            after.tick = Self.milliseconds { store.tick(at: 1) }
        }
        after.snapshot = Self.milliseconds { _ = store.snapshot(at: 1) }
        let universes = store.snapshot(at: 1).universes.count
        let receiving = Self.count(lines, "DMX receiving")
        let limits = Self.count(lines, "DMX limits reached")
        print("B271 burst: \(universes) universes, \(receiving) receiving lines, \(limits) limit lines; snapshot \(before.snapshot) → \(after.snapshot) ms, tick \(before.tick) → \(after.tick) ms")
        #expect(universes <= 256 + store.currentPatch.universes.count, "\(universes) universes in the live document")
        #expect(receiving <= 256, "\(receiving) receiving lines")
        #expect(limits == 1, "\(limits) limit lines")

        // the patched universes still take the desk, also the Master's (A 0.0.1), first heard while the table is full,
        // and once the burst is silent a console's universe is heard again
        store.queue.sync {
            store.receive(artnet: ArtDmx(portAddress: 0, data: [200, 0]), from: "desk", at: 1.5)
            store.receive(artnet: ArtDmx(portAddress: 1, data: [200, 0]), from: "desk", at: 1.5)
        }
        #expect(store.snapshot(at: 1.5).universes.contains { $0.id == "artnet:0.0.1" && $0.active })
        // the tick at 3.5 forgets the silent burst and refuses nothing: the burst is over, the logged pairs are forgotten
        store.queue.sync {
            store.tick(at: 3.5)
            store.receive(sacn: SACNData(cid: Self.desk, sourceName: "Console", universe: 40, slots: [1]), at: 3.6)
        }
        #expect(Self.intensity(store, at: 3.6) == 200 << 8)
        let later = store.snapshot(at: 3.6).universes
        #expect(later.contains { $0.id == "sacn:40" && $0.active })
        #expect(later.count < 10, "the burst's universes are forgotten: \(later.count)")
        #expect(lines.all.withLock { $0.contains { $0.hasPrefix("DMX receiving") && $0.contains("sacn:40 from Console") } })
        #expect(Self.count(lines, "DMX limits reached") == 1)
    }

    /// Rotating CIDs on the patched universe: at most 16 sources are tracked, the desk keeps winning, at most one line
    /// per source that got in.
    @Test func rotatingSourcesOnAPatchedUniverseStayBounded() {
        let lines = HTTPSServerLogTests.Lines()
        let store = Self.store(.standard(layers: 1, outputs: 1, transport: .sacn), lines)
        store.queue.sync {
            store.receive(sacn: SACNData(cid: Self.desk, sourceName: "desk", priority: 150, universe: 1, slots: [77, 0]), at: 0)
            for n in 1...5000 {
                store.receive(sacn: SACNData(cid: Self.cid(n), sourceName: "rogue \(n)", priority: 100, universe: 1, slots: [1]), at: 0.5)
            }
            store.tick(at: 1)
        }
        let universe = store.snapshot(at: 1).universes.first { $0.id == "sacn:1" }
        let receiving = Self.count(lines, "DMX receiving")
        print("B271 rotating sources: \(universe?.source ?? "-"), \(receiving) receiving lines")
        #expect(universe?.source == "desk (p150)")
        #expect(Self.intensity(store, at: 1) == 77 << 8)
        #expect(receiving <= 16, "\(receiving) receiving lines")
    }

    /// The review's rig: a desk at priority 100 drives the patched S 1, junk at priority 50 holds the other 15 places,
    /// the desk restarts under a new CID while its old one is still tracked: it is in control on its first packet.
    @Test func aDeskReturningUnderANewCIDBeatsAFullJunkSet() {
        let lines = HTTPSServerLogTests.Lines()
        let store = Self.store(.standard(layers: 1, outputs: 1, transport: .sacn), lines)
        store.queue.sync {
            store.receive(sacn: SACNData(cid: Self.desk, sourceName: "desk", priority: 100, universe: 1, slots: [77, 0]), at: 0)
            for n in 1...15 { store.receive(sacn: SACNData(cid: Self.cid(n), sourceName: "junk", priority: 50, universe: 1, slots: [1]), at: 0.5) }
            store.receive(sacn: SACNData(cid: Self.cid(9999), sourceName: "desk", priority: 100, universe: 1, slots: [33, 0]), at: 1)
        }
        #expect(Self.intensity(store, at: 1) == 33 << 8)
        store.queue.sync { store.tick(at: 1.2) }
        #expect(Self.count(lines, "DMX limits reached") == 1)
        #expect(lines.all.withLock { $0.contains { $0.hasPrefix("DMX limits reached") && $0.contains("1 sources replaced") } })
    }

    /// A main and a backup console on 130 universes are 260 pairs and no flood: every pair is logged (over a few ticks,
    /// 32 new lines per tick), nothing warns, and a console that comes afterwards is announced.
    @Test func manyLegitimatePairsWarnNothingAndALateConsoleIsAnnounced() {
        let lines = HTTPSServerLogTests.Lines()
        let store = Self.store(.standard(layers: 1, outputs: 1), lines)
        store.queue.sync {
            var t = 0.0
            for round in 0..<12 {
                for universe in 1...130 {
                    for (cid, name) in [(Self.cid(1), "main"), (Self.cid(2), "backup")] {
                        store.receive(sacn: SACNData(cid: cid, sourceName: name, sequence: UInt8(round), universe: UInt16(universe), slots: [1]), at: t)
                    }
                }
                t += 0.5
                store.tick(at: t)
            }
            store.receive(sacn: SACNData(cid: Self.desk, sourceName: "late", universe: 4000, slots: [1]), at: t)
        }
        #expect(Self.count(lines, "DMX receiving") == 261)
        #expect(Self.count(lines, "DMX limits reached") == 0)
        #expect(lines.all.withLock { $0.contains { $0.contains("sacn:4000 from late") } })
    }

    /// A flood in bursts with a quiet half second between them: the second burst writes no line twice, and the warning
    /// comes once.
    @Test func aBurstyFloodLogsNoLineTwice() {
        let lines = HTTPSServerLogTests.Lines()
        let store = Self.store(.standard(layers: 1, outputs: 1), lines)
        store.queue.sync {
            for (burst, at) in [(1, 0.1), (2, 1.1), (3, 2.1)] {
                for universe in 1...2000 {
                    store.receive(sacn: SACNData(cid: Self.cid(universe), sourceName: "burst", sequence: UInt8(burst), universe: UInt16(universe), slots: [1]), at: at)
                }
                store.tick(at: at + 0.4)
                store.tick(at: at + 0.9)
            }
        }
        let receiving = lines.all.withLock { $0.filter { $0.hasPrefix("DMX receiving") } }
        #expect(Set(receiving).count == receiving.count, "a line written twice")
        #expect(receiving.count <= 3 * 32)
        #expect(Self.count(lines, "DMX limits reached") == 1)
    }

    /// A universe patched later (`applyPatch`, not only `init`) gets in while the table is full.
    @Test func aUniversePatchedLaterGetsInWhileTheTableIsFull() {
        let store = Self.store(.standard(layers: 1, outputs: 1), HTTPSServerLogTests.Lines())
        store.queue.sync {
            for universe in 1...1000 { store.receive(sacn: SACNData(cid: Self.cid(universe), sourceName: "burst", universe: UInt16(universe), slots: [1]), at: 0) }
        }
        store.setPatch(Patch(entries: store.currentPatch.entries + [PatchEntry(fixture: .layer(2), universe: UniverseID(.sacn, 5000), address: 1)]))
        store.queue.sync { store.receive(sacn: SACNData(cid: Self.desk, sourceName: "desk", universe: 5000, slots: [1]), at: 0.1) }
        #expect(store.snapshot(at: 0.1).universes.contains { $0.id == "sacn:5000" && $0.active })
    }

    /// Allocations of 100 packets from a known source on a patched universe, with 1 and with 16 sources tracked there.
    /// Printed, not asserted: the padded slots, the routing arrays and the source name still allocate per packet (B307).
    @Test(.mallocCounter) func printKnownSourcePacketMallocs() throws {
        try requireMallocCounter()
        for sources in [1, 16] {
            let store = Self.store(.standard(layers: 1, outputs: 1, transport: .sacn), HTTPSServerLogTests.Lines())
            let packets = (1...100).map { SACNData(cid: Self.cid(1), sourceName: "desk", sequence: UInt8($0), universe: 1, slots: [77, 0]) }
            var mallocs = 0
            store.queue.sync {
                for n in 1...sources { store.receive(sacn: SACNData(cid: Self.cid(n), sourceName: "desk", universe: 1, slots: [77, 0]), at: 0) }
                mallocs = MallocCounter.count {
                    var i = 0
                    while i < packets.count {
                        store.receive(sacn: packets[i], at: 0.1)
                        i += 1
                    }
                }
            }
            print("B271 known-source packets × 100 with \(sources) sources: \(mallocs) allocations")
        }
    }
}
