// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Synchronization
import Testing
import simd

@testable import FanousEngine

final class Box { var value = 0 }

@Suite struct TripleBufferTests {
    @Test func readerSeesTheLatestWriteAndKeepsItWhenNothingIsNew() {
        let buffer = TripleBuffer { Box() }
        #expect(buffer.read().value == 0)
        buffer.write { $0.value = 1 }
        buffer.write { $0.value = 2 }
        #expect(buffer.read().value == 2)
        #expect(buffer.read().value == 2)
        buffer.write { $0.value = 3 }
        #expect(buffer.read().value == 3)
    }

    @Test func writerNeverTouchesTheSlotTheReaderHolds() {
        let buffer = TripleBuffer { Box() }
        buffer.write { $0.value = 10 }
        let held = buffer.read()
        for i in 0..<100 { buffer.write { $0.value = i } }  // many writes while the reader keeps its slot
        #expect(held.value == 10)
        #expect(buffer.read().value == 99)
    }

    @Test func concurrentWriterAndReaderNeverTear() async {
        final class Pair { var a = 0; var b = 0 }
        let buffer = TripleBuffer { Pair() }
        let writer = Task.detached {
            for i in 1...50_000 { buffer.write { $0.a = i; $0.b = -i } }
        }
        var torn = 0
        for _ in 0..<50_000 {
            let p = buffer.read()
            if p.a != -p.b { torn += 1 }
        }
        await writer.value
        #expect(torn == 0)
        #expect(buffer.read().a == 50_000)
    }

    // MARK: Readers other than the render reader (B71)

    @Test func copyReaderLeavesTheNewFlagToTheRenderReader() {
        let buffer = TripleBuffer({ Box() }, copy: { $0.value = $1.value })
        let held = buffer.read()
        buffer.write { $0.value = 1 }
        #expect(buffer.withLatest { $0.value } == 1)
        let next = buffer.read()
        #expect(next !== held)  // the render reader took the new slot itself
        #expect(next.value == 1)
    }

    @Test func copyReaderNeverHandsTheWriterTheRenderReadersSlot() {
        let buffer = TripleBuffer({ Box() }, copy: { $0.value = $1.value })
        let held = buffer.read()
        buffer.write { $0.value = 1 }
        _ = buffer.withLatest { $0.value }  // with `read()` here, the third write below lands in `held`
        for i in 2...4 { buffer.write { $0.value = i } }
        #expect(held.value == 0)
        #expect(buffer.withLatest { $0.value } == 4)
        #expect(buffer.read().value == 4)
    }

    @Test func currentKeepsTheTicksSlotAndLeavesTheNewFlag() {
        let buffer = TripleBuffer { Box() }
        let held = buffer.read()
        buffer.write { $0.value = 1 }
        #expect(buffer.current() === held)  // a second `read()` here would take the new slot and free `held` to the writer
        for i in 2...4 { buffer.write { $0.value = i } }
        #expect(held.value == 0)
        #expect(buffer.read().value == 4)
    }

    @Test func dmxCopyEqualsTheLastPublishedSlot() {
        let store = DMXStore(patch: .standard(layers: 2, outputs: 1), logger: Logger(label: "test"))
        for i in 1...3 {
            store.snapshots.write { slot in
                slot.sequence = UInt64(i)
                slot.receivedAt = Double(i)
                slot.master = Float(i) / 10
                slot.testPattern = i == 2 ? .grid : .off
                slot.layers[1].intensity = Float(i) / 4
                slot.layers[1].playMode = .bounce
                slot.outputs[0].raw = i % 2 == 1
                slot.keystones[1] = matrix_identity_float3x3 * Float(i)
                slot.keystoneInvalid[1] = i == 2
                slot.presets[2] = UInt8(i)
                slot.presetCompare[2] = i == 2
            }
        }
        let published = store.snapshots.read()
        #expect(published.sequence == 3)
        let same = store.snapshots.withLatest {
            $0.sequence == published.sequence && $0.receivedAt == published.receivedAt && $0.master == published.master
                && $0.masterControl == published.masterControl && $0.masterSpeed == published.masterSpeed
                && $0.testPattern == published.testPattern && $0.layers == published.layers && $0.outputs == published.outputs
                && $0.keystones == published.keystones && $0.keystoneInvalid == published.keystoneInvalid
                && $0.presets == published.presets && $0.presetCompare == published.presetCompare
        }
        #expect(same)
    }

