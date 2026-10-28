// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import QuartzCore
import Testing

@testable import FanousEngine

/// The Sync channel in the compositor (DESIGN.md §23.2–23.3): slaves set their clock from the table, masters fill the
/// packet slot and the local table.
@Suite(.serialized)
struct SyncCompositorTests {
    static let own = UUID(uuidString: "40000000-0000-0000-0000-000000000000")!
    static let remote = UUID(uuidString: "30000000-0000-0000-0000-000000000000")!

    /// `sync.count` layers on one 20-frame 10 fps movie, opened but not decoding: the clocks run, nothing is drawn.
    final class Rig {
        let compositor: Compositor
        let layers: [RenderLayer]
        let receiver = SyncReceiver(machine: SyncCompositorTests.own, logger: Logger(label: "sync-test"))
        let sender = SyncSender(
            machine: SyncCompositorTests.own, settings: SyncSettings(), network: false,
            logger: Logger(label: "sync-test"))
        let metrics = MetricsRing(capacity: 4096)
        let source: MovieSource
        private let parameters: TripleBuffer<ParameterSnapshotSlot>
        private let directory: URL
        private var ticks = 0
        private var sequence: UInt64 = 0
        /// Written by `publish()`, which fills a whole slot (the triple buffer's slots are not copies of each other).
        var roles: [LayerSync]
        var freezeAll = false
        /// Layer 1's in and out point.
        var inOut: (Float, Float) = (0, 1)

        init(_ sync: [LayerSync]) async throws {
            directory = try IngestQueueTests.temporaryDirectory()
            let url = directory.appending(path: "clip.mov")
            try await IngestQueueTests.writeSource(to: url, seconds: 2, audio: false)
            let context = try MetalContext()
            source = try await MovieSource.open(url: url, device: context.device, poolSize: 4)
            parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: sync.count) }
            roles = sync
            compositor = try Compositor(
                context: context, canvasWidth: 64, canvasHeight: 36, fps: 60, maxLayers: sync.count, metrics: metrics,
                parameters: parameters,
                logger: Logger(label: "sync-test"))
            compositor.skipsIdleWork = true  // nobody watches: clocks only, no GPU work
            layers = sync.indices.map { RenderLayer(index: $0) }
            for layer in layers {
                layer.current = playback()
                layer.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
            }
            compositor.setLayers(layers)
            compositor.sync = (receiver, sender)
            publish()
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func playback() -> LayerPlayback {
            let ring = FrameRing(capacity: 4)
            return LayerPlayback(
                key: MediaKey(folder: 1, file: 1), movie: source,
                decoder: LayerDecoder(source: source, ring: ring, logger: Logger(label: "sync-test")), ring: ring)
        }

        func publish() {
            sequence += 1
            let sequence = sequence
            let roles = roles
            let freezeAll = freezeAll
            let inOut = inOut
            parameters.write { slot in
                slot.sequence = sequence
                slot.masterControl = freezeAll ? .freezeAll : .normal
                for (i, role) in roles.enumerated() {
                    slot.layers[i].intensity = 1
                    slot.layers[i].folder = 1
                    slot.layers[i].file = 1
                    slot.layers[i].sync = role
                    slot.layers[i].inPoint = i == 0 ? inOut.0 : 0
                    slot.layers[i].outPoint = i == 0 ? inOut.1 : 1
                }
            }
        }

        func tick(_ n: Int = 1) {
            for _ in 0..<n {
                compositor.tick(target: 3600 + Double(ticks) / 60, drawable: nil)
                ticks += 1
            }
        }

        func position(_ layer: Int) -> Double { layers[layer].current!.clock.position }
        func status(_ layer: Int) -> LayerSyncStatus { layers[layer].syncStatus.withLock { $0 } }

