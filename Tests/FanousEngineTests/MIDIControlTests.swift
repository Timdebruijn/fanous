// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Synchronization
import Testing

@testable import FanousEngine

/// B36 with injected messages: no CoreMIDI device is opened (a virtual source for a real-port test stays out of CI).
struct MIDIControlTests {
    static let logger = Logger(label: "test")

    static func settings(_ map: [MIDIMapping], mscDevice: Int = 0, mscFormat: Int? = nil) -> MIDISettings {
        var s = MIDISettings()
        s.mscDevice = mscDevice
        s.mscFormat = mscFormat
        s.map = map.enumerated().map { i, m in
            var m = m
            m.id = "m\(i)"
            return m
        }
        return s
    }

    @Test func controllersBecomeParameterValues() {
        var cc = MIDIMapping(channel: 1, kind: .cc, number: 7, target: "fixture:Layer 2/intensity")
        cc.low = 0.5
        let fine = MIDIMapping(kind: .cc14, number: 1, target: "master/intensity")
        let program = MIDIMapping(source: "APC", channel: 1, kind: .pc, number: nil, target: "fixture:Layer 1/file")
        var mapper = MIDIMapper(settings: Self.settings([cc, fine, program]))
        func run(_ m: MIDIMessage, from source: String = "APC") -> [MIDIMapper.Action] { mapper.handle(m, from: source) { _, _ in nil } }
        // 7-bit: 0…127 across low…high of a 16-bit parameter; another channel does nothing
        #expect(run(.controlChange(channel: 0, controller: 7, value: 127)) == [.set(.layer(2), .layer(.intensity), 65535)])
        #expect(run(.controlChange(channel: 0, controller: 7, value: 0)) == [.set(.layer(2), .layer(.intensity), 32768)])
        #expect(run(.controlChange(channel: 1, controller: 7, value: 0)) == [])
        // 14-bit per MIDI 1.0: an MSB resets the LSB (msb << 7), also once the pair is known; the LSB refines it
        #expect(run(.controlChange(channel: 3, controller: 1, value: 64)) == [.set(.master, .master(.intensity), 32770)])
        #expect(run(.controlChange(channel: 3, controller: 33, value: 127)) == [.set(.master, .master(.intensity), 33278)])
        #expect(run(.controlChange(channel: 3, controller: 1, value: 127)) == [.set(.master, .master(.intensity), 65027)])
        #expect(run(.controlChange(channel: 3, controller: 33, value: 127)) == [.set(.master, .master(.intensity), 65535)])
        // the MSB is kept per source: another source's LSB does not complete this one's
        #expect(mapper.handle(.controlChange(channel: 3, controller: 33, value: 127), from: "APC", uid: 2) { _, _ in nil } == [.set(.master, .master(.intensity), 508)])
        mapper.forget(uid: 0)
        #expect(run(.controlChange(channel: 3, controller: 33, value: 0)) == [.set(.master, .master(.intensity), 0)], "forgotten with its source")
        // program change: only from the named source; 8-bit file parameter
        #expect(run(.programChange(channel: 0, program: 127)) == [.set(.layer(1), .layer(.file), 255)])
        #expect(run(.programChange(channel: 0, program: 127), from: "Keyboard") == [])
    }