    /// DESIGN.md §9.10 item 2: a Keystone fixture patched next to its Output fixture. Both reach the snapshot whichever
    /// changes, in either patch order: the Output fixture rebuilds `outputs` on every publish, so the keystone has its own
    /// array. A refused quad keeps the last valid matrix and is flagged; unpatched is the identity again.
    @Test func keystoneAndOutputFixturesBothApply() {
        let universe = UniverseID(.artnet, 0)
        let output = PatchEntry(fixture: .output(1), universe: universe, address: 1)
        let keystone = PatchEntry(fixture: .keystone(1), universe: universe, address: 9)
        for entries in [[output, keystone], [keystone, output]] {
            let store = DMXStore(patch: Patch(entries: entries), logger: Logger(label: "test"))
            var time = 1000.0
            /// Output 1 intensity, Keystone 1 centred but for the top-left corner.
            func send(intensity: UInt16, topLeft: (x: UInt16, y: UInt16)) {
                var data = [UInt8](repeating: 0, count: 512)
                (data[0], data[1]) = (UInt8(intensity >> 8), UInt8(intensity & 0xFF))
                for (i, raw) in ([topLeft.x, topLeft.y] + Array(repeating: 32768, count: 6)).enumerated() {
                    (data[8 + 2 * i], data[9 + 2 * i]) = (UInt8(raw >> 8), UInt8(raw & 0xFF))
                }
                time += 0.02
                store.queue.sync { store.receive(artnet: ArtDmx(portAddress: 0, data: data), from: "desk", at: time) }
            }
            func state() -> (intensity: Float, topLeft: SIMD2<Float>, invalid: Bool) {
                store.snapshots.withLatest { slot in
                    let k = slot.keystones[0] * SIMD3<Float>(0, 0, 1)
                    return (slot.outputs[0].intensity, SIMD2(k.x, k.y) / k.z, slot.keystoneInvalid[0])
                }
            }
            func near(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool { simd_distance(a, b) < 1e-3 }
            let quarter = ChannelMap.spec(.keystone(.topLeftX)).raw(fromPhysical: 25)
            send(intensity: 32768, topLeft: (quarter, 32768))
            var s = state()
            #expect(abs(s.intensity - 0.5) < 0.01 && near(s.topLeft, SIMD2(0.25, 0)) && !s.invalid, "\(entries.map(\.fixture)): \(s)")
            send(intensity: 65535, topLeft: (quarter, 32768))
            s = state()
            #expect(s.intensity == 1 && near(s.topLeft, SIMD2(0.25, 0)), "an Output change keeps the keystone: \(s)")
            // top-left onto the centre: on the TR–BL diagonal, refused; the output still follows its own fixture
            send(intensity: 0, topLeft: (65535, 65535))
            s = state()
            #expect(s.intensity == 0 && near(s.topLeft, SIMD2(0.25, 0)) && s.invalid, "the last valid keystone stays: \(s)")
            store.setPatch(Patch(entries: [output]))
            store.queue.sync {}
            s = state()
            #expect(near(s.topLeft, .zero) && !s.invalid, "unpatched: the identity")
        }
    }

    /// DESIGN.md §9.10 item 3: Output ch 6 asks for a mapping preset; Compare's lease (`output.show`) wins over it while it
    /// runs, the latest call wins, and the tick lets it expire 5 s after its last renewal. An output without an Output
    /// fixture can still compare.
    @Test func compareWinsOverChannel6AndExpires() {
        let universe = UniverseID(.artnet, 0)
        let store = DMXStore(patch: Patch(entries: [PatchEntry(fixture: .output(1), universe: universe, address: 1)]), logger: Logger(label: "test"))
        let t = 1000.0
        func send(ch6: UInt8, at time: Double) {
            var data = [UInt8](repeating: 0, count: 512)
            (data[0], data[1], data[5]) = (0xFF, 0xFF, ch6)
            store.queue.sync { store.receive(artnet: ArtDmx(portAddress: 0, data: data), from: "desk", at: time) }
        }
        func shown(_ i: Int = 0) -> (preset: UInt8, compare: Bool) { store.snapshots.withLatest { ($0.presets[i], $0.presetCompare[i]) } }
        send(ch6: 3, at: t)
        #expect(shown() == (3, false), "the console's preset")
        store.queue.sync { store.show([1, 2], preset: 5, at: t + 1) }
        #expect(shown() == (5, true) && shown(1) == (5, true), "Compare wins, also on an output without an Output fixture")
        send(ch6: 4, at: t + 2)
        #expect(shown() == (5, true), "a ch 6 change under a running lease")
        store.queue.sync { store.show([1], preset: 6, at: t + 3) }  // a renewal with another preset: the latest wins
        #expect(shown() == (6, true))
        store.queue.sync { store.tick(at: t + 7.9) }
        #expect(shown() == (6, true) && shown(1) == (0, false), "output 2's lease (from t + 1) ran out, output 1's renewal runs to t + 8")
        store.queue.sync { store.tick(at: t + 8) }
        #expect(shown() == (4, false), "expired: back to ch 6")
        store.queue.sync { store.show([1], preset: 7, at: t + 9) }
        store.queue.sync { store.show([1], preset: 0, at: t + 9.5) }
        #expect(shown() == (4, false), "preset 0 ends it at once")
    }

    /// DMX loss with hold "zero" centres a Keystone fixture instead of putting every corner at −50 %: zero for a geometry
    /// offset is no offset, so a keystone universe that drops alone does not shift a lit picture.
    @Test func zeroOnLossCentresTheKeystone() {
        let universe = UniverseID(.artnet, 0)
        let store = DMXStore(patch: Patch(entries: [PatchEntry(fixture: .keystone(1), universe: universe, address: 1)]), logger: Logger(label: "test"))
        var settings = UniverseSettings(for: universe)
        settings.holdOnLoss = .zero
        let time = 1000.0
        store.queue.sync { store.configure([universe: settings], at: time) }
        var data = [UInt8](repeating: 0, count: 512)
        for i in 0..<8 { data[2 * i] = 0x80 }  // 32768: centred
        data[0] = 0xA0  // top-left X +12.5 %
        store.queue.sync { store.receive(artnet: ArtDmx(portAddress: 0, data: data), from: "desk", at: time + 0.02) }
        func topLeft() -> SIMD2<Float> {
            store.snapshots.withLatest { slot in
                let k = slot.keystones[0] * SIMD3<Float>(0, 0, 1)
                return SIMD2(k.x, k.y) / k.z
            }
        }
        #expect(topLeft().x > 0.1, "the console's keystone applies: \(topLeft())")
        store.queue.sync { store.tick(at: time + 10) }
        #expect(simd_length(topLeft()) < 1e-6, "lost with zero: centred, not −50 %: \(topLeft())")
    }

    /// An unpatched layer (Unpatch, Remove last layer, beyond the layer count) no longer plays at its last values, and
    /// an unpatched Master no longer holds the show at its last level: both render as with no console.
    @Test func unpatchedLayerAndMasterFallBackToDefaults() {
        let store = DMXStore(patch: .standard(layers: 2, outputs: 0), logger: Logger(label: "test"))
        for fixture in [FixtureRef.layer(2), .master] { store.setPolicy(.internal, for: fixture) }
        // values in every slot: a publish writes into a slot that holds an older publish
        for raw in UInt16(1)...3 {
            store.queue.sync {
                store.applyUI(.layer(2), .layer(.file), raw: raw, at: 1000)
                store.applyUI(.layer(2), .layer(.intensity), raw: 65535, at: 1000)
                store.applyUI(.master, .master(.intensity), raw: 0, at: 1000)
            }
        }
        let playing = store.snapshots.read()
        #expect(playing.layers[1].file == 3 && playing.layers[1].intensity == 1 && playing.master == 0)
        var patch = Patch.standard(layers: 1, outputs: 0)
        patch.entries.removeAll { $0.fixture == .master }
        store.setPatch(patch)
        _ = store.currentPatch  // the DMX queue has run the patch change
        let slot = store.snapshots.read(), fresh = ParameterSnapshotSlot(maxLayers: 0)
        #expect(slot.layers[1] == LayerParameters())
        #expect(slot.master == fresh.master && slot.masterControl == fresh.masterControl)
        #expect(slot.masterSpeed == fresh.masterSpeed && slot.testPattern == fresh.testPattern)
    }

    /// An unpatched (or removed) Output fixture no longer holds its output at the last values: a re-added output with
    /// the same number and no fixture renders as with no console.
    @Test func unpatchedOutputFallsBackToDefaults() {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Logger(label: "test"))
        store.setPolicy(.internal, for: .output(1))
        // Blackout in every slot: a publish writes into a slot that holds an older publish
        for raw in UInt16(64)...70 { store.queue.sync { store.applyUI(.output(1), .output(.control), raw: raw, at: 1000) } }
        #expect(store.snapshots.read().outputs[0].control == .blackout)
        store.setPatch(.standard(layers: 1, outputs: 0))
        _ = store.currentPatch  // the DMX queue has run the patch change
        #expect(store.snapshots.read().outputs[0] == OutputParameters())
    }

