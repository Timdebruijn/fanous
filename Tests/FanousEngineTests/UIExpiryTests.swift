// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Logging
import Testing

@testable import FanousEngine

/// B27: UI values expire 10 minutes after the last UI change, but only while a console is received for the fixture.
struct UIExpiryTests {
    static let logger = Logger(label: "test")
    let layer = FixtureRef.layer(1)
    let intensity = ParameterID.layer(.intensity)

    func hasUI(_ store: DMXStore) -> Bool { store.snapshot().internalValues["Layer 1"]?.contains { $0.source == "ui" } ?? false }

    func console(_ store: DMXStore) {
        store.queue.sync { store.receive(artnet: ArtDmx(portAddress: 0, data: [UInt8](repeating: 0, count: 512)), from: "desk") }
    }

    @Test func staysWithoutConsole() {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Self.logger)
        store.queue.sync {
            store.applyUI(layer, intensity, raw: 100, at: 1000)
            store.expireUI(at: 1000 + 3600)
        }
        #expect(hasUI(store))
        #expect(store.snapshot().uiExpiresIn.isEmpty)
    }

    @Test func expiresWithConsoleAndResetsOnChange() {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Self.logger)
        console(store)
        store.queue.sync {
            store.applyUI(layer, intensity, raw: 100, at: 1000)
            store.expireUI(at: 1500)
            store.applyUI(layer, intensity, raw: 200, at: 1500)  // a change restarts the clock
            store.expireUI(at: 2050)
        }
        #expect(hasUI(store))
        #expect(store.snapshot().uiExpiresIn["Layer 1"] != nil)
        store.queue.sync {
            store.keepUI(layer, at: 2050)  // Keep restarts it too
            store.expireUI(at: 2600)
        }
        #expect(hasUI(store))
        store.queue.sync { store.expireUI(at: 2650) }
        #expect(!hasUI(store))
        #expect(store.snapshot().uiExpiresIn.isEmpty)
    }

    @Test func clockStartsWhenConsoleArrives() {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Self.logger)
        store.queue.sync {
            store.applyUI(layer, intensity, raw: 100, at: 1000)
            store.expireUI(at: 5000)  // no console: held
        }
        console(store)
        store.queue.sync { store.expireUI(at: 5300) }
        #expect(hasUI(store))
        store.queue.sync { store.expireUI(at: 5600) }
        #expect(!hasUI(store))
    }
}