    @Test func notesAndControllersFireCues() {
        let go = MIDIMapping(kind: .note, number: 36, target: "cue.go")
        let back = MIDIMapping(kind: .cc, number: 20, target: "cue.back")
        let three = MIDIMapping(kind: .note, number: 40, target: "cue.goto", cue: 3)
        let programs = MIDIMapping(kind: .pc, number: nil, target: "cue.goto")
        var mapper = MIDIMapper(settings: Self.settings([go, back, three, programs], mscDevice: 5))
        func run(_ m: MIDIMessage) -> [MIDIMapper.Action] { mapper.handle(m, from: "APC") { _, _ in nil } }
        #expect(run(.noteOn(channel: 9, note: 36, velocity: 1)) == [.cueGo])
        #expect(run(.noteOff(channel: 9, note: 36, velocity: 0)) == [])
        #expect(run(.noteOn(channel: 0, note: 40, velocity: 127)) == [.cueGoto(3)])
        // a controller as a button: once when it rises past half way, not while it stays up
        #expect(run(.controlChange(channel: 0, controller: 20, value: 127)) == [.cueBack])
        #expect(run(.controlChange(channel: 0, controller: 20, value: 100)) == [])
        #expect(run(.controlChange(channel: 0, controller: 20, value: 0)) == [])
        #expect(run(.controlChange(channel: 0, controller: 20, value: 64)) == [.cueBack])
        // any program change: program n (0-based) fires cue n + 1
        #expect(run(.programChange(channel: 0, program: 4)) == [.cueGoto(5)])
        // MSC: our device id or the all-call; GO with a cue is a go to; STOP and RESUME do nothing
        // MSC (video format by default): our device id or the all-call; GO with a cue is a go to; STOP and RESUME do nothing
        #expect(run(.showControl(MSCMessage(deviceID: 5, format: 0x30, command: 1))) == [.cueGo])
        #expect(run(.showControl(MSCMessage(deviceID: 0x7F, format: 0x3F, command: 1, cue: "12.5"))) == [.cueGoto(12.5)])
        #expect(run(.showControl(MSCMessage(deviceID: 5, format: 0x7F, command: 1))) == [.cueGo], "all-types")
        #expect(run(.showControl(MSCMessage(deviceID: 6, format: 0x30, command: 1))) == [])
        #expect(run(.showControl(MSCMessage(deviceID: 5, format: 0x30, command: 2))) == [])
        #expect(run(.showControl(MSCMessage(deviceID: 5, format: 0x01, command: 1))) == [], "a lighting GO is for the desk")
        // a cue that is there but no number never becomes a plain GO
        #expect(run(.showControl(MSCMessage(deviceID: 5, format: 0x30, command: 1, cue: "1.2.3"))) == [])
        #expect(run(.showControl(MSCMessage(deviceID: 5, format: 0x30, command: 1, cue: "1\u{7}"))) == [])
        var lighting = MIDIMapper(settings: Self.settings([], mscDevice: 5, mscFormat: 0x01))
        #expect(lighting.handle(.showControl(MSCMessage(deviceID: 5, format: 0x01, command: 1)), from: "x") { _, _ in nil } == [.cueGo])
        #expect(lighting.handle(.showControl(MSCMessage(deviceID: 5, format: 0x30, command: 1)), from: "x") { _, _ in nil } == [])
    }

    @Test func toggleAndPickup() {
        var toggle = MIDIMapping(kind: .note, number: 50, target: "fixture:Output 1/intensity", curve: .toggle)
        toggle.low = 0.25
        let fader = MIDIMapping(kind: .cc, number: 1, target: "fixture:Layer 1/intensity", pickup: true)
        var mapper = MIDIMapper(settings: Self.settings([toggle, fader]))
        var shown: UInt16 = 40000  // the value the resolver shows (set by a console)
        func run(_ m: MIDIMessage) -> [MIDIMapper.Action] {
            let actions = mapper.handle(m, from: "x") { _, _ in shown }
            for case .set(_, _, let raw) in actions { shown = raw }
            return actions
        }
        #expect(run(.noteOn(channel: 0, note: 50, velocity: 127)).first == .set(.output(1), .output(.intensity), 65535))
        #expect(run(.noteOff(channel: 0, note: 50, velocity: 0)) == [])
        #expect(run(.noteOn(channel: 0, note: 50, velocity: 127)).first == .set(.output(1), .output(.intensity), 16384))
        shown = 40000
        // 40000 ≈ CC 77.7: the fader is ignored below it and takes over once it moves across
        #expect(run(.controlChange(channel: 0, controller: 1, value: 10)) == [])
        #expect(run(.controlChange(channel: 0, controller: 1, value: 70)) == [])
        #expect(run(.controlChange(channel: 0, controller: 1, value: 80)) == [.set(.layer(1), .layer(.intensity), 41282)])
        #expect(run(.controlChange(channel: 0, controller: 1, value: 20)) == [.set(.layer(1), .layer(.intensity), 10320)])
        // something else moved the value: let go until the fader reaches it again (within one step counts)
        shown = 60000
        #expect(run(.controlChange(channel: 0, controller: 1, value: 30)) == [])
        #expect(run(.controlChange(channel: 0, controller: 1, value: 116)) == [.set(.layer(1), .layer(.intensity), 59859)])
    }

