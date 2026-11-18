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
        #expect(receiving <= 256 + 1, "\(receiving) receiving lines")
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
        #expect(lines.all.withLock { $0.contains { $0.hasPrefix("DMX limits reached") && $0.contains("1 sACN sources replaced") } })
    }

    /// A main and a backup console on 130 universes are 260 pairs and no flood: every pair is logged at once (the line
    /// budget holds 512), nothing warns, and a console that comes afterwards is announced.
    @Test func manyLegitimatePairsWarnNothingAndALateConsoleIsAnnounced() {
        let lines = HTTPSServerLogTests.Lines()
        let store = Self.store(.standard(layers: 1, outputs: 1), lines)
        store.queue.sync {
            var t = 0.0
            for round in 0..<4 {
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

    /// Ten minutes of the log budget in one simulated minute (B353): the bucket, its refill time and the warning interval
    /// a tenth of the engine's (51 lines, 1.5 s, 6 s), so the rules are the same at a tenth of the packets and ticks.
    static let scaled = (burst: 51, refill: 1.5, warnEvery: 6.0)

    /// One simulated minute on the `scaled` budget, a tick every 0.5 s, `packets(tick, time)` sent before each tick on the
    /// DMX queue.
    static func tenMinutes(_ store: DMXStore, packets: (Int, Double) -> Void) {
        store.queue.sync {
            store.logBudget = scaled
            var tick = 1
            while tick <= 120 {
                let time = Double(tick) / 2
                packets(tick, time - 0.25)
                store.tick(at: time)
                tick += 1
            }
        }
    }

    /// The most a flood may log in ten minutes of the budget: the bucket plus 40 lines of refill, and the one "held back"
    /// line. The warning comes once an interval (10 in the ten), each with the counts of its interval.
    static func expectBoundedLog(_ lines: HTTPSServerLogTests.Lines, _ shape: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let receiving = count(lines, "DMX receiving"), heldBack = count(lines, "Further DMX receiving lines held back")
        let warnings = lines.all.withLock { $0.filter { $0.hasPrefix("DMX limits reached") } }
        print("B271 ten minutes of \(shape): \(receiving) receiving lines, \(heldBack) held-back lines, \(warnings.count) warnings")
        #expect(receiving <= scaled.burst + 40 + 1, "\(shape): \(receiving) receiving lines", sourceLocation: sourceLocation)
        #expect(heldBack <= 1, sourceLocation: sourceLocation)
        #expect((10...11).contains(warnings.count), "\(shape): \(warnings.count) warnings", sourceLocation: sourceLocation)
        // the first warning holds half a second, the second a whole interval
        let total = { (line: String) in line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.reduce(0, +) }
        if warnings.count >= 2 { #expect(total(warnings[1]) > total(warnings[0]), "\(shape): \(warnings.prefix(2))", sourceLocation: sourceLocation) }
    }

    /// Rotating sACN CIDs on the patched S 1 (20 new ones per tick below the desk), then the flood stops and a console
    /// that comes afterwards is announced.
    @Test func tenMinutesOfRotatingSourcesLogBounded() {
        let lines = HTTPSServerLogTests.Lines()
        let store = Self.store(.standard(layers: 1, outputs: 1, transport: .sacn), lines)
        Self.tenMinutes(store) { tick, time in
            store.receive(sacn: SACNData(cid: Self.desk, sourceName: "desk", priority: 150, sequence: UInt8(tick % 256), universe: 1, slots: [77, 0]), at: time)
            for k in 0..<20 { store.receive(sacn: SACNData(cid: Self.cid(tick * 20 + k), sourceName: "rogue \(tick * 20 + k)", universe: 1, slots: [1]), at: time) }
        }
        Self.expectBoundedLog(lines, "rotating sACN sources")
        #expect(Self.intensity(store, at: 60) == 77 << 8)
        store.queue.sync {
            var t = 60.5
            while t < 63 {  // 2.5 s: under two refill lines, as 30 s were at the engine's 15 s
                store.receive(sacn: SACNData(cid: Self.cid(1_000_000), sourceName: "late", sequence: UInt8(Int(t * 2) % 256), universe: 4000, slots: [1]), at: t)
                store.tick(at: t)
                t += 0.5
            }
        }
        #expect(lines.all.withLock { $0.contains { $0.contains("sacn:4000 from late") } })
    }

    /// 17 Art-Net senders on the patched A 0.0.0, each sending every tick: every packet still reaches the universe.
    @Test func tenMinutesOfSeventeenArtNetSendersLogBounded() {
        let lines = HTTPSServerLogTests.Lines()
        let store = Self.store(.standard(layers: 1, outputs: 1), lines)
        var packets = 0
        Self.tenMinutes(store) { tick, time in
            for n in 0..<17 {
                store.receive(artnet: ArtDmx(sequence: UInt8(tick % 255 + 1), portAddress: 0, data: [UInt8(n), 0]), from: "10.0.0.\(n)", at: time)
                packets += 1
            }
        }
        Self.expectBoundedLog(lines, "17 Art-Net senders")
        #expect(store.snapshot(at: 60).universes.first { $0.id == "artnet:0.0.0" }?.packets == packets, "no packet dropped")
        #expect(lines.all.withLock { $0.contains { $0.hasPrefix("DMX limits reached") && !$0.contains("; 0 Art-Net senders replaced") } })
    }

    /// A burst over 300 sACN universes (past the 256 held) every second, the same sources each time.
    @Test func tenMinutesOfABurstEverySecondLogBounded() {
        let lines = HTTPSServerLogTests.Lines()
        let store = Self.store(.standard(layers: 1, outputs: 1), lines)
        Self.tenMinutes(store) { tick, time in
            guard tick % 2 == 0 else { return }
            for universe in 1...300 {
                store.receive(sacn: SACNData(cid: Self.cid(universe), sourceName: "burst", sequence: UInt8(tick / 2 % 256), universe: UInt16(universe), slots: [1]), at: time)
            }
        }
        Self.expectBoundedLog(lines, "a burst every second")
    }

    /// A known source changing its priority on every packet is announced once, and nothing warns.
    @Test func aSourceAlternatingItsPriorityIsAnnouncedOnce() {
        let lines = HTTPSServerLogTests.Lines()
        let store = Self.store(.standard(layers: 1, outputs: 1, transport: .sacn), lines)
        Self.tenMinutes(store) { tick, time in
            var k = 0
            while k < 4 {
                let n = tick * 4 + k
                store.receive(sacn: SACNData(cid: Self.desk, sourceName: "desk", priority: n % 2 == 0 ? 100 : 120, sequence: UInt8(n % 256), universe: 1, slots: [1]), at: time)
                k += 1
            }
        }
        #expect(Self.count(lines, "DMX receiving") == 1)
        #expect(Self.count(lines, "DMX limits") == 0)
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
