// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import QuartzCore
import Synchronization
import Testing

@testable import FanousEngine

/// B285: readers do not borrow the DMX queue (ADR-0002) for work that grows with the patch.
struct DMXQueueTests {
    /// The engine limits: 32 layers, 8 outputs (and their Keystone fixtures), every universe received and every
    /// parameter holding a UI value that wins (latest wins), so the live snapshot formats the most it can.
    static func full() -> DMXStore {
        let patch = Patch.standard(layers: ParameterSnapshotSlot.maxLayers, outputs: ParameterSnapshotSlot.maxOutputs)
        let fixtures = ProjectDocument.fixtures(layerCount: ParameterSnapshotSlot.maxLayers, outputs: Array(1...ParameterSnapshotSlot.maxOutputs))
        let store = DMXStore(patch: patch, fixtures: fixtures, logger: testLogger)
        store.setPolicy(.ltp)
        store.queue.sync {
            for universe in 0..<patch.universes.count {
                store.receive(artnet: ArtDmx(portAddress: UInt16(universe), data: (0..<512).map { UInt8($0 & 0xFF) }), from: "desk", at: 1)
            }
            for fixture in fixtures {
                for spec in ChannelMap.specs(for: fixture.mode) { store.applyUI(fixture, spec.id, raw: 1, at: 1) }
            }
        }
        return store
    }

    static func median(_ runs: Int, _ body: () -> Void) -> Double {
        var times: [Double] = []
        for _ in 0..<runs {
            let started = CACurrentMediaTime()
            body()
            times.append(CACurrentMediaTime() - started)
        }
        return times.sorted()[runs / 2]
    }

    /// Prints what the readers cost at the limits (the PR body quotes it; numbers from an optimised build).
    @Test(.offPool) func printDMXQueueCosts() {
        let store = Self.full()
        let snapshot = Self.median(200) { _ = store.snapshot(at: 2) }
        let osc = Self.median(20) {
            store.queue.sync { for _ in 0..<4000 { store.apply(.setParameter(.layer(1), .layer(.intensity), raw: 100)) } }
        } / 4000
        let raw = Self.median(200) { _ = store.resolvedRaw() }
        // the part of a snapshot that holds the queue: up to the hook after the copy
        let copied = Mutex(0.0)
        store.whileFormatting = { copied.withLock { $0 = CACurrentMediaTime() } }
        var held: [Double] = []
        for _ in 0..<200 {
            let started = CACurrentMediaTime()
            _ = store.snapshot(at: 2)
            held.append(copied.withLock { $0 } - started)
        }
        print(
            String(
                format: "DMX queue costs at the limits: snapshot %.1f µs (%.1f µs of it on the queue), OSC setParameter %.2f µs each, resolvedRaw %.1f µs",
                snapshot * 1e6, held.sorted()[100] * 1e6, osc * 1e6, raw * 1e6))
    }

    /// The snapshot is formatted after the copy, with the DMX queue free: a block queued on it runs meanwhile. On main
    /// the whole snapshot ran inside `queue.sync` (1.0 ms at the limits, measured).
    @Test(.offPool) func theSnapshotFormatsOffTheQueue() {
        let store = Self.full()
        let free = Mutex<[Bool]>([])
        store.whileFormatting = { [queue = store.queue] in
            let ran = DispatchSemaphore(value: 0)
            queue.async { ran.signal() }
            let ok = ran.wait(timeout: .now() + 5) == .success
            free.withLock { $0.append(ok) }
        }
        let snapshot = store.snapshot(at: 2)
        #expect(free.withLock { $0 } == [true])
        // the copy formats as before: every fixture, its policy, its UI values and the countdown (the desk is on)
        #expect(snapshot.fixtures.count == 32 + 1 + 8 + 8)
        #expect(snapshot.fixtures["Layer 1"]?.first { $0.key == "intensity" }?.source == "ui")
        #expect(snapshot.internalValues["Output 8"]?.isEmpty == false)
        #expect(snapshot.policies["Master"] == "ltp")
        #expect(snapshot.uiExpiresIn["Layer 1"] == 599)
        #expect(snapshot.universes.count == 5 && snapshot.universes.allSatisfy { $0.active && $0.packets == 1 })
    }

    /// The same OSC value again publishes nothing (a 64 KiB bundle of one message is about 4000, each a whole publish
    /// on main: 0.12 ms at the limits); a new value publishes once, and so does the media pair.
    @Test func anUnchangedOSCValuePublishesNothing() {
        let store = DMXStore(patch: .standard(layers: 2, outputs: 1), logger: testLogger)
        store.setPolicy(.internal)
        store.queue.sync {
            let start = store.sequence
            store.apply(.setParameter(.layer(1), .layer(.intensity), raw: 100))
            #expect(store.sequence == start + 1, "the first value publishes")
            for _ in 0..<4000 { store.apply(.setParameter(.layer(1), .layer(.intensity), raw: 100)) }
            #expect(store.sequence == start + 1, "the same value 4000 times publishes nothing")
            store.apply(.setParameter(.layer(1), .layer(.intensity), raw: 101))
            #expect(store.sequence == start + 2)
            store.apply(.setMedia(layer: 1, folder: 3, file: 4))
            store.apply(.setMedia(layer: 1, folder: 3, file: 4))
            #expect(store.sequence == start + 3)
            store.apply(.setParameter(.layer(9), .layer(.intensity), raw: 1))
            #expect(store.sequence == start + 3, "a fixture that does not exist publishes nothing")
        }
        #expect(store.snapshot(at: 0).fixtures["Layer 1"]?.first { $0.key == "intensity" }?.raw == 101)
    }
}