    @Test func learnFindsTheControl() {
        var learner = MIDILearner()
        #expect(learner.feed(.noteOff(channel: 0, note: 1, velocity: 0), from: "A") == nil)
        #expect(learner.feed(.noteOn(channel: 2, note: 36, velocity: 9), from: "A") == MIDIMapping(source: "A", channel: 3, kind: .note, number: 36, target: ""))
        #expect(learner.feed(.controlChange(channel: 0, controller: 48, value: 9), from: "A")?.kind == .cc)
        // controller 0–31 waits one message: its LSB makes it 14-bit, anything else a plain controller
        #expect(learner.feed(.controlChange(channel: 0, controller: 7, value: 9), from: "A") == nil)
        #expect(learner.feed(.controlChange(channel: 0, controller: 39, value: 9), from: "A") == MIDIMapping(source: "A", channel: 1, kind: .cc14, number: 7, target: ""))
        #expect(learner.feed(.controlChange(channel: 0, controller: 7, value: 9), from: "A") == nil)
        #expect(learner.feed(.controlChange(channel: 0, controller: 7, value: 10), from: "A") == MIDIMapping(source: "A", channel: 1, kind: .cc, number: 7, target: ""))
        #expect(learner.feed(.programChange(channel: 15, program: 3), from: "B") == MIDIMapping(source: "B", channel: 16, kind: .pc, number: 3, target: ""))
    }

    @Test func mapCommandsValidateReplaceAndLock() throws {
        let (store, _) = StateStoreTests.makeStore()
        let learned = Mutex<[String?]>([])
        MIDICommands.register(on: store, hooks: MIDICommands.Hooks(learn: { target, _ in learned.withLock { $0.append(target) } }))
        let id = try store.execute("midi.map.set", args: ["channel": 1, "kind": "note", "number": 36, "target": "cue.go"], role: .programmer).get().value?.string
        // same control and target again: replaced, not added; by id: changed in place
        let again = try store.execute("midi.map.set", args: ["channel": 1, "kind": "note", "number": 36, "target": "cue.go", "curve": "toggle"], role: .programmer).get().value?.string
        #expect(again == id)
        _ = try store.execute("midi.map.set", args: ["id": .string(id!), "channel": 2, "kind": "note", "number": 36, "target": "cue.back"], role: .programmer).get()
        _ = try store.execute("midi.map.set", args: ["kind": "cc14", "number": 1, "target": "master/intensity", "pickup": true], role: .programmer).get()
        var settings = MIDISettings.from(project: store.project)
        #expect(settings.map.count == 2 && settings.map[0].target == "cue.back" && settings.map[0].channel == 2 && settings.map[1].pickup)
        for bad: JSONValue in [
            ["kind": "note", "number": 128, "target": "cue.go"], ["kind": "cc14", "number": 40, "target": "cue.go"], ["kind": "note", "number": 1, "target": "cue.goto"],
            ["kind": "cc", "number": 1, "target": "fixture:Camera 1/x"], ["kind": "cc", "number": 1, "target": "layer 1/intensity"], ["kind": "cc", "number": 1, "target": "cue.go", "low": 2],
            ["kind": "cc", "number": 1, "channel": 17, "target": "cue.go"], ["id": "nope", "kind": "cc", "number": 1, "target": "cue.go"], ["target": "cue.go"],
        ] {
            #expect(store.execute("midi.map.set", args: bad, role: .programmer).failureCode == "invalidArgs", "\(bad)")
        }
        _ = try store.execute("midi.set", args: ["source": "APC40", "mscDevice": 3], role: .programmer).get()
        settings = MIDISettings.from(project: store.project)
        #expect(settings.source == "APC40" && settings.mscDevice == 3 && settings.map.count == 2)
        #expect(store.execute("midi.set", args: ["mscDevice": 127], role: .programmer).failureCode == "invalidArgs")
        _ = try store.execute("midi.learn", args: ["target": "fixture:Layer 1/intensity"], role: .programmer).get()
        #expect(store.execute("midi.learn", args: ["target": "cue.goto"], role: .programmer).failureCode == "invalidArgs")
        _ = try store.execute("midi.learn", role: .programmer).get()
        #expect(learned.withLock { $0 } == ["fixture:Layer 1/intensity", nil])
        // show lock: mapping changes and learn are refused
        _ = try store.execute("show.lock", role: .programmer).get()
        #expect(store.execute("midi.map.remove", args: ["id": .string(id!)], role: .programmer).failureCode == "showLocked")
        #expect(store.execute("midi.learn", args: ["target": "cue.go"], role: .programmer).failureCode == "showLocked")
        _ = try store.execute("show.unlock", role: .programmer).get()
        _ = try store.execute("midi.map.remove", args: ["id": .string(id!)], role: .programmer).get()
        #expect(MIDISettings.from(project: store.project).map.count == 1)
        _ = try store.execute("midi.set", args: ["source": .null], role: .programmer).get()
        #expect(MIDISettings.from(project: store.project).source == nil)
    }

