// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Logging
import Testing

@testable import FanousEngine

/// B27: UI values expire after masking a live console for 10 minutes since the last UI change; time without console
/// traffic, or with the console winning, pauses the count. All times are injected.
struct UIExpiryTests {
    let layer = FixtureRef.layer(1)
    let intensity = ParameterID.layer(.intensity)

    func store(_ policy: SourcePolicy) -> DMXStore {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        store.setPolicy(policy, for: layer)
        return store
    }

    /// A fixture patched after the project's policy was set takes that policy, so its UI values apply (before, a new
    /// patch entry kept the default `dmx` until the policy itself changed).
    @Test func aFixturePatchedLaterTakesTheProjectPolicy() {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        store.setPolicy(.ltp)
        store.setPatch(Patch(entries: store.currentPatch.entries + [PatchEntry(fixture: .layer(2), universe: UniverseID(.artnet, 1), address: 1)]))
        store.setUI(.layer(2), intensity, raw: 40000)
        store.queue.sync {}
        let value = store.snapshot().fixtures["Layer 2"]?.first { $0.key == "intensity" }
        #expect(value?.raw == 40000 && value?.source == "ui", "\(String(describing: value))")
    }

    /// A policy change reaches the render snapshot at once, without waiting for a DMX change.
    @Test func aPolicyChangeReachesTheOutputAtOnce() {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        store.setUI(layer, intensity, raw: 65535)
        store.queue.sync {}
        let rendered = { store.snapshots.withLatest { $0.layers[0].intensity } }
        #expect(rendered() == 0, "dmx: the UI value waits")
        store.setPolicy(.ltp)
        store.queue.sync {}
        #expect(rendered() == 1, "ltp: the UI value renders")
    }

    func hasUI(_ store: DMXStore) -> Bool { store.snapshot().internalValues["Layer 1"]?.contains { $0.source == "ui" } ?? false }

    /// Seconds left as published in the live document.
    func left(_ store: DMXStore, at now: Double) -> Double? { store.snapshot(at: now).uiExpiresIn["Layer 1"] }

    /// One console packet (Layer 1 is on Art-Net 0.0.0) and the housekeeping tick at the same moment.
    func console(_ store: DMXStore, at now: Double, level: UInt8 = 0) {
        store.queue.sync {
            store.receive(artnet: ArtDmx(portAddress: 0, data: [UInt8](repeating: level, count: 512)), from: "desk", at: now)
            store.tick(at: now)
        }
    }

    func tick(_ store: DMXStore, at now: Double) { store.queue.sync { store.tick(at: now) } }

    @Test func staysWithoutConsole() {
        let store = store(.internal)
        store.queue.sync { store.applyUI(layer, intensity, raw: 100, at: 1000) }
        tick(store, at: 1000 + 3600)
        #expect(hasUI(store))
        #expect(left(store, at: 1000 + 3600) == nil)
    }

    @Test func countdownPausesOnLossResetsOnChangeAndKeep() {
        let store = store(.internal)
        console(store, at: 1000)
        store.queue.sync { store.applyUI(layer, intensity, raw: 100, at: 1000) }
        #expect(left(store, at: 1000) == 600)
        console(store, at: 1100)
        #expect(left(store, at: 1100) == 500)

        // console lost: the count pauses (no countdown shown) and does not restart
        tick(store, at: 1200)
        #expect(left(store, at: 1200) == nil)
        tick(store, at: 1999)
        console(store, at: 2000)
        #expect(left(store, at: 2000) == 499)

        store.queue.sync { store.applyUI(layer, intensity, raw: 200, at: 2000) }
        #expect(left(store, at: 2000) == 600)
        console(store, at: 2300)
        #expect(left(store, at: 2300) == 300)
        store.queue.sync { store.keepUI(layer, at: 2300) }
        #expect(left(store, at: 2300) == 600)

        console(store, at: 2899)
        #expect(hasUI(store))
        console(store, at: 2900)
        #expect(!hasUI(store))
        #expect(left(store, at: 2900) == nil)
        #expect(store.queue.sync { store.uiClock.isEmpty })
    }

