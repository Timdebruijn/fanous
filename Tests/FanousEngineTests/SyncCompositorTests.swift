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
        private let directory: URL
        private var ticks = 0

        init(_ sync: [LayerSync]) async throws {
            directory = try IngestQueueTests.temporaryDirectory()
            let url = directory.appending(path: "clip.mov")
            try await IngestQueueTests.writeSource(to: url, seconds: 2, audio: false)
            let context = try MetalContext()
            let source = try await MovieSource.open(url: url, device: context.device, poolSize: 4)
            let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: sync.count) }
            parameters.write { slot in
                slot.sequence = 1
                for (i, role) in sync.enumerated() {
                    slot.layers[i].intensity = 1
                    slot.layers[i].folder = 1
                    slot.layers[i].file = 1
                    slot.layers[i].sync = role
                }
            }
            compositor = try Compositor(
                context: context, canvasWidth: 64, canvasHeight: 36, fps: 60, maxLayers: sync.count, metrics: metrics,
                parameters: parameters,
                logger: Logger(label: "sync-test"))
            compositor.skipsIdleWork = true  // nobody watches: clocks only, no GPU work
            layers = sync.indices.map { RenderLayer(index: $0) }
            for layer in layers {
                let ring = FrameRing(capacity: 4)
                layer.current = LayerPlayback(
                    key: MediaKey(folder: 1, file: 1), movie: source,
                    decoder: LayerDecoder(source: source, ring: ring, logger: Logger(label: "sync-test")),
                    ring: ring)
                layer.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
            }
            compositor.setLayers(layers)
            compositor.sync = (receiver, sender)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func tick(_ n: Int = 1) {
            for _ in 0..<n {
                compositor.tick(target: 3600 + Double(ticks) / 60, drawable: nil)
                ticks += 1
            }
        }

        func position(_ layer: Int) -> Double { layers[layer].current!.clock.position }
        func status(_ layer: Int) -> LayerSyncStatus { layers[layer].syncStatus.withLock { $0 } }

        /// A clock from another machine for `group`, received `age` seconds ago (10 fps, playing at 1×).
        func inject(group: Int, position: Double, age: Double = 0) {
            let clock = SyncPacket.Layer(
                group: UInt8(group), layer: 7, mediaKey: 0x0101, fps: 10, position: position, direction: 1,
                finished: false, rate: 10)
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

        // no new entry: the one there ages past 1.5 ticks, the clock runs on at the entry's rate
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
    }

    /// Printed, not asserted: the compositor's CPU time per idle tick with 32 file layers, Sync off and all masters.
    @Test func printMasterSlotCost() async throws {
        for role in [LayerSync.off, .master(group: 1)] {
            let rig = try await Rig(Array(repeating: role, count: SyncPacket.maxLayers))
            rig.tick(120)
            var before = malloc_statistics_t()
            malloc_zone_statistics(nil, &before)
            rig.tick(1200)
            var after = malloc_statistics_t()
            malloc_zone_statistics(nil, &after)
            let summary = rig.metrics.summary(seconds: 1e9, now: 1e9)
            print(
                String(
                    format: "sync %@ × 32: cpu p50 %.1f µs  p99 %.1f µs  malloc Δ %d blocks", "\(role)",
                    summary.cpuP50 * 1000, summary.cpuP99 * 1000,
                    Int(after.blocks_in_use) - Int(before.blocks_in_use)))
        }
    }
}