    /// The input end to end: bytes → parser → map → the resolver's `midi` source and cue actions; learn → stored entry.
    @Test func injectedBytesReachTheResolverAndLearn() throws {
        let dmx = DMXStore(patch: .standard(layers: 2, outputs: 1), logger: Self.logger)
        dmx.setPolicy(.ltp, for: .layer(1))
        let input = MIDIInput(dmx: dmx, logger: Self.logger)
        let cues = Mutex<[MIDIMapper.Action]>([])
        let stored = Mutex<[MIDIMapping]>([])
        input.onCue = { action in cues.withLock { $0.append(action) } }
        input.onLearn = { mapping in
            stored.withLock { $0.append(mapping) }
            return nil
        }
        input.apply(Self.settings([
            MIDIMapping(kind: .cc, number: 7, target: "fixture:Layer 1/intensity"), MIDIMapping(kind: .note, number: 36, target: "cue.go"),
        ]))
        input.inject([0xB0, 7, 127, 0x90, 36, 100], from: "nanoKONTROL2")
        let values = dmx.snapshot().internalValues["Layer 1"] ?? []
        #expect(values.contains { $0.key == "intensity" && $0.raw == 65535 && $0.source == "midi" })
        #expect(dmx.resolvedRaw(.layer(1), .layer(.intensity)) == 65535)
        #expect(cues.withLock { $0 } == [.cueGo])
        #expect(input.status.withLock { $0.last } == "nanoKONTROL2 · ch 1 · note 36 on · 100")
        // learn: a note on a parameter becomes a toggle
        input.learn(target: "fixture:Layer 2/intensity", cue: nil)
        input.inject([0x91, 60, 127], from: "APC40", uid: 2)
        let mapping = try #require(stored.withLock { $0.first })
        #expect(mapping.source == "APC40" && mapping.channel == 2 && mapping.kind == .note && mapping.number == 60 && mapping.target == "fixture:Layer 2/intensity" && mapping.curve == .toggle)
        #expect(input.status.withLock { $0.learning == nil && $0.learned == "ch 2 · note 60 → fixture:Layer 2/intensity" })
        // MSC GO 4 (video format) to the all-call, split over two packets
        input.inject([0xF0, 0x7F, 0x7F, 0x02, 0x30], from: "Desk", uid: 3)
        input.inject([0x01, 0x34, 0xF7], from: "Desk", uid: 3)
        #expect(cues.withLock { $0 } == [.cueGo, .cueGoto(4)])
    }

    /// Two identical controllers share a name: running status is kept per source id, not per name.
    @Test func parsersArePerSourceID() {
        let dmx = DMXStore(patch: .standard(layers: 2, outputs: 1), logger: Self.logger)
        let input = MIDIInput(dmx: dmx, logger: Self.logger)
        let cues = Mutex<Int>(0)
        input.onCue = { _ in cues.withLock { $0 += 1 } }
        input.apply(Self.settings([MIDIMapping(kind: .note, number: 36, target: "cue.go")]))
        input.inject([0x90], from: "APC mini", uid: 10)  // a status byte, its data still to come
        input.inject([0xB0, 1, 0], from: "APC mini", uid: 11)  // the twin sends a CC meanwhile
        input.inject([36, 127], from: "APC mini", uid: 10)
        #expect(cues.withLock { $0 } == 1)
    }

