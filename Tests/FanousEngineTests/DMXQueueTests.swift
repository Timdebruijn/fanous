// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import QuartzCore
import Testing

@testable import FanousEngine

/// B285: readers do not borrow the DMX queue (ADR-0002) for work that grows with the patch.
struct DMXQueueTests {
    /// The engine limits: 32 layers, 8 outputs (and their Keystone fixtures), every universe received and every
    /// parameter holding a UI value, so the live snapshot formats the most it can.
    static func full() -> DMXStore {
        let patch = Patch.standard(layers: ParameterSnapshotSlot.maxLayers, outputs: ParameterSnapshotSlot.maxOutputs)
        let fixtures = ProjectDocument.fixtures(layerCount: ParameterSnapshotSlot.maxLayers, outputs: Array(1...ParameterSnapshotSlot.maxOutputs))
        let store = DMXStore(patch: patch, fixtures: fixtures, logger: testLogger)
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
        print(String(format: "DMX queue costs at the limits: snapshot %.1f µs, OSC setParameter %.2f µs each, resolvedRaw %.1f µs", snapshot * 1e6, osc * 1e6, raw * 1e6))
    }
}