    // MARK: A fixture exists without a patch (DESIGN.md §6.6 item 1)

    static let a0 = UniverseID(.artnet, 0)

    /// Layer 1 on A 0.0.0 at 1, the Master on A 0.0.1 at 1; nothing else patched.
    static func store(fixtures: Set<FixtureRef>, policy: SourcePolicy) -> DMXStore {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 0), fixtures: fixtures, logger: Logger(label: "test"))
        store.setPolicy(policy)
        return store
    }

    /// One console packet on Art-Net port-address `port`, with `bytes` from channel 1.
    static func console(_ store: DMXStore, port: UInt16 = 0, _ bytes: [UInt8], at time: Double) {
        var data = [UInt8](repeating: 0, count: 512)
        data.replaceSubrange(0..<bytes.count, with: bytes)
        store.queue.sync { store.receive(artnet: ArtDmx(portAddress: port, data: data), from: "desk", at: time) }
    }

    @Test func anUnpatchedLayerPlaysFromTheUIUnderInternalAndStaysAtDefaultsUnderDMX() {
        let store = Self.store(fixtures: ProjectDocument.fixtures(layerCount: 2, outputs: []), policy: .internal)
        store.setUI(.layer(2), .layer(.file), raw: 110)
        store.setUI(.layer(2), .layer(.intensity), raw: 65535)
        store.queue.sync {}
        let playing = store.snapshots.withLatest { $0.layers[1] }
        #expect(playing.file == 110 && playing.intensity == 1, "\(playing)")
        store.setPolicy(.dmx)
        store.queue.sync {}
        #expect(store.snapshots.withLatest { $0.layers[1] } == LayerParameters())
    }

    /// Unpatched, or moved to another universe, while the console drives it: the console's look goes (PR #112's
    /// "defaults, not hold"), the UI values stay.
    @Test func unpatchingWhileAConsoleDrivesGoesToDefaultsAndKeepsUIValues() {
        let fixtures = ProjectDocument.fixtures(layerCount: 1, outputs: [])
        let store = Self.store(fixtures: fixtures, policy: .ltp)
        let patched = store.currentPatch
        var unpatched = patched
        unpatched.entries.removeAll { $0.fixture == .layer(1) }
        var moved = patched
        moved.entries = moved.entries.map { $0.fixture == .layer(1) ? PatchEntry(fixture: .layer(1), universe: UniverseID(.artnet, 2), address: 1) : $0 }
        for (time, change) in [(1000.0, unpatched), (2000, moved)] {
            store.setPatch(patched, fixtures: fixtures)
            Self.console(store, [0xFF, 0xFF, 0, 5], at: time)  // full, file 5
            store.queue.sync { store.applyUI(.layer(1), .layer(.positionX), raw: 65535, at: time + 1) }
            let driven = store.snapshots.withLatest { $0.layers[0] }
            #expect(driven.intensity == 1 && driven.file == 5 && driven.positionX == 1, "\(driven)")
            store.setPatch(change, fixtures: fixtures)
            store.queue.sync {}
            var expected = LayerParameters()
            expected.positionX = 1
            #expect(store.snapshots.withLatest { $0.layers[0] } == expected, "\(change.entry(for: .layer(1)).map { "\($0.universe)" } ?? "unpatched")")
        }
    }

    /// No DMX ever received: the Master's default (full) does not compete, so a UI Master at 50 % wins under `htp`.
    @Test func htpWithoutDMXLetsAUIMasterAt50Win() {
        var patch = Patch.standard(layers: 1, outputs: 0)
        patch.entries.removeAll { $0.fixture == .master }
        let store = DMXStore(patch: patch, fixtures: ProjectDocument.fixtures(layerCount: 1, outputs: []), logger: Logger(label: "test"))
        store.setPolicy(.htp)
        store.setUI(.master, .master(.intensity), raw: 32768)
        store.queue.sync {}
        #expect(abs(store.snapshots.withLatest { $0.master } - 0.5) < 0.001)
    }

    /// A console held the Master at its default (full: its change time never moved) and went silent with hold on loss:
    /// the held full still competes, so a UI value below it does not win under `htp`.
    @Test func afterALossWithHoldAHeldDefaultBeatsALowerUIValue() {
        let store = Self.store(fixtures: ProjectDocument.fixtures(layerCount: 1, outputs: []), policy: .htp)
        Self.console(store, port: 1, [0xFF, 0xFF], at: 1000)
        store.queue.sync { store.tick(at: 1010) }
        #expect(store.snapshot(at: 1010).universes.first { $0.id == "artnet:0.0.1" }?.active == false)
        store.queue.sync { store.applyUI(.master, .master(.intensity), raw: 32768, at: 1011) }
        #expect(store.snapshots.withLatest { $0.master } == 1)
    }

    /// "Defaults from the resolver" (a fixture without DMX under `dmx`) and "defaults from the reset" (PR #112, a fixture
    /// without a resolver) are the same values.
    @Test func aFreshResolverGivesTheResetValues() {
        #expect(LayerParameters.from(FixtureResolver(mode: .layer)) == LayerParameters())
        #expect(OutputParameters.from(FixtureResolver(mode: .output)) == OutputParameters())
        let fromResolver = ParameterSnapshotSlot(maxLayers: 0), reset = ParameterSnapshotSlot(maxLayers: 0)
        fromResolver.master = 0
        ParameterSnapshotSlot.from(FixtureResolver(mode: .master), into: fromResolver)
        reset.resetMaster()
        #expect(fromResolver.master == reset.master && fromResolver.masterControl == reset.masterControl)
        #expect(fromResolver.masterSpeed == reset.masterSpeed && fromResolver.testPattern == reset.testPattern)
        let store = DMXStore(patch: Patch(entries: []), fixtures: ProjectDocument.fixtures(layerCount: 1, outputs: [1]), logger: Logger(label: "test"))
        store.queue.sync { store.publish(receivedAt: 0) }
        #expect(store.snapshots.withLatest { $0.keystones[0] == matrix_identity_float3x3 && !$0.keystoneInvalid[0] })
    }

    /// Layer 1…min(layerCount, 32), the Master, and Output n and Keystone n for outputs 1–8: a layer above the count (or
    /// above 32, even when patched) and output 9 have no resolver.
    @Test func onlyTheFixturesThatExistHaveAResolver() {
        let fixtures = ProjectDocument.fixtures(layerCount: 40, outputs: [1, 9])
        #expect(fixtures == Set((1...32).map(FixtureRef.layer) + [.master, .output(1), .keystone(1)]))
        #expect(ProjectDocument.fixtures(layerCount: 3, outputs: []) == [.layer(1), .layer(2), .layer(3), .master])
        let patch = Patch(entries: [PatchEntry(fixture: .layer(33), universe: Self.a0, address: 1)])
        let store = DMXStore(patch: patch, fixtures: ProjectDocument.fixtures(layerCount: 3, outputs: []), logger: Logger(label: "test"))
        #expect(store.resolvedRaw(.layer(3), .layer(.intensity)) != nil)
        #expect(store.resolvedRaw(.layer(4), .layer(.intensity)) == nil)
        #expect(store.resolvedRaw(.layer(33), .layer(.intensity)) == nil)
        #expect(store.resolvedRaw(.output(1), .output(.intensity)) == nil)
    }

    /// The cue engine pushes values only while a fade runs: a layer added while a cue holds its values takes them at once.
    @Test func aLayerAddedWhileACueHoldsValuesTakesThem() {
        let store = Self.store(fixtures: ProjectDocument.fixtures(layerCount: 1, outputs: []), policy: .internal)
        let values = [CueValue(fixture: .layer(2), parameter: .layer(.intensity), raw: 65535), CueValue(fixture: .layer(2), parameter: .layer(.file), raw: 7)]
        var cues = CueEngine(list: CueList(cues: [Cue(number: 1, values: values)]))
        cues.go(at: 0)
        store.setCue(cues.tick(at: 0))  // the fade is over: the runner pushes nothing more
        store.queue.sync {}
        #expect(store.snapshots.withLatest { $0.layers[1] } == LayerParameters())
        store.setPatch(store.currentPatch, fixtures: ProjectDocument.fixtures(layerCount: 2, outputs: []))
        store.queue.sync {}
        let added = store.snapshots.withLatest { $0.layers[1] }
        #expect(added.intensity == 1 && added.file == 7, "\(added)")
        // released before the layer is added: nothing to take
        store.setCue([CueOutput]())
        store.setPatch(store.currentPatch, fixtures: ProjectDocument.fixtures(layerCount: 1, outputs: []))
        store.setPatch(store.currentPatch, fixtures: ProjectDocument.fixtures(layerCount: 2, outputs: []))
        store.queue.sync {}
        #expect(store.snapshots.withLatest { $0.layers[1] } == LayerParameters())
    }

    /// A cue holds Layer 2 on file 7, then Layer 2 is added on a universe whose console sends file 3: under latest wins
    /// the console's value (fed now) beats the cue's (from when the cue ran), as it would on a layer that existed.
    @Test func aLayerAddedOnALiveUniverseGivesTheConsoleTheLatestChange() {
        let store = DMXStore(
            patch: .standard(layers: 2, outputs: 0), fixtures: ProjectDocument.fixtures(layerCount: 1, outputs: []), logger: Logger(label: "test"))
        store.setPolicy(.ltp)
        var cues = CueEngine(list: CueList(cues: [Cue(number: 5, values: [CueValue(fixture: .layer(2), parameter: .layer(.file), raw: 7)])]))
        cues.go(at: 0)
        store.setCue(cues.tick(at: 0))
        store.queue.sync {}
        let now = DMXStore.now
        var bytes = [UInt8](repeating: 0, count: 68)
        (bytes[64], bytes[65], bytes[67]) = (0xFF, 0xFF, 3)  // Layer 2 at 65: full, file 3
        Self.console(store, port: 0, bytes, at: now)
        store.queue.sync { store.applyPatch(.standard(layers: 2, outputs: 0), fixtures: ProjectDocument.fixtures(layerCount: 2, outputs: []), at: now + 1) }
        let file = store.snapshot().fixtures["Layer 2"]?.first { $0.key == "file" }
        #expect(file?.raw == 3 && file?.source == "dmx", "\(String(describing: file))")
    }

    /// A new or changed patch entry on a universe that is being received takes its values at once (a console that sends
    /// only changes may not send for a second): moved to another live universe, patched again (Undo of Unpatch). On a
    /// universe that is not received it is at its defaults.
    @Test func aPatchOnALiveUniverseTakesItsValuesAtOnce() {
        let fixtures = ProjectDocument.fixtures(layerCount: 1, outputs: [])
        let store = DMXStore(patch: .standard(layers: 1, outputs: 0), fixtures: fixtures, logger: Logger(label: "test"))
        Self.console(store, port: 0, [0xFF, 0xFF, 0, 5], at: 1000)  // A 0.0.0: Layer 1 full, file 5
        Self.console(store, port: 2, [0x80, 0x00, 0, 9], at: 1000)  // A 0.0.2: half, file 9
        func layer1() -> LayerParameters { store.snapshots.withLatest { $0.layers[0] } }
        #expect(layer1().intensity == 1 && layer1().file == 5)
        /// Layer 1 on A 0.0.`universe` at 1 (nil: unpatched), the rest as it is.
        func repatch(_ universe: Int?, at time: Double) {
            var patch = store.currentPatch
            patch.entries.removeAll { $0.fixture == .layer(1) }
            if let universe { patch.entries.append(PatchEntry(fixture: .layer(1), universe: UniverseID(.artnet, universe), address: 1)) }
            store.queue.sync { store.applyPatch(patch, fixtures: fixtures, at: time) }
        }
        repatch(2, at: 1000.5)
        #expect(abs(layer1().intensity - 0.5) < 0.01 && layer1().file == 9, "moved to A 0.0.2: \(layer1())")
        repatch(nil, at: 1000.6)
        #expect(layer1() == LayerParameters(), "unpatched")
        repatch(0, at: 1000.7)
        #expect(layer1().intensity == 1 && layer1().file == 5, "patched again: \(layer1())")
        repatch(3, at: 1000.8)
        #expect(layer1() == LayerParameters(), "A 0.0.3 is not received")
        repatch(0, at: 1010)
        #expect(layer1() == LayerParameters(), "A 0.0.0 silent for 10 s: no longer received")
    }

    /// Without `layerCount` (a hand-written project) the layers the engine starts with; outputs above 8 have no fixture.
    @Test func fixturesFromAProject() throws {
        var project = ProjectDocument.initial(patch: .standard(layers: 3, outputs: 0), layerCount: 3, libraryRoot: "/tmp/lib", policy: .dmx)
        try ProjectDocument.setOutputs([OutputConfig(id: 1), OutputConfig(id: 9)], in: &project)
        #expect(ProjectDocument.fixtures(from: project) == [.layer(1), .layer(2), .layer(3), .master, .output(1), .keystone(1)])
        try project.set(.null, at: "/layerCount")
        let layers = ProjectDocument.fixtures(from: project).filter { if case .layer = $0 { true } else { false } }
        #expect(layers == Set((1...ProjectDocument.defaultLayerCount).map(FixtureRef.layer)))
    }

    /// Every output has a Keystone resolver; one with no DMX and no internal value is skipped, so `publish` on the DMX
    /// queue with eight outputs and no Keystone patched allocates nothing more than with no Keystone resolver at all.
    /// Asserted in an optimised build (`scripts/check-mallocs.sh`); a debug build prints the counts.
    @Test(.enabled(if: MallocCounter.availableOrRequired, "malloc_logger not exported by libsystem_malloc on this macOS"))
    func mallocCounterKeystoneRecomputeSkipsUnusedKeystones() throws {
        try #require(MallocCounter.available, "malloc_logger not exported by libsystem_malloc on this macOS")
        let fixtures = ProjectDocument.fixtures(layerCount: 8, outputs: Array(1...8))
        var counts: [Int] = []
        for set in [fixtures, fixtures.filter { if case .keystone = $0 { false } else { true } }] {
            let store = DMXStore(patch: .standard(layers: 8, outputs: 8), fixtures: set, logger: Logger(label: "test"))
            var mallocs = 0
            store.queue.sync {
                // warm: every slot of the triple buffer written once
                store.publish(receivedAt: 0)
                store.publish(receivedAt: 0)
                store.publish(receivedAt: 0)
                mallocs = MallocCounter.count {
                    var i = 0
                    while i < 100 {
                        store.publish(receivedAt: 0)
                        i += 1
                    }
                }
            }
            counts.append(mallocs)
        }
        print("DMXStore.publish × 100, 8 outputs: \(counts[0]) allocations with unused Keystone resolvers, \(counts[1]) without")
        #if !DEBUG
            #expect(counts[0] == counts[1], "the Keystone recompute allocated: \(counts)")
        #endif
    }

    /// Writer at ~1 kHz, the render reader on its own thread and a copy reader at ~2 kHz: no torn slot on either
    /// side, and the render reader's slot never changes under it (also run under `-sanitize=thread`).
    @Test func concurrentWriterRenderReaderAndCopyReader() async throws {
        let run = try await offPool { readerRun(count: 1000, interval: 0.001, otherHz: 2000, other: copyReader) }
        print("B71 stress (1 kHz writer, copy reader): \(run)")
        #expect(run.torn == 0)
        #expect(run.changed == 0)
        #expect(run.otherTorn == 0)
        #expect(run.lastSeen == 1000)
    }

    /// Sparse updates (one per 20 ms) with a 4 Hz copy reader (CITP layer status): the render reader's slot stays
    /// intact and it ends on the last update. `missed` is printed, not asserted: it depends on the reader thread being
    /// scheduled within each 20 ms gap.
    @Test func sparseUpdatesBesideA4HzCopyReader() async throws {
        let run = try await offPool { readerRun(count: 100, interval: 0.02, otherHz: 4, other: copyReader) }
        print("B71 sparse (100 updates 20 ms apart, 4 Hz copy reader): \(run)")
        #expect(run.changed == 0)
        #expect(run.torn == 0)
        #expect(run.lastSeen == 100)
    }
}