    /// MIDI values are a controller like the UI: they expire after masking a console, Release clears them, and they go
    /// when their entry is removed or their source disconnects.
    @Test func midiValuesNeverStayStuck() {
        let dmx = DMXStore(patch: .standard(layers: 2, outputs: 1), logger: Self.logger)
        dmx.setPolicy(.internal, for: .layer(1))
        let input = MIDIInput(dmx: dmx, logger: Self.logger)
        let fader = MIDIMapping(kind: .cc, number: 7, target: "fixture:Layer 1/intensity")
        let knob = MIDIMapping(kind: .cc, number: 8, target: "fixture:Layer 1/speed")
        func midi() -> [String] { (dmx.snapshot().internalValues["Layer 1"] ?? []).filter { $0.source == "midi" }.map(\.key).sorted() }
        input.apply(Self.settings([fader, knob]))
        input.inject([0xB0, 7, 100, 8, 100], from: "nanoKONTROL2", uid: 5)
        #expect(midi().count == 2)
        // the knob's entry removed: its value goes, the fader's stays
        input.apply(Self.settings([fader]))
        input.inject([], from: "nanoKONTROL2", uid: 5)
        #expect(midi() == ["intensity"])
        // the source disconnects: everything it set goes
        input.queue.sync { input.setSources([:]) }
        #expect(midi() == [])
        // fixture.release clears MIDI values too
        input.inject([0xB0, 7, 100], from: "nanoKONTROL2", uid: 5)
        #expect(midi() == ["intensity"])
        dmx.releaseUI(.layer(1))
        #expect(midi() == [])
        // B27 expiry: masking a received console for 10 minutes releases them
        dmx.queue.sync {
            dmx.receive(artnet: ArtDmx(portAddress: 0, data: [UInt8](repeating: 0, count: 512)), from: "desk", at: 1000)
            dmx.applyUI(.layer(1), .layer(.intensity), raw: 100, at: 1000, source: .midi)
            dmx.tick(at: 1000)
        }
        #expect(dmx.snapshot(at: 1000).uiExpiresIn["Layer 1"] == 600)
        dmx.queue.sync {
            dmx.receive(artnet: ArtDmx(portAddress: 0, data: [UInt8](repeating: 0, count: 512)), from: "desk", at: 1601)
            dmx.tick(at: 1601)
        }
        #expect(midi() == [])
    }

    @Test func toggleStartsFromTheShownValue() {
        var mapper = MIDIMapper(settings: Self.settings([MIDIMapping(kind: .note, number: 1, target: "fixture:Output 1/intensity", curve: .toggle)]))
        // the output shows full (its default): the first press turns it off, not "on" again
        #expect(mapper.handle(.noteOn(channel: 0, note: 1, velocity: 127), from: "x") { _, _ in 65535 } == [.set(.output(1), .output(.intensity), 0)])
        #expect(mapper.handle(.noteOn(channel: 0, note: 1, velocity: 127), from: "x") { _, _ in 0 } == [.set(.output(1), .output(.intensity), 65535)])
    }

    /// Hand-written entries: one that cannot be read is reported and kept in the document; the rest work and get ids.
    @Test func mapEntriesAreReadOneByOne() throws {
        let broken: JSONValue = ["kind": "knob", "number": 3, "target": "cue.go"]
        let project: JSONValue = ["midi": ["mscDevice": 0, "map": [broken, ["kind": "note", "number": 36, "target": "cue.go"], ["kind": "note", "number": 37, "target": "cue.goto"]]]]
        let settings = MIDISettings.from(project: project)
        #expect(settings.map.count == 2 && settings.problems.count == 2, "\(settings.problems)")
        #expect(settings.problems.first?.hasPrefix("map entry 1:") == true && settings.problems.last?.contains("cue number") == true)
        #expect(MIDIMapper(settings: settings).settings.map.count == 2)
        var mapper = MIDIMapper(settings: settings)
        #expect(mapper.handle(.noteOn(channel: 0, note: 36, velocity: 1), from: "x") { _, _ in nil } == [.cueGo])
        let fixed = try #require(MIDISettings.assigningIDs(project))
        #expect(MIDISettings.from(project: fixed).map.allSatisfy { !$0.id.isEmpty })
        #expect(MIDISettings.assigningIDs(fixed) == nil)
        // midi.map.set and remove leave the unreadable entry exactly as it was
        let store = StateStore(project: fixed, logger: Self.logger)
        MIDICommands.register(on: store, hooks: MIDICommands.Hooks(learn: { _, _ in }))
        let id = try store.execute("midi.map.set", args: ["kind": "cc", "number": 1, "target": "cue.back"], role: .programmer).get().value?.string
        _ = try store.execute("midi.map.remove", args: ["id": .string(id!)], role: .programmer).get()
        #expect(store.project["midi"]?["map"]?.array?.first?["kind"] == "knob")
        #expect(store.project["midi"]?["map"]?.array?.count == 3)
    }
}