        /// A clock from another machine for `group`, received `age` seconds ago (10 fps, by default playing at 1×).
        func inject(
            group: Int, position: Double, age: Double = 0, direction: Int8 = 1, finished: Bool = false, rate: Float = 10
        ) {
            let clock = SyncPacket.Layer(
                group: UInt8(group), layer: 7, mediaKey: 0x0101, fps: 10, position: position, direction: direction,
                finished: finished, rate: rate)
            receiver.table.withLock {
                $0.offer(clock, from: SyncCompositorTests.remote, at: CACurrentMediaTime() - age)
            }
        }
    }

    @Test func aSlaveFollowsItsMasterAndFreewheelsWhenTheEntryGoesStale() async throws {
        let rig = try await Rig([.slave(group: 1)])
        rig.tick()
        #expect(rig.status(0).state == .noMaster, "no entry ever: plays on its own clock")
        #expect(abs(rig.position(0) - 10.0 / 60) < 1e-9, "its own clock advanced")

        rig.inject(group: 1, position: 5)
        rig.tick()
        #expect(rig.status(0).state == .locked)
        #expect(rig.status(0).master?.machine == Self.remote)
        #expect(
            rig.position(0) >= 5 && rig.position(0) < 5.05,
            "set from the entry, extrapolated by its age: \(rig.position(0))")
        rig.inject(group: 1, position: 12)
        rig.tick()
        #expect(rig.position(0) >= 12 && rig.position(0) < 12.05, "follows the next entry: \(rig.position(0))")

        // no new entry: the one there ages past the lock window, the clock runs on at the entry's rate
        rig.inject(group: 1, position: 3, age: 0.5)
        let before = rig.position(0)
        rig.tick()
        #expect(rig.status(0).state == .freewheel)
        #expect(
            abs(rig.position(0) - (before + 10.0 / 60)) < 1e-9, "advanced by rate × dt, not set to the stale position")
        rig.inject(group: 1, position: 3, age: 3)
        rig.tick()
        #expect(rig.status(0).state == .lost)
        rig.inject(group: 1, position: 8)
        rig.tick()
        #expect(rig.status(0).state == .locked)
        #expect(rig.position(0) >= 8 && rig.position(0) < 8.05, "relocked")
    }

    @Test func aMasterLandsInTheSlotAndALocalSlaveFollowsInTheSameTick() async throws {
        let rig = try await Rig([.master(group: 2), .slave(group: 2), .off])
        rig.tick(5)
        let slot = rig.sender.slots.read()
        #expect(slot.packet.machineID == Self.own)
        #expect(slot.packet.tick == UInt32(rig.compositor.ticks.load(ordering: .relaxed)))
        let clock = try #require(slot.packet.layers.first)
        #expect(slot.packet.layers.count == 1, "only the master")
        #expect(
            clock
                == SyncPacket.Layer(
                    group: 2, layer: 1, mediaKey: 0x0101, fps: 10, position: rig.position(0), direction: 1,
                    finished: false, rate: 10))
        #expect(rig.position(1) == rig.position(0), "zero offset inside one machine")
        #expect(rig.status(1).state == .locked)
        #expect(rig.status(1).master?.machine == Self.own)
        #expect(rig.status(0).role == .master(group: 2) && rig.status(0).state == nil)
        #expect(
            rig.receiver.table.withLock { $0.entries[1]?.machine } == Self.own,
            "the local table holds the master for the next tick")
        #expect(abs(rig.position(2) - 5 * 10.0 / 60) < 1e-9, "a layer with Sync off plays on its own")

        // in == out: the master's clock stands, so it sends rate 0
        rig.inOut = (0.5, 0.5)
        rig.publish()
        rig.tick()
        #expect(rig.sender.slots.read().packet.layers.first?.rate == 0)
    }

    /// A dissolve on a slave: the new file follows the master, the outgoing one keeps its own clock.
    @Test func aSlavesOutgoingPictureKeepsItsOwnClock() async throws {
        let rig = try await Rig([.slave(group: 1)])
        let outgoing = rig.playback()
        rig.layers[0].outgoing = outgoing
        rig.layers[0].dissolveStart = 3600
        rig.layers[0].dissolveDuration = 10
        rig.inject(group: 1, position: 15)
        rig.tick(3)
        #expect(rig.position(0) >= 15, "the current file follows")
        #expect(
            abs(outgoing.clock.position - 3 * 10.0 / 60) < 1e-9, "the outgoing one plays on: \(outgoing.clock.position)"
        )
        #expect(!outgoing.following)
    }

    /// Leaving the group gives the layer its own direction and end back.
    @Test func aSlaveThatStopsFollowingDropsTheMastersDirectionAndEnd() async throws {
        let rig = try await Rig([.slave(group: 1)])
        rig.inject(group: 1, position: 4, direction: -1, finished: true, rate: 0)
        rig.tick()
        #expect(rig.layers[0].current!.clock.direction == -1 && rig.layers[0].current!.clock.finished)
        rig.roles = [.off]
        rig.publish()
        rig.tick()
        let clock = rig.layers[0].current!.clock
        #expect(clock.direction == 1 && !clock.finished)
        #expect(abs(clock.position - (4 + 10.0 / 60)) < 1e-9, "forward on its own loop: \(clock.position)")
    }

    /// Freeze-all holds a locked slave like any other layer; the release relocks it.
    @Test func freezeAllHoldsASlave() async throws {
        let rig = try await Rig([.slave(group: 1)])
        rig.inject(group: 1, position: 6)
        rig.tick()
        let held = rig.position(0)
        rig.freezeAll = true
        rig.publish()
        rig.inject(group: 1, position: 9)
        rig.tick(2)
        #expect(rig.position(0) == held, "held while frozen")
        #expect(rig.status(0).state == .locked)
        rig.freezeAll = false
        rig.publish()
        rig.inject(group: 1, position: 11)
        rig.tick()
        #expect(rig.position(0) >= 11 && rig.position(0) < 11.05, "relocked")
    }

    /// The compositor's CPU time per idle tick with 32 file layers, Sync off and all masters (printed), and no
    /// allocation on the ticking thread in steady state (§4.6), in an optimised build.
    @Test func printMasterSlotCost() async throws {
        for role in [LayerSync.off, .master(group: 1)] {
            let rig = try await Rig(Array(repeating: role, count: SyncPacket.maxLayers))
            rig.tick(120)
            // Counted on this thread only (B89); the process-wide `blocks_in_use` delta is printed for information: in
            // a parallel run other suites allocate and free in the same window. The rule holds for the optimised build:
            // a debug tick allocates for unspecialised generics (see `MallocCounter`), so a debug run prints the count
            // and `scripts/test.sh -c release -Xswiftc -enable-testing --filter printMasterSlotCost` checks it.
            var before = malloc_statistics_t()
            malloc_zone_statistics(nil, &before)
            let allocations = MallocCounter.count { rig.tick(1200) }
            var after = malloc_statistics_t()
            malloc_zone_statistics(nil, &after)
            let summary = rig.metrics.summary(seconds: 1e9, now: 1e9)
            #if !DEBUG
                #expect(allocations == 0, "\(role): \(allocations) allocations on the ticking thread")
            #endif
            print(
                String(
                    format: "sync %@ × 32: cpu p50 %.1f µs  p99 %.1f µs  mallocs on the ticking thread %d  "
                        + "process-wide Δ %d blocks",
                    "\(role)", summary.cpuP50 * 1000, summary.cpuP99 * 1000, allocations,
                    Int(after.blocks_in_use) - Int(before.blocks_in_use)))
        }
    }
}