final class Twin { var a = 0; var b = 0 }

let copyReader: @Sendable (TripleBuffer<Twin>) -> (Int, Int) = { buffer in buffer.withLatest { ($0.a, $0.b) } }

struct ReaderRun: CustomStringConvertible {
    var missed = 0, changed = 0, torn = 0, lastSeen = 0, otherReads = 0, otherTorn = 0
    var description: String {
        "missed \(missed), changed under the render reader \(changed), torn \(torn), last seen \(lastSeen); "
            + "other reads \(otherReads), torn \(otherTorn)"
    }
}

/// One writer (`count` writes `interval` apart, `a = k, b = −k`), the render reader on its own thread (`read()` about
/// every 0.5 ms, keeping the slot over a 0.2 ms "tick") and another reader at `otherHz` through `other`. Blocking:
/// call it through `offPool`.
func readerRun(count: Int, interval: TimeInterval, otherHz: Double, other: @escaping @Sendable (TripleBuffer<Twin>) -> (Int, Int))
    -> ReaderRun
{
    final class Shared: @unchecked Sendable {  // `run` is written by the render reader only, read after the join
        let stop = Atomic<Bool>(false)
        let lastSeen = Atomic<Int>(0)
        let other = Mutex((reads: 0, torn: 0))
        var run = ReaderRun()
    }
    let buffer = TripleBuffer({ Twin() }, copy: { $0.a = $1.a; $0.b = $1.b })
    let shared = Shared()
    let group = DispatchGroup()
    func thread(_ body: @escaping @Sendable () -> Void) {
        group.enter()
        Thread.detachNewThread {
            body()
            group.leave()
        }
    }
    thread {
        for k in 1...count {
            buffer.write { $0.a = k; $0.b = -k }
            usleep(UInt32(interval * 1e6))
        }
        // the render reader gets up to 2 s to see the last write, not a fixed sleep
        let deadline = Date().addingTimeInterval(2)
        while shared.lastSeen.load(ordering: .relaxed) != count, Date() < deadline { usleep(1000) }
        shared.stop.store(true, ordering: .relaxed)
    }
    thread {
        var seen = [Bool](repeating: false, count: count + 1)
        while !shared.stop.load(ordering: .relaxed) {
            let slot = buffer.read()
            let a = slot.a, b = slot.b
            if a != -b { shared.run.torn += 1 }
            if a > 0, a <= count { seen[a] = true }
            shared.lastSeen.store(a, ordering: .relaxed)
            usleep(200)
            if slot.a != a || slot.b != b { shared.run.changed += 1 }
            usleep(300)
        }
        shared.run.missed = seen.dropFirst().filter { !$0 }.count
    }
    thread {
        while !shared.stop.load(ordering: .relaxed) {
            let (a, b) = other(buffer)
            shared.other.withLock { $0.reads += 1; if a != -b { $0.torn += 1 } }
            usleep(UInt32(1e6 / otherHz))
        }
    }
    group.wait()
    var run = shared.run
    run.lastSeen = shared.lastSeen.load(ordering: .relaxed)
    (run.otherReads, run.otherTorn) = shared.other.withLock { ($0.reads, $0.torn) }
    return run
}