    @Test func onlyCountsWhileTheUIWins() {
        // policy dmx: the UI value is not shown, so it masks nothing
        let dmx = store(.dmx)
        console(dmx, at: 1000)
        dmx.queue.sync { dmx.applyUI(layer, intensity, raw: 100, at: 1000) }
        #expect(left(dmx, at: 1000) == nil)
        console(dmx, at: 5000)
        #expect(hasUI(dmx))

        // htp: the console's full intensity is higher than the UI's 100, so the console wins
        let htp = store(.htp)
        console(htp, at: 1000, level: 255)
        htp.queue.sync { htp.applyUI(layer, intensity, raw: 100, at: 1000) }
        #expect(left(htp, at: 1000) == nil)
        console(htp, at: 5000, level: 255)
        #expect(hasUI(htp))
        // console pulled to 0: the UI value is now the higher one and the count runs
        console(htp, at: 5001, level: 0)
        #expect(left(htp, at: 5001) == 599)  // the interval up to the tick that sees the UI win counts whole
        #expect(left(htp, at: 5100) == 500)
    }

    @Test func clockDroppedWhenUIValuesAreGone() {
        let store = store(.internal)
        store.queue.sync {
            store.applyUI(layer, intensity, raw: 100, at: 1000)
            store.apply(.setParameter(layer, intensity, raw: 7))  // OSC overwrites the only UI value
            store.tick(at: 1001)
        }
        #expect(store.queue.sync { store.uiClock.isEmpty })

        store.queue.sync { store.applyUI(layer, intensity, raw: 100, at: 1002) }
        store.releaseUI(layer)
        #expect(store.queue.sync { store.uiClock.isEmpty })
    }

    /// B288: Release, a MIDI release and the expiry give the parameter back to the cue value the UI or MIDI value
    /// replaced in the one internal slot, with the cue's own stamp: under ltp a console change older than the cue does
    /// not take it (before: stamp 0, the console's stale 10000 showed).
    @Test func aReleasedControllerValueGivesTheParameterBackToTheCue() {
        let cue = CueValue(fixture: layer, parameter: intensity, raw: 30000)
        let ltp = store(.ltp)
        var data = [UInt8](repeating: 0, count: 512)
        (data[0], data[1]) = (0x27, 0x10)  // 10000, before the cue
        ltp.queue.sync { ltp.receive(artnet: ArtDmx(portAddress: 0, data: data), from: "desk", at: DMXStore.now) }
        ltp.setCue([cue], changed: [cue])
        #expect(ltp.resolvedRaw(layer, intensity) == 30000)
        ltp.setUI(layer, intensity, raw: 50000)
        #expect(ltp.resolvedRaw(layer, intensity) == 50000)
        ltp.releaseUI(layer)
        #expect(ltp.resolvedRaw(layer, intensity) == 30000, "Release under ltp")

        let midi = store(.internal)
        midi.setCue([cue], changed: [cue])
        midi.setMIDI(layer, intensity, raw: 50000)
        #expect(midi.resolvedRaw(layer, intensity) == 50000)
        midi.releaseMIDI([(layer, intensity)])
        #expect(midi.resolvedRaw(layer, intensity) == 30000, "a MIDI release")

        let expiry = store(.internal)
        expiry.setCue([cue], changed: [cue])
        console(expiry, at: 1000)
        expiry.queue.sync { expiry.applyUI(layer, intensity, raw: 50000, at: 1000) }
        console(expiry, at: 1599)
        #expect(expiry.resolvedRaw(layer, intensity) == 50000)
        console(expiry, at: 1600)
        #expect(expiry.resolvedRaw(layer, intensity) == 30000, "the expiry")
    }
}
