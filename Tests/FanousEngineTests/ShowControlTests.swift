// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreMIDI
import Foundation
import FanousCore
import Logging
import Metal
import Synchronization
import Testing

@testable import FanousEngine

extension ShowCommands.Hooks {
    /// Hooks that do nothing: the commands alone.
    static let noop = Self(go: {}, back: {}, goto: { _ in }, showMode: { _ in [] }, acknowledge: { _, _ in }, runReadiness: {})
}

/// A show mode that persists to `url` from the start, as `Engine.start` sets it.
private func showMode(persistingTo url: URL) -> ShowModeController {
    let controller = ShowModeController(logger: testLogger)
    controller.persist(to: url)
    return controller
}

@Suite(.cleansTempFiles)
struct ShowControlTests {

    @Test func cueFollowFiresWithoutAFade() async throws {
        let runner = CueRunner(dmx: DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger))
        defer { runner.stop() }
        runner.replace(list: CueList(cues: [
            Cue(number: 1, fadeTime: 0, followTime: 0.6),
            Cue(number: 2, fadeTime: 0),
        ]))
        let started = ContinuousClock.now
        runner.go()
        #expect(await waitUntil { runner.status.withLock { $0.current } != nil })
        let first = runner.status.withLock { $0.current }
        if ContinuousClock.now - started < .milliseconds(600) { #expect(first == 1, "the follow waits its 0.6 s") }
        #expect(await waitUntil { runner.status.withLock { $0.current } == 2 }, "the follow fired although nothing was fading")
        #expect(ContinuousClock.now - started >= .milliseconds(600), "not before its follow time")
    }

    /// B346: cues of a hand-written or imported `project.json` (no id, an id that is no UUID, a UUID an earlier cue
    /// already has) get ids once, at load: the parse is stable from then on, so an unrelated project change keeps the
    /// current cue and what the cues hold; `cue.set` and `cue.remove` find them; a save and a load keep the ids. Before,
    /// every parse made new ids: every project change dropped the current cue and released the held values.
    @Test func handWrittenCuesGetStableIDsAtLoad() throws {
        let dup = UUID().uuidString
        func value(_ layer: Int) -> JSONValue { ["fixture": .string("Layer \(layer)"), "parameter": "intensity", "raw": 30000] }
        var project = testProject(layers: 4, outputs: 0)
        try project.set(
            [
                ["number": 1, "name": "A", "values": [value(1)]],
                ["number": 2, "name": "B", "id": "cue-2", "values": [value(2)]],
                ["number": 3, "name": "C", "id": .string(dup), "values": [value(3)]],
                ["number": 4, "name": "D", "id": .string(dup), "values": [value(4)]],
            ], at: "/cues")
        let fixed = try #require(ShowCommands.assigningCueIDs(project))
        #expect(ShowCommands.assigningCueIDs(fixed) == nil, "once")
        let ids = (fixed["cues"]?.array ?? []).compactMap { $0["id"]?.string }
        #expect(ids.count == 4 && Set(ids).count == 4 && ids.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(ids[2] == dup, "the first holder of a duplicate keeps it")

        // GO, GO, then an unrelated change (the name): the list parses the same, the cue and its values stay
        var engine = CueEngine(list: ShowCommands.cueList(from: fixed))
        engine.go(at: 0)
        engine.go(at: 1)
        var renamed = fixed
        try renamed.set("Renamed", at: "/name")
        #expect(ShowCommands.cueList(from: renamed) == engine.list, "the engine would replace the list at every change")
        engine.replace(list: ShowCommands.cueList(from: renamed))
        #expect(engine.current?.number == 2 && engine.tick(at: 2).count == 2)

        let url = tempFile("b346-project", ext: "json")
        try ProjectDocument.save(fixed, to: url)
        let loaded = try #require(ProjectDocument.load(from: url))
        #expect(ShowCommands.assigningCueIDs(loaded) == nil && loaded["cues"] == fixed["cues"], "a save and a load keep the ids")

        let (store, _) = testStore(project: fixed)
        ShowCommands.register(
            on: store,
            hooks: ShowCommands.Hooks(go: {}, back: {}, goto: { _ in }, showMode: { _ in nil }, acknowledge: { _, _ in }, runReadiness: {}))
        _ = try store.execute("cue.set", args: ["id": .string(ids[0]), "cue": ["number": 1, "name": "A2"]], role: .programmer).get()
        _ = try store.execute("cue.remove", args: ["id": .string(ids[1])], role: .programmer).get()
        #expect(ShowCommands.cueList(from: store.project).cues.map(\.name) == ["A2", "C", "D"])
    }

    /// B346: a project loaded or reverted while the engine runs (here: `/cues` corrected to id-less cues from off the
    /// store queue, as a load lands) gets its cue ids through `Engine.projectChanged`, once: the stored cues end with
    /// unique UUIDs and parse the same twice. Never started, the engine has no cue runner, so this cannot see which list
    /// the runner gets; that it gets the corrected one, and only once, is the live check's.
    @Test func aLoadedProjectsCuesGetIDsThroughProjectChanged() async throws {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        let store = StateStore(project: testProject(layers: 2, outputs: 0), logger: testLogger)
        engine.store = store
        store.onProjectChanged = { [engine] in engine.projectChanged($0) }
        let cues: JSONValue = [["number": 1, "name": "A"], ["number": 2, "name": "B", "id": "cue-2"], ["number": 3, "name": "C", "id": "cue-2"]]
        try await offPool { store.correct(cues, at: "/cues") }
        let ids = { @Sendable in (store.project["cues"]?.array ?? []).compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) } }
        #expect(await waitUntil { Set(ids()).count == 3 }, "the cues did not get ids: \(store.project["cues"] ?? .null)")
        #expect(ShowCommands.cueList(from: store.project) == ShowCommands.cueList(from: store.project))
        #expect(ShowCommands.assigningCueIDs(store.project) == nil)
    }

    /// B43: a cue's fade measured end to end in the engine, go() → CueRunner (50 Hz) → DMXStore → the published Layer 1
    /// intensity the compositor reads. Loose bounds (B67), held at load average 31; the sampler thread must keep up. Stops at the snapshot;
    /// nothing here measures light (no photon probe exists).
    @Test func cueFadeReachesTheLayerAt50Hz() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        store.setPolicy(.internal)  // the default .dmx policy never lets a cue value through, even without DMX
        let runner = CueRunner(dmx: store)
        defer { runner.stop() }
        let full = CueValue(fixture: .layer(1), parameter: .layer(.intensity), raw: 65535)
        runner.replace(list: CueList(cues: [Cue(number: 1, fadeTime: 1.0, values: [full])]))
        #expect(await waitUntil { runner.status.withLock { $0.count } == 1 })
        let intensity = { @Sendable in store.snapshots.withLatest { $0.layers[0].intensity } }
        #expect(intensity() == 0)
        // sampled on a thread of its own: on the cooperative pool a parallel run starved the sampler (13 of 51 steps seen)
        let steps = try await offPool {
            var steps: [(at: Duration, value: Float)] = []
            let t0 = ContinuousClock.now
            runner.go()
            while ContinuousClock.now - t0 < .seconds(5) {
                let value = intensity()
                if value != (steps.last?.value ?? 0) { steps.append((ContinuousClock.now - t0, value)) }
                if value == 1 { break }
                usleep(1000)
            }
            return steps
        }
        let ms = { (d: Duration) in Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        let gaps = zip(steps.dropFirst(), steps).map { ms($0.at - $1.at) }.sorted()
        let first = steps.first.map { ms($0.at) } ?? .infinity
        let last = steps.last.map { ms($0.at) } ?? .infinity
        let (p50, low, high) = (gaps.isEmpty ? 0 : gaps[gaps.count / 2], gaps.first ?? 0, gaps.last ?? 0)
        let format = "TIMING cue fade 1 s: first step %.1f ms, full %.1f ms after go, %d steps, p50 %.1f (%.1f…%.1f) ms"
        print(String(format: format, first, last, steps.count, p50, low, high))
        #expect(steps.last?.value == 1, "reached full")
        #expect(first < 200, "first step within 200 ms of go: \(first) ms")
        #expect(last < 1300, "full within the fade + 300 ms: \(last) ms")
        // about 50 steps at 50 Hz on a quiet Mac; on the hosted CI VM the sampler saw 19 once (2026-11-04), so the bound
        // only refuses a fade that jumps in a handful of steps; the rate itself is not asserted. The fade is wall-clock
        // based, so load delays its end but never brings it forward: the lower bound on `last` cannot flake
        #expect(steps.count >= 10, "a fade in steps, not jumps: \(steps.count)")
        #expect(last >= 950, "the fade takes its second: \(last) ms")
    }

    @Test func timecodeClockExtrapolatesFreewheelsAndLoses() {
        let clock = TimecodeClock()
        clock.freewheelSeconds = 2
        #expect(clock.current(at: 10).state == .off)
        clock.update(Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, rate: .fps25), at: 10, source: "LTC")
        #expect(clock.current(at: 10.01).state == .locked)
        #expect(clock.current(at: 10.5).frameCount == 90_000 + 12, "12 frames later at 25 fps")
        #expect(clock.current(at: 10.5).state == .freewheel)
        #expect(clock.frames(at: 10.5)! - 90_012.5 < 1e-9)
        let lost = clock.current(at: 13)
        #expect(lost.state == .lost && lost.frameCount == 90_000 + 50, "frozen at the end of the freewheel")
        #expect(clock.frames(at: 13) == nil)
        clock.stop()
        #expect(clock.current(at: 14).state == .off)
    }

    /// B65: the lock window is 1.5 of the source's update intervals. MTC assembles a time every 2 frames (80 ms at
    /// 25 fps) and stays locked between them; LTC (every frame) keeps the 60 ms window.
    @Test func timecodeClockLockWindowFollowsTheSourcesUpdateInterval() {
        let clock = TimecodeClock()
        clock.freewheelSeconds = 2
        var flickers: [Double] = []
        for i in 0..<25 {  // 2 s of MTC: an update every 2 frames
            let t = 10 + Double(i) * 0.08
            clock.update(Timecode(frameCount: 90_000 + 2 * i, rate: .fps25), at: t, source: "MTC", everyFrames: 2)
            for step in 0..<8 where clock.current(at: t + Double(step) * 0.01).state != .locked { flickers.append(t + Double(step) * 0.01) }
        }
        #expect(flickers.isEmpty, "locked between MTC updates: \(flickers)")
        let last = 10 + 24 * 0.08
        #expect(clock.current(at: last + 0.11).state == .locked, "within 1.5 intervals (120 ms)")
        #expect(clock.current(at: last + 0.13).state == .freewheel, "past 1.5 intervals")
        #expect(clock.current(at: last + 1.9).state == .freewheel)
        #expect(clock.current(at: last + 2.1).state == .lost, "lost after the freewheel time")
        clock.update(Timecode(frameCount: 90_000, rate: .fps25), at: 20, source: "LTC")
        #expect(clock.current(at: 20.05).state == .locked, "LTC: within 1.5 frames (60 ms)")
        #expect(clock.current(at: 20.07).state == .freewheel, "LTC: past 1.5 frames, as before")
        #expect(clock.current(at: 22.1).state == .lost)
    }

    /// The LTC level (B137): the peak of each tenth of a second, across buffer boundaries, as dBFS; nothing before
    /// the first window or once the last one is older than half a second (a device that stopped delivering).
    @Test func ltcPeakWindow() {
        var window = PeakWindow(sampleRate: 1000)  // a window of 100 samples
        let quiet = [Float](repeating: 0.1, count: 60), loud = [Float](repeating: -0.5, count: 60)
        #expect(quiet.withUnsafeBufferPointer { window.feed($0) } == nil)
        // 40 more complete the first window (peak 0.5 from the negative samples), 20 start the next
        #expect(loud.withUnsafeBufferPointer { window.feed($0) } == 0.5)
        #expect([Float](repeating: 0.25, count: 80).withUnsafeBufferPointer { window.feed($0) } == 0.5)  // the second window holds 20 of -0.5
        #expect([Float](repeating: 0.25, count: 100).withUnsafeBufferPointer { window.feed($0) } == 0.25)
        #expect(PeakWindow.dBFS(1) == 0 && PeakWindow.dBFS(0.5) == -6 && PeakWindow.dBFS(0) == -96 && PeakWindow.dBFS(1e-9) == -96)
        let half = Float(0.5).bitPattern
        #expect(PeakWindow.level(bits: .max, at: 0, now: 0, ticksPerSecond: 1000) == nil)
        #expect(PeakWindow.level(bits: half, at: 1000, now: 1400, ticksPerSecond: 1000) == -6)
        #expect(PeakWindow.level(bits: half, at: 1000, now: 1501, ticksPerSecond: 1000) == nil)
        #expect(LTCInput(clock: TimecodeClock(), logger: testLogger).level == nil)
    }

    /// Acceptance: the chase against a generated LTC file (the decoder → clock path of `LTCInput`) is on the frame being
    /// transmitted, to a hundredth of a frame (B290: it ran one frame late and the old ±1 tolerance passed either way).
    /// The host time is the sample index, so the only error left is the threshold crossing within one sample.
    @Test func ltcFileChasesToAHundredthOfAFrame() throws {
        let sampleRate = 48_000.0
        let rate = TimecodeRate.fps25
        let frames = (0..<75).map { Timecode(frameCount: 90_000 + $0, rate: rate) }  // 3 s from 01:00:00:00
        let samples = LTCEncoder.samples(frames: frames, sampleRate: sampleRate)
        var decoder = LTCDecoder(sampleRate: sampleRate, nominalFrameRate: 25)
        let clock = TimecodeClock()
        var decoded = 0
        // feed in 512-sample buffers as the audio thread would, with host times from the sample index; the
        // chase is read "live", right after the buffer that contains t has been processed
        let t = 61.0 / 25  // frame 61 (01:00:02:11) is being transmitted
        var index = 0
        var chased: (now: Double, frames: Double)?
        var later: (now: Double, frames: Double)?
        while index < samples.count {
            let chunk = Array(samples[index..<min(samples.count, index + 512)])
            for frame in decoder.process(chunk) {
                clock.update(LTCInput.timeAtEnd(of: frame), at: Double(frame.endSampleIndex) / sampleRate, source: "LTC")
                decoded += 1
            }
            index += 512
            let now = Double(index) / sampleRate
            if chased == nil, now >= t { chased = clock.frames(at: now).map { (now, $0) } }
            if later == nil, now >= t + 0.02 { later = clock.frames(at: now).map { (now, $0) } }
        }
        #expect(decoded >= 70, "decoded \(decoded) of 75 frames")
        for (label, read) in [("at t", try #require(chased)), ("half a frame later", try #require(later))] {
            let transmitted = 90_000 + read.now * rate.exactFrameRate  // the frame on the wire at `now`, with its phase
            #expect(abs(read.frames - transmitted) < 0.01, "\(label): chased \(read.frames - 90_000), transmitted \(transmitted - 90_000)")
        }
    }

    /// F1 quarter-frame UMP system messages (pieces 0…7) for `tc` at 25 fps (rate code 1).
    static func quarterFrames(_ tc: Timecode) -> [UInt32] {
        let nibbles: [UInt8] = [
            UInt8(tc.frames & 0xF), UInt8(tc.frames >> 4), UInt8(tc.seconds & 0xF), UInt8(tc.seconds >> 4),
            UInt8(tc.minutes & 0xF), UInt8(tc.minutes >> 4), UInt8(tc.hours & 0xF), UInt8((tc.hours >> 4) | (1 << 1)),
        ]
        return nibbles.enumerated().map { piece, nibble in 0x1000_0000 | (0xF1 << 16) | (UInt32(UInt8(piece << 4) | nibble) << 8) }
    }

    /// Words as if CoreMIDI delivered them from a connected source, handled on the input's queue before this returns.
    static func feed(_ input: MTCInput, _ words: [UInt32], at hostTime: Double, uid: MIDIUniqueID = 1, name: String = "Pad") {
        input.queue.sync {
            if input.status.withLock({ !$0.connected.contains(name) }) { input.listener.setSources([uid: name]) }
            input.receive(words.map { ($0, hostTime) }, uid: uid)
        }
    }

    @Test func mtcQuarterFramesAssembleATimecode() {
        let clock = TimecodeClock()
        let input = MTCInput(clock: clock, logger: testLogger)
        let tc = Timecode(hours: 0, minutes: 0, seconds: 1, frames: 2, rate: .fps25)
        for (piece, word) in Self.quarterFrames(tc).enumerated() { Self.feed(input, [word], at: 5 + Double(piece) * 0.01) }
        let sample = clock.current(at: 5.08)
        #expect(sample.state == .locked)
        #expect(sample.frameCount == tc.frameCount + 2, "quarter-frame time is two frames behind")
        #expect(clock.current(at: 5.17).state == .locked, "100 ms after the last piece: MTC promises a time every 2 frames (B65)")
        // full-frame SysEx F0 7F 7F 01 01 hh mm ss ff F7 as a 64-bit UMP (start + end)
        let sysex: [UInt8] = [0x7F, 0x7F, 0x01, 0x01, UInt8(1 << 5) | 2, 3, 4, 5]
        let first = (UInt32(3) << 28) | (UInt32(1) << 20) | (UInt32(6) << 16) | (UInt32(sysex[0]) << 8) | UInt32(sysex[1])
        let second = (UInt32(sysex[2]) << 24) | (UInt32(sysex[3]) << 16) | (UInt32(sysex[4]) << 8) | UInt32(sysex[5])
        let third = (UInt32(3) << 28) | (UInt32(3) << 20) | (UInt32(2) << 16) | (UInt32(sysex[6]) << 8) | UInt32(sysex[7])
        Self.feed(input, [first, second, third, 0], at: 6)
        let full = clock.current(at: 6)
        #expect(full.timecode == Timecode(hours: 2, minutes: 3, seconds: 4, frames: 5, rate: .fps25), "\(full.timecode)")
    }

    /// B64: one parse state per source (two senders interleaved still assemble), and the source feeding the clock
    /// leaving is signal loss (freewheel, then lost), with late words from it dropped.
    @Test func mtcSourcesKeepTheirOwnStateAndLeavingFreewheelsTheClock() {
        let clock = TimecodeClock()
        let input = MTCInput(clock: clock, logger: testLogger)
        input.queue.sync { input.listener.setSources([1: "Pad", 2: "Console"]) }
        let a = Self.quarterFrames(Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, rate: .fps25))
        let b = Self.quarterFrames(Timecode(hours: 2, minutes: 0, seconds: 0, frames: 0, rate: .fps25))
        let seen = Mutex<[Int]>([])
        clock.onFrame = { tc, _ in seen.withLock { $0.append(tc.frameCount) } }
        for i in 0..<8 {
            input.queue.sync {
                input.receive([(a[i], 10)], uid: 1)
                input.receive([(b[i], 10)], uid: 2)
            }
        }
        #expect(seen.withLock { $0 } == [90_002, 180_002], "each source assembled its own time")
        #expect(input.status.withLock { $0.connected } == ["Console", "Pad"])
        // the console (last to feed) is unplugged; the pad stays
        input.queue.sync { input.listener.setSources([1: "Pad"]) }
        #expect(input.status.withLock { $0.connected } == ["Pad"], "the device list drops it at once")
        #expect(clock.current(at: 10.5).state == .freewheel, "an unplugged source is signal loss: freewheel")
        input.queue.sync { input.receive(b.map { ($0, 11) }, uid: 2) }
        #expect(clock.current(at: 11).state == .freewheel, "words in flight from the gone source are dropped")
        #expect(clock.current(at: 12.5).state == .lost, "lost after the freewheel time (2 s)")
        #expect(clock.frames(at: 12.5) == nil)
        // the pad sends again: locked
        Self.feed(input, a, at: 13, uid: 1, name: "Pad")
        #expect(clock.current(at: 13).state == .locked)
        input.queue.sync { input.listener.setSources([:]) }
        #expect(input.status.withLock { $0 }.error == "no MIDI source connected")
        input.stop()
        #expect(clock.current(at: 14).state == .off)
    }

    /// B150: a numberless cue.add is cue 0 and is refused like any other number once cue 0 exists.
    @Test func numberlessCueAddIsCueZeroOnce() throws {
        let (store, _) = testStore(outputs: 0)
        ShowCommands.register(on: store, hooks: .noop)
        _ = try store.execute("cue.add", args: ["name": "first"], role: .programmer).get()
        #expect(store.execute("cue.add", args: ["name": "second"], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("cue.add", args: ["number": 0, "name": "zero"], role: .programmer).failureCode == "invalidArgs")
        #expect(ShowCommands.cueList(from: store.project).cues.map(\.number) == [0])
        // cue.set keeps its refusal: a taken number, also the 0 a numberless cue normalizes to
        let one = try #require(try store.execute("cue.add", args: ["number": 1, "name": "one"], role: .programmer).get().value?.string)
        #expect(store.execute("cue.set", args: ["id": .string(one), "cue": ["number": 0, "name": "one"]], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("cue.set", args: ["id": .string(one), "cue": ["name": "one"]], role: .programmer).failureCode == "invalidArgs")
        #expect(ShowCommands.cueList(from: store.project).cues.map(\.number) == [0, 1])
    }

    @Test func cueJSONRoundTripAndCommands() throws {
        let (store, _) = testStore(outputs: 0)
        let fired = Mutex<[String]>([])
        ShowCommands.register(
            on: store,
            hooks: ShowCommands.Hooks(
                go: { fired.withLock { $0.append("go") } }, back: { fired.withLock { $0.append("back") } }, goto: { number in fired.withLock { $0.append("goto \(number)") } },
                showMode: { _ in ["power"] }, acknowledge: { id, on in fired.withLock { $0.append("\(on ? "ack" : "unack") \(id)") } }, runReadiness: { fired.withLock { $0.append("run") } }))
        let id = try store.execute(
            "cue.add",
            args: [
                "number": 1, "name": "Intro", "fade": 2.5, "trigger": "01:00:10:00@25", "follow": 3,
                "values": [["fixture": "Layer 1", "parameter": "intensity", "raw": 65535], ["fixture": "Master", "parameter": "speed", "raw": 32768, "fade": 1]],
            ], role: .programmer
        ).get().value?.string
        #expect(id != nil)
        let list = ShowCommands.cueList(from: store.project)
        #expect(list.cues.count == 1)
        let cue = try #require(list.cues.first)
        #expect(cue.name == "Intro" && cue.fadeTime == 2.5 && cue.followTime == 3)
        #expect(cue.timecodeTrigger == Timecode(hours: 1, minutes: 0, seconds: 10, frames: 0, rate: .fps25))
        #expect(cue.values.count == 2 && cue.values[0].parameter == .layer(.intensity) && cue.values[1].fadeTime == 1)
        #expect(store.execute("cue.add", args: ["number": 1, "name": "dup"], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("cue.add", args: ["number": 2, "name": "bad", "values": [["fixture": "Camera", "parameter": "x", "raw": 1]]], role: .programmer).failureCode == "invalidArgs")
        _ = try store.execute("cue.set", args: ["id": .string(id!), "cue": ["number": 1.5, "name": "Intro B", "fade": 0]], role: .programmer).get()
        #expect(ShowCommands.cueList(from: store.project).cues.first?.number == 1.5)
        _ = try store.execute("cue.go", role: .operator).get()
        _ = try store.execute("cue.goto", args: ["number": 1.5], role: .operator).get()
        #expect(store.execute("cue.remove", args: ["id": "nope"], role: .programmer).failureCode == "invalidArgs")
        _ = try store.execute("cue.remove", args: ["id": .string(id!)], role: .programmer).get()
        #expect(ShowCommands.cueList(from: store.project).cues.isEmpty)
        _ = try store.execute("undo", role: .programmer).get()
        #expect(ShowCommands.cueList(from: store.project).cues.count == 1)
        #expect(store.execute("show.mode", args: ["on": true], role: .operator).failureCode == "notReady")
        _ = try store.execute("readiness.acknowledge", args: ["id": "power"], role: .programmer).get()
        #expect(store.execute("readiness.unacknowledge", args: ["id": "power"], role: .operator).failureCode == "forbidden")
        _ = try store.execute("readiness.unacknowledge", args: ["id": "power"], role: .programmer).get()
        _ = try store.execute("timecode.set", args: ["path": "/source", "value": "mtc"], role: .programmer).get()
        _ = try store.execute("timecode.set", args: ["path": "/layerOffsets/3", "value": 12], role: .programmer).get()
        let settings = ShowCommands.timecodeSettings(from: store.project)
        #expect(settings.source == .mtc && settings.layerOffsets["3"] == 12)
        #expect(store.execute("timecode.set", args: ["path": "/source", "value": "vhs"], role: .programmer).failureCode == "invalidArgs")
        // the Inputs screen's Use for timecode (B137): the whole settings at path "", the switch's null kept as on
        let whole: JSONValue = ["source": "ltc", "device": "UMC404HD", "channel": 2, "offset": 0, "freewheel": 2, "layerOffsets": ["3": 12], "enabled": .null]
        _ = try store.execute("timecode.set", args: ["path": "", "value": whole], role: .programmer).get()
        let ltc = ShowCommands.timecodeSettings(from: store.project)
        #expect(ltc.source == .ltc && ltc.device == "UMC404HD" && ltc.channel == 2 && ltc.enabled == nil && ltc.layerOffsets["3"] == 12)
        _ = try store.execute("undo", role: .programmer).get()
        #expect(ShowCommands.timecodeSettings(from: store.project).source == .mtc)
        #expect(fired.withLock { $0 } == ["go", "goto 1.5", "ack power", "unack power"])
    }

    /// B262: `timecode.set` stored two keys for one layer ("1", "01"), which trapped the engine on the control queue.
    /// The command refuses a key that is not the canonical spelling of a layer number, in the form of other refused values.
    @Test func timecodeSetRefusesNonCanonicalLayerKeys() throws {
        let (store, _) = testStore(outputs: 0)
        ShowCommands.register(on: store, hooks: .noop)
        let refused: [(String, JSONValue)] = [("/layerOffsets", ["1": 0, "01": 5]), ("/layerOffsets/01", 5), ("/layerOffsets/+3", 5), ("/layerOffsets/x", 5)]
        for (path, value) in refused {
            #expect(store.execute("timecode.set", args: ["path": .string(path), "value": value], role: .programmer).failureCode == "invalidArgs", "\(path)")
        }
        #expect(ShowCommands.timecodeSettings(from: store.project).layerOffsets.isEmpty)
        _ = try store.execute("timecode.set", args: ["path": "/layerOffsets", "value": ["1": 0, "12": 5]], role: .programmer).get()
        #expect(ShowCommands.timecodeSettings(from: store.project).layerOffsets == ["1": 0, "12": 5])
    }

    /// B262 review: a key an older build stored ("01") is kept, and the other settings stay editable, also from the
    /// Inputs screen, which sends the stored object back at path ""; only a key the command adds is refused.
    @Test func timecodeSetKeepsAStoredNonCanonicalKey() throws {
        var project = testProject(layers: 2, outputs: 0)
        let stored: JSONValue = ["source": "off", "channel": 0, "offset": 0, "freewheel": 2, "layerOffsets": ["01": 5]]
        try project.set(stored, at: "/timecode")
        let (store, _) = testStore(project: project)
        ShowCommands.register(on: store, hooks: .noop)
        _ = try store.execute("timecode.set", args: ["path": "/source", "value": "mtc"], role: .programmer).get()
        #expect(ShowCommands.timecodeSettings(from: store.project).source == .mtc)
        #expect(ShowCommands.timecodeSettings(from: store.project).layerOffsets == ["01": 5])
        _ = try store.execute("timecode.set", args: ["path": "", "value": stored], role: .programmer).get()
        #expect(store.execute("timecode.set", args: ["path": "/layerOffsets/02", "value": 4], role: .programmer).failureCode == "invalidArgs")
        _ = try store.execute("timecode.set", args: ["path": "/layerOffsets/1", "value": 3], role: .programmer).get()
        #expect(ShowCommands.timecodeSettings(from: store.project).layerOffsetsByNumber == [1: 3])
    }

    /// B262: a project that already holds two keys for one layer (older build, hand edit) trapped at every start
    /// (`Dictionary(uniqueKeysWithValues:)` in applyTimecodeSettings). Loading it never traps: the canonical key wins,
    /// else the lowest key, whatever the dictionary's hash order.
    @Test func layerOffsetsByNumberSurvivesDuplicateKeys() throws {
        var settings = ShowCommands.TimecodeSettings()
        settings.layerOffsets = ["01": 5, "1": 0, "+1": 7, "002": 3, "02": 4, "x": 9, "-1": 2]
        #expect(settings.layerOffsetsByNumber == [1: 0, 2: 3, -1: 2])
    }

    /// B159: every rate spelling the guide and the cue editor use parses, and cue.add refuses a trigger that does not.
    @Test func cueTriggerRateSpellings() throws {
        for (text, rate) in [
            ("00:01:30:00@29.97df", TimecodeRate.fps2997df), ("00:01:30:00@29.97ndf", .fps2997ndf), ("00:01:30:00@29.97 DF", .fps2997df),
            ("00:01:30:00@29.97 NDF", .fps2997ndf), ("00:01:30:00@fps2997df", .fps2997df), ("00:01:30:00@24", .fps24), ("00:01:30:00@25", .fps25),
            ("00:01:30:00@30", .fps30), ("00:01:30:00", .fps25),
        ] {
            #expect(ShowCommands.parseTimecode(text) == Timecode(hours: 0, minutes: 1, seconds: 30, frames: 0, rate: rate), "\(text)")
        }
        #expect(ShowCommands.parseTimecode("00:01:30:00@29.97") == nil)
        let (store, _) = testStore(outputs: 0)
        ShowCommands.register(on: store, hooks: .noop)
        #expect(store.execute("cue.add", args: ["number": 1, "name": "typo", "trigger": "00:01:30:00@29.97"], role: .programmer).failureCode == "invalidArgs")
        #expect(store.execute("cue.add", args: ["number": 2, "name": "short", "trigger": "01:30:00"], role: .programmer).failureCode == "invalidArgs")
        _ = try store.execute("cue.add", args: ["number": 3, "name": "ndf", "trigger": "00:01:30:00@29.97ndf"], role: .programmer).get()
        #expect(ShowCommands.cueList(from: store.project).cues.map(\.timecodeTrigger) == [Timecode(hours: 0, minutes: 1, seconds: 30, frames: 0, rate: .fps2997ndf)])
        // null clears the trigger and is not refused
        _ = try store.execute("cue.add", args: ["number": 4, "name": "none", "trigger": .null], role: .programmer).get()
    }

    /// B189: cue.add and cue.set refuse a trigger outside the field ranges, the same rules as the web's parseTrigger; a project
    /// stored by an older build still loads every cue with that trigger armed as before.
    @Test func cueTriggerFieldRanges() throws {
        let (store, _) = testStore(outputs: 0)
        ShowCommands.register(on: store, hooks: .noop)
        let bad = [
            "00:00:00:99@25", "25:00:00:00@25", "00:60:00:00", "00:00:60:00", "00:00:00:25@25", "00:00:00:24@24", "00:00:00:30@30",
            "00:01:00:00@29.97df", "00:01:00:01@29.97df",
        ]
        for (i, trigger) in bad.enumerated() {
            let result = store.execute("cue.add", args: ["number": .number(Double(i + 1)), "name": "bad", "trigger": .string(trigger)], role: .programmer)
            #expect(result.failureMessage?.hasPrefix("trigger \(trigger) out of range: ") == true, "\(trigger)")
        }
        let good = ["23:59:59:24@25", "00:00:00:23@24", "00:00:00:29@29.97df", "00:01:00:02@29.97df", "00:10:00:00@29.97df", "00:01:00:00@29.97ndf"]
        for (i, trigger) in good.enumerated() {
            _ = try store.execute("cue.add", args: ["number": .number(Double(i + 1)), "name": "good", "trigger": .string(trigger)], role: .programmer).get()
        }
        let first = try #require(store.project["cues"]?.array?.first)
        var changed = first
        try changed.set("00:00:00:99@25", at: "/trigger")
        let refused = store.execute("cue.set", args: ["id": first["id"] ?? .null, "cue": changed], role: .programmer)
        #expect(
            refused.failureMessage
                == "trigger 00:00:00:99@25 out of range: hours go to 23, minutes and seconds to 59, frames to one below the rate; 29.97df skips frames 00 and 01 of each minute except every tenth")
        // a malformed trigger keeps its own text
        #expect(
            store.execute("cue.add", args: ["number": 99, "name": "typo", "trigger": "00:01:30:00@29.97"], role: .programmer).failureMessage
                == "trigger is hh:mm:ss:ff@rate, the rate 24, 25, 29.97df, 29.97ndf or 30")

        let stored: JSONValue = ["cues": .array(bad.enumerated().map { ["number": .number(Double($0.offset + 1)), "name": "old", "trigger": .string($0.element)] })]
        let loaded = ShowCommands.cueList(from: stored).cues
        #expect(loaded.count == bad.count)
        #expect(loaded.allSatisfy { $0.timecodeTrigger != nil })
        #expect(loaded.first?.timecodeTrigger == Timecode(hours: 0, minutes: 0, seconds: 0, frames: 99, rate: .fps25))
    }

    /// B192: one table of trigger spellings with the verdict of both sides: "accept" the engine's cue.add and the web's
    /// parseTrigger both take as is, "refuse" both refuse, "web" only the web takes and normalizes before sending (`;`,
    /// spaces before `@`, surrounding whitespace, empty for none); a "web" row's third column is what parseTrigger sends
    /// ("" = no trigger, null), which cue.add must take. This table and TRIGGER_SPELLINGS in web/src/lib/show.test.ts must
    /// stay identical, row for row.
    static let triggerSpellings: [[String]] = [
        ["00:01:30:00", "accept"], ["1:2:3:4", "accept"], ["00:01:30:00@24", "accept"], ["00:01:30:00@25", "accept"],
        ["00:01:30:00@29.97df", "accept"], ["00:01:30:00@29.97ndf", "accept"], ["00:01:30:00@29.97 DF", "accept"],
        ["00:01:30:00@29.97 NDF", "accept"], ["00:01:30:00@29.97DF", "accept"], ["00:01:30:00@29.97 Ndf", "accept"],
        ["00:01:30:00@30", "accept"], ["00:01:30:00@ 25", "accept"], ["00:01:30:00@25 ", "accept"],
        ["23:59:59:24@25", "accept"], ["00:00:00:23@24", "accept"], ["00:00:00:29@29.97df", "accept"], ["00:01:00:02@29.97df", "accept"],
        ["00:10:00:00@29.97df", "accept"], ["00:01:00:00@29.97ndf", "accept"], ["23:59:59:29@30", "accept"],
        ["+1:00:00:00", "refuse"], ["+1:00:00:00@25", "refuse"], ["-0:00:00:00@25", "refuse"], ["000:00:00:000@25", "refuse"],
        ["00:00:00:000@25", "refuse"], ["00::00:00:00", "refuse"], ["00:00:00:00@25@junk", "refuse"], ["00:00:00:00@@25", "refuse"],
        ["00:00:00:00@", "refuse"], ["00:00:00:00@fps2997df", "refuse"], ["00:00:00:00@fps25", "refuse"], ["00:01:30:00@29.97", "refuse"],
        ["00:00:10:00@50", "refuse"], ["10", "refuse"], ["00:00:10", "refuse"], ["01:30:00", "refuse"], ["a:b:c:d", "refuse"],
        ["00:00:00:99@25", "refuse"], ["25:00:00:00@25", "refuse"], ["24:00:00:00", "refuse"], ["00:60:00:00", "refuse"],
        ["00:00:60:00", "refuse"], ["00:00:00:25@25", "refuse"], ["00:00:00:24@24", "refuse"], ["00:00:00:30@30", "refuse"],
        ["00:01:00:00@29.97df", "refuse"], ["00:01:00:01@29.97df", "refuse"],
        ["", "web", ""], ["00:01:00;02@29.97df", "web", "00:01:00:02@29.97 DF"],
        ["00:00:10:29 @ 29.97 NDF", "web", "00:00:10:29@29.97 NDF"], ["00:00:10:00 @25", "web", "00:00:10:00@25"],
        [" 00:00:10:00@25 ", "web", "00:00:10:00@25"], ["00:00:10:00@29.97\tdf", "web", "00:00:10:00@29.97 DF"],
    ]

    @Test func cueTriggerSpellingsMatchTheWeb() throws {
        let (store, _) = testStore(outputs: 0)
        ShowCommands.register(on: store, hooks: .noop)
        for (i, row) in Self.triggerSpellings.enumerated() {
            let result = store.execute("cue.add", args: ["number": .number(Double(i + 1)), "name": "t", "trigger": .string(row[0])], role: .programmer)
            #expect((result.failureCode == nil) == (row[1] == "accept"), "\(row[0].debugDescription) \(row[1])")
            if row[1] == "web" {
                let sent: JSONValue = row[2].isEmpty ? .null : .string(row[2])
                let normalized = store.execute("cue.add", args: ["number": .number(Double(1000 + i)), "name": "t", "trigger": sent], role: .programmer)
                #expect(normalized.failureCode == nil, "\(row[2].debugDescription) sent for \(row[0].debugDescription)")
            }
        }
        #expect(
            store.execute("cue.add", args: ["number": 999, "name": "t", "trigger": "+1:00:00:00"], role: .programmer).failureMessage
                == "trigger is hh:mm:ss:ff@rate, the rate 24, 25, 29.97df, 29.97ndf or 30")
    }

    /// B192: a project an older build stored with an engine-only spelling loads every cue with its trigger armed; such a cue
    /// takes no other change until its trigger is corrected, as with an out-of-range trigger (B189).
    @Test func storedEngineOnlyTriggerSpellingsStillLoad() throws {
        let old: [(String, Timecode)] = [
            ("+1:00:00:00", Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0, rate: .fps25)),
            ("000:00:00:010@25", Timecode(hours: 0, minutes: 0, seconds: 0, frames: 10, rate: .fps25)),
            ("00:00:00:05@24@junk", Timecode(hours: 0, minutes: 0, seconds: 0, frames: 5, rate: .fps24)),
            ("00:01:00:02@fps2997df", Timecode(hours: 0, minutes: 1, seconds: 0, frames: 2, rate: .fps2997df)),
            // empty fields and an empty rate are skipped on load, as before
            ("00::01:02:03", Timecode(hours: 0, minutes: 1, seconds: 2, frames: 3, rate: .fps25)),
            ("00:00:00:07:", Timecode(hours: 0, minutes: 0, seconds: 0, frames: 7, rate: .fps25)),
            ("00:00:00:08@", Timecode(hours: 0, minutes: 0, seconds: 0, frames: 8, rate: .fps25)),
            ("00:00:00:09@@24", Timecode(hours: 0, minutes: 0, seconds: 0, frames: 9, rate: .fps24)),
        ]
        let cues: JSONValue = .array(
            old.enumerated().map { ShowCommands.normalizedCue(["number": .number(Double($0.offset + 1)), "name": "old", "trigger": .string($0.element.0)], id: UUID().uuidString) })
        var project = testProject(layers: 2, outputs: 0)
        try project.set(cues, at: "/cues")
        #expect(ShowCommands.cueList(from: project).cues.map(\.timecodeTrigger) == old.map(\.1))

        let (store, _) = testStore(outputs: 0, project: project)
        ShowCommands.register(on: store, hooks: .noop)
        let first = try #require(store.project["cues"]?.array?.first)
        var renamed = first
        try renamed.set("new name", at: "/name")
        #expect(
            store.execute("cue.set", args: ["id": first["id"] ?? .null, "cue": renamed], role: .programmer).failureMessage
                == "trigger is hh:mm:ss:ff@rate, the rate 24, 25, 29.97df, 29.97ndf or 30")
        try renamed.set("01:00:00:00@25", at: "/trigger")
        _ = try store.execute("cue.set", args: ["id": first["id"] ?? .null, "cue": renamed], role: .programmer).get()
        #expect(ShowCommands.cueList(from: store.project).cues.map(\.name) == ["new name"] + Array(repeating: "old", count: old.count - 1))
    }

    /// B163: an acknowledgement holds for this failure in this show: taken back it blocks again, leaving show mode drops
    /// it, outside show mode a pass (ok or warn, not manual) drops it, and a run is flagged by the set as it is when it lands.
    @Test func anAcknowledgementHoldsForOneFailureInOneShow() {
        /// `acknowledged`: what the run read from the set when it started (Readiness.check flags it).
        func run(_ state: ReadinessItem.State, detail: String = "lost: [1]", acknowledged: Bool = true) -> [ReadinessItem] {
            [ReadinessItem(id: "outputs", title: "All outputs bound to their displays", state: state, detail: detail, fix: "", acknowledged: acknowledged)]
        }
        var ledger = ReadinessLedger()
        ledger.store(run(.fail, acknowledged: false), run: ledger.begin().run, at: 1, showMode: false)
        #expect(ledger.items[0].blocks)
        ledger.acknowledge("outputs", true)
        #expect(!ledger.items[0].blocks && ledger.acknowledged == ["outputs"])
        // another failure detail keeps it: no detail tracking
        ledger.store(run(.fail, detail: "unassigned: [2]"), run: ledger.begin().run, at: 2, showMode: false)
        #expect(!ledger.items[0].blocks)
        ledger.acknowledge("outputs", false)
        #expect(ledger.items[0].blocks && ledger.acknowledged.isEmpty)
        // a run that read the old set (acknowledged when it started) lands after the take-back: it blocks
        ledger.store(run(.fail), run: ledger.begin().run, at: 3, showMode: false)
        #expect(ledger.items[0].blocks)
        // in show mode a pass keeps it (the camera passes while no cue uses it): the next failure is still accepted
        ledger.acknowledge("outputs", true)
        ledger.store(run(.ok), run: ledger.begin().run, at: 4, showMode: true)
        ledger.store(run(.fail), run: ledger.begin().run, at: 5, showMode: true)
        #expect(!ledger.items[0].blocks && ledger.checkedAt == 5)
        // outside show mode manual (unreadable) keeps it; ok and warn drop it, so fail → pass → fail needs a new one
        ledger.store(run(.manual), run: ledger.begin().run, at: 6, showMode: false)
        #expect(ledger.acknowledged == ["outputs"])
        ledger.store(run(.ok), run: ledger.begin().run, at: 7, showMode: false)
        #expect(ledger.acknowledged.isEmpty)
        ledger.acknowledge("outputs", true)
        ledger.store(run(.warn), run: ledger.begin().run, at: 8, showMode: false)
        #expect(ledger.acknowledged.isEmpty && !ledger.items[0].acknowledged)
        ledger.store(run(.fail, acknowledged: false), run: ledger.begin().run, at: 9, showMode: false)
        #expect(ledger.items[0].blocks)
        // a run in flight that sampled ok before the programmer acknowledged the red row drops nothing
        ledger.acknowledge("outputs", true)
        ledger.store(run(.ok, acknowledged: false), run: ledger.begin().run, at: 10, showMode: false)
        #expect(ledger.acknowledged == ["outputs"])
        // leaving show mode drops every acknowledgement, also one for an item the last run did not show
        ledger.acknowledge("spotlight", true)
        ledger.store(run(.fail), run: ledger.begin().run, at: 11, showMode: true)
        ledger.leaveShow()
        #expect(ledger.items[0].blocks && ledger.acknowledged.isEmpty)
        // B187: a run that started before the one stored last changes nothing, an acknowledgement neither
        ledger.acknowledge("outputs", true)
        let older = ledger.begin().run
        ledger.store(run(.fail), run: ledger.begin().run, at: 12, showMode: false)
        #expect(ledger.store(run(.ok), run: older, at: 13, showMode: false).map(\.state) == [.ok])
        #expect(ledger.checkedAt == 12 && ledger.items[0].state == .fail && ledger.acknowledged == ["outputs"])
    }

    /// B185: in show mode the engine logs what a stored run changed: items that start failing (acknowledged or not),
    /// items that pass again, and the blocking set; nothing when a run changes nothing or the ledger discards it.
    @Test func aStoredRunReportsWhatItChanged() {
        func item(_ id: String, _ state: ReadinessItem.State, acknowledged: Bool = false) -> ReadinessItem {
            ReadinessItem(id: id, title: id, state: state, detail: "", fix: "", acknowledged: acknowledged)
        }
        func change(_ old: [ReadinessItem], _ new: [ReadinessItem]) -> [[String]]? {
            ReadinessChange(from: old, to: new).map { [$0.failing, $0.acknowledged, $0.passing, $0.blocking, $0.blockingGained ? ["gained"] : []] }
        }
        let ok = [item("dmx", .ok), item("outputs", .ok)]
        // nothing changes, nothing reported: also the same failure on the next run
        #expect(change(ok, ok) == nil)
        #expect(change([item("dmx", .fail)], [item("dmx", .fail)]) == nil)
        // starts blocking
        #expect(change(ok, [item("dmx", .fail), item("outputs", .ok)]) == [["dmx"], [], [], ["dmx"], ["gained"]])
        // more start blocking: only the new one fails anew, the blocking set has both
        #expect(change([item("dmx", .fail), item("outputs", .ok)], [item("dmx", .fail), item("outputs", .hard)]) == [["outputs"], [], [], ["dmx", "outputs"], ["gained"]])
        // one clears while another stays, then the last clears
        #expect(change([item("dmx", .fail), item("outputs", .fail)], [item("dmx", .ok), item("outputs", .fail)]) == [[], [], ["dmx"], ["outputs"], []])
        #expect(change([item("dmx", .ok), item("outputs", .fail)], ok) == [[], [], ["outputs"], [], []])
        // one clears and another starts in the same run: both are in it
        #expect(change([item("dmx", .fail), item("outputs", .ok)], [item("dmx", .ok), item("outputs", .fail)]) == [["outputs"], [], ["dmx"], ["outputs"], ["gained"]])
        // an acknowledged item that passes, then fails again: reported as failing and acknowledged, not blocking
        let acknowledgedFail = [item("dmx", .fail, acknowledged: true), item("outputs", .ok)]
        let acknowledgedPass = [item("dmx", .ok, acknowledged: true), item("outputs", .ok)]
        #expect(change(acknowledgedFail, acknowledgedPass) == [[], [], ["dmx"], [], []])
        #expect(change(acknowledgedPass, acknowledgedFail) == [["dmx"], ["dmx"], [], [], []])
        // an acknowledged failing item that turns hard blocks: no state starts failing, the blocking set gains it
        #expect(change(acknowledgedFail, [item("dmx", .hard, acknowledged: true), item("outputs", .ok)]) == [[], [], [], ["dmx"], ["gained"]])
        // after a resume the ledger is empty: every failing item is new
        #expect(change([], [item("dmx", .fail), item("outputs", .ok)]) == [["dmx"], [], [], ["dmx"], ["gained"]])

        // a discarded older run leaves the stored items, so it reports nothing
        var ledger = ReadinessLedger()
        let older = ledger.begin().run
        ledger.store([item("dmx", .fail)], run: ledger.begin().run, at: 1, showMode: true)
        let before = ledger.items
        ledger.store([item("dmx", .ok)], run: older, at: 2, showMode: true)
        #expect(change(before, ledger.items) == nil)
    }

    /// B185: outside show mode the engine logs no readiness line: not for the entry run (refused here, so show mode
    /// stays off and no show-state file is written) and not for an acknowledgement.
    @Test func readinessLogsNothingOutsideShowMode() async throws {
        let lines = HTTPSServerLogTests.Lines()
        let logger = Logger(label: "test") { _ in HTTPSServerLogTests.Capture(lines: lines) }
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: logger)
        engine.readinessCheck = { _, _ in [ReadinessItem(id: "outputs", title: "", state: .hard, detail: "", fix: "")] }
        #expect(try await offPool { engine.setShowMode(true) } == ["outputs"])
        try engine.acknowledgeReadiness("outputs", true)
        try engine.acknowledgeReadiness("outputs", false)
        #expect(try await offPool { engine.setShowMode(true) } == ["outputs"])
        #expect(!lines.all.withLock { $0 }.contains { $0.hasPrefix("readiness") })
    }

    /// PR #341: a console repeating `/fanous/show/mode 1` in a show runs no entry checks, which would drop the
    /// acknowledgement of an item that passes at that moment, so it blocked again at its next failure. Show mode is
    /// entered for real (power assertions for the test's duration), with no state file.
    @Test func aRepeatedShowModeEntryKeepsTheAcknowledgements() async throws {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        let calls = Atomic<Int>(0)
        let state = Mutex(ReadinessItem.State.fail)
        engine.readinessCheck = { _, acknowledged in  // flagged as `Readiness.check` does
            calls.add(1, ordering: .relaxed)
            return [ReadinessItem(id: "outputs", title: "", state: state.withLock { $0 }, detail: "", fix: "", acknowledged: acknowledged.contains("outputs"))]
        }
        try engine.acknowledgeReadiness("outputs", true)
        #expect(try await offPool { engine.setShowMode(true) } == nil)
        defer { _ = engine.setShowMode(false) }
        try #require(calls.load(ordering: .relaxed) == 1, "the entry ran the checks once")
        state.withLock { $0 = .ok }  // the item passes at the moment the console repeats
        #expect(try await offPool { engine.setShowMode(true) } == nil)
        #expect(calls.load(ordering: .relaxed) == 1, "the repeat ran the entry checks")
        #expect(engine.readiness.withLock { $0.acknowledged } == ["outputs"], "the repeat dropped the acknowledgement")
    }

    /// B144: a Mac without a ProRes engine fails the "Supported hardware" item hard; acknowledging does not unblock it.
    @Test func aMacWithoutAProResEngineIsRefusedShowMode() throws {
        #expect(!SystemInfo.proResEngine(chip: "Apple M1") && SystemInfo.proResEngine(chip: "Apple M1 Pro") && SystemInfo.proResEngine(chip: "Apple M2"))
        #expect(SystemInfo.proResEngine(chip: "Apple M1 (Virtual)"))  // CI's runner (B99): the e2e engines must pass
        var context = ReadinessContext()
        context.hardwareSupported = false
        let item = try #require(Readiness.check(context, acknowledged: ["hardware"]).first { $0.id == "hardware" })
        #expect(item.state == .hard && item.blocks && item.detail == "no hardware ProRes decoder")
    }

    /// B187: a probe tool that does not exit is killed at the timeout and reads as unknown (nil); one that exits but
    /// leaves a child holding its output open returns at once.
    @Test func aHungProbeToolReturnsNilAtTheTimeout() async throws {
        try await offPool {
            #expect(Readiness.run("/bin/echo", ["ok"], timeout: 2) == "ok\n")
            for (arguments, expected) in [(["-c", "sleep 30"], nil), (["-c", "sleep 30 & wait"], nil), (["-c", "echo hi; sleep 30 &"], "hi\n")] as [([String], String?)] {
                let started = ContinuousClock.now
                let output = Readiness.run("/bin/sh", arguments, timeout: 0.3)
                #expect(output == expected, "\(arguments)")
                #expect(ContinuousClock.now - started < .seconds(3), "\(arguments) held the caller")
            }
        }
    }

    /// B187: a readiness run with a probe that hangs leaves the feed queue (live publish, DMX monitor, autosave) free,
    /// and its result, when it comes, does not replace that of a show-mode entry that started after it.
    @Test func aHungReadinessRunHoldsNeitherTheFeedQueueNorANewerResult() async throws {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        let release = Hold()
        let calls = Atomic<Int>(0)
        let seenByThirdRun = Mutex<[String]?>(nil)
        engine.readinessCheck = { [weak engine] _, _ in
            switch calls.add(1, ordering: .relaxed).newValue {
            case 1:
                release.wait()
                return [ReadinessItem(id: "old", title: "", state: .ok, detail: "", fix: "")]
            case 2: return [ReadinessItem(id: "new", title: "", state: .hard, detail: "", fix: "")]
            default:
                // queued behind the hung run: what that run left stored
                seenByThirdRun.withLock { $0 = engine?.readiness.withLock { $0.items.map(\.id) } }
                return []
            }
        }
        defer { release.done() }
        engine.feedQueue.sync { engine.runReadiness() }  // as the 30 s timer does
        #expect(await waitUntil { calls.load(ordering: .relaxed) == 1 }, "the run started")
        let free = DispatchGroup()
        engine.feedQueue.async(group: free) {}
        #expect(try await offPool { free.wait(timeout: .now() + 1) } == .success, "the feed queue waited for the hung probe")
        #expect(try await offPool { engine.setShowMode(true) } == ["new"])
        engine.runReadiness()
        release.signal()
        #expect(await waitUntil { seenByThirdRun.withLock { $0 } != nil })
        #expect(seenByThirdRun.withLock { $0 } == ["new"], "the older run stored its items over the show-mode entry's")
    }

    /// B197: a library volume that stops answering (a stalled network mount) holds the checks for the volume timeout
    /// only: disk and library fail, Spotlight is manual, and a second check joins the hung read instead of starting
    /// another thread. Once the read returns, the next check reads the volume again.
    @Test(.offPool) func aHungLibraryVolumeReadTimesOut() throws {
        let gate = Hold()
        defer { gate.done() }
        let reads = Atomic<Int>(0)
        var context = ReadinessContext()
        context.libraryRoot = "/b197-\(UUID().uuidString)"
        context.volumeTimeout = 0.2
        context.readVolume = { _ in
            reads.add(1, ordering: .relaxed)
            gate.wait(turnstile: true)  // once open, every later read passes at once
            return Readiness.libraryVolume(NSHomeDirectory())
        }
        for _ in 0..<2 {
            let start = ContinuousClock.now
            let items = Readiness.check(context, acknowledged: [])
            #expect(ContinuousClock.now - start < .seconds(2), "the check waited for the hung volume read")
            let item = { (id: String) in items.first { $0.id == id } }
            #expect(item("disk")?.state == .fail && item("disk")?.detail == "library volume not answering")
            #expect(item("library")?.state == .fail && item("library")?.detail == "library volume not answering")
            #expect(item("spotlight")?.state == .manual && item("spotlight")?.detail == "library volume not answering")
        }
        #expect(reads.load(ordering: .relaxed) == 1, "a second check started another read of the hung volume")
        gate.signal()
        context.volumeTimeout = 5  // the deadline was proven above; this proves the recovery, also on a slow CI VM
        #expect(Readiness.check(context, acknowledged: []).first { $0.id == "disk" }?.detail != "library volume not answering")
    }

    /// B197: readiness requests behind a hung run (the 30 s timer, Run checks) coalesce into one waiting run, and a
    /// request while that run is running still leads to one more run after it.
    @Test func readinessRequestsBehindAHungRunCoalesce() async throws {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        let first = Hold(), second = Hold()
        let calls = Atomic<Int>(0)
        engine.readinessCheck = { _, _ in
            switch calls.add(1, ordering: .relaxed).newValue {
            case 1: first.wait()
            case 2: second.wait()
            default: break
            }
            return []
        }
        defer { first.done(); second.done() }
        engine.runReadiness()
        #expect(await waitUntil { calls.load(ordering: .relaxed) == 1 }, "the first run started")
        for _ in 0..<50 { engine.runReadiness() }
        first.signal()
        #expect(await waitUntil { calls.load(ordering: .relaxed) == 2 }, "no run after the hung one")
        engine.runReadiness()  // a click while the coalesced run runs
        second.signal()
        #expect(await waitUntil { calls.load(ordering: .relaxed) >= 3 }, "the click during a run led to no run")
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls.load(ordering: .relaxed) == 3, "\(calls.load(ordering: .relaxed)) runs for 52 requests")
    }

    /// B198: an OSC command reaches the engine on the DMX queue; a show-mode entry whose readiness checks hang must not
    /// hold that queue (Art-Net, sACN, OSC parameters). The cue commands run in their order meanwhile (B200).
    /// Wires `onCommand` to the hand-over the way `Engine.start` does; the UDP receive and `start` itself are not run.
    @Test func anOSCCommandDoesNotHoldTheDMXQueue() async throws {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        let release = Hold()
        let checking = Atomic<Bool>(false)
        engine.readinessCheck = { _, _ in
            checking.store(true, ordering: .relaxed)
            release.wait()
            return [ReadinessItem(id: "hung", title: "", state: .hard, detail: "", fix: "")]
        }
        defer { release.done() }
        let ran = Mutex<[String]>([])
        let store = StateStore(project: [:], logger: testLogger)
        // the entry runs in `prepare`, off the control queue, as the real command's does (B200)
        store.register(CommandSpec(name: "show.mode", role: .operator, mutatesConfig: false, undoable: false, summary: "", prepare: { [weak engine] args in
            _ = engine?.setShowMode(true)
            return args
        }) { _, _ in
            ran.withLock { $0.append("show.mode") }
            return nil
        })
        for name in ["cue.go", "cue.goto"] {
            store.register(CommandSpec(name: name, role: .operator, mutatesConfig: false, undoable: false, summary: "") { _, args in
                ran.withLock { $0.append(name + (args["number"]?.double.map { " \($0)" } ?? "")) }
                return nil
            })
        }
        let dmx = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        dmx.onCommand = { [weak engine] in engine?.handOver($0, to: store) }
        dmx.queue.async {
            for command in [OSCCommand.showMode(true), .cueGo, .cueGoto(2), .cueGo] { dmx.apply(command) }
        }
        #expect(await waitUntil { checking.load(ordering: .relaxed) }, "the readiness check started")
        let free = DispatchGroup()
        dmx.queue.async(group: free) {}
        #expect(try await offPool { free.wait(timeout: .now() + 5) } == .success, "the DMX queue waited for the readiness check")
        #expect(await waitUntil { ran.withLock { $0.count } == 3 }, "the cue commands waited for the entry")
        release.signal()
        #expect(await waitUntil { ran.withLock { $0.count } == 4 })
        #expect(ran.withLock { $0 } == ["cue.go", "cue.goto 2.0", "cue.go", "show.mode"])
    }

    /// B198: a console repeating `/fanous/show/mode 1` while the entry's checks hang queues no backlog: the repeats are
    /// dropped while one entry is queued or running, and a cue go sent after them fires once, without waiting (B200).
    @Test func repeatedShowModeEntriesAreCoalescedButACueGoIsNot() async throws {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        let gate = Hold()
        let checks = Atomic<Int>(0)
        engine.readinessCheck = { _, _ in
            checks.add(1, ordering: .relaxed)
            gate.wait(turnstile: true)  // once open, every later check passes at once
            return [ReadinessItem(id: "hung", title: "", state: .hard, detail: "", fix: "")]
        }
        defer { gate.done() }
        let cues = Atomic<Int>(0), leaves = Atomic<Int>(0)
        let store = StateStore(project: [:], logger: testLogger)
        store.register(CommandSpec(name: "show.mode", role: .operator, mutatesConfig: false, undoable: false, summary: "", prepare: { [weak engine] args in
            if args["on"]?.bool == true { _ = engine?.setShowMode(true) }
            return args
        }) { _, args in
            if args["on"]?.bool == false { leaves.add(1, ordering: .relaxed) }
            return nil
        })
        store.register(CommandSpec(name: "cue.go", role: .operator, mutatesConfig: false, undoable: false, summary: "") { _, _ in
            cues.add(1, ordering: .relaxed)
            return nil
        })
        engine.handOver(.showMode(true), to: store)
        #expect(await waitUntil { checks.load(ordering: .relaxed) == 1 }, "the entry started")
        for _ in 0..<100 { engine.handOver(.showMode(true), to: store) }
        engine.handOver(.cueGo, to: store)
        #expect(await waitUntil(.seconds(5)) { cues.load(ordering: .relaxed) == 1 }, "the cue go waited for the entry")
        gate.signal()
        // a leave runs on the show-mode queue after every entry handed over before it: once it ran, they have
        engine.handOver(.showMode(false), to: store)
        #expect(await waitUntil { leaves.load(ordering: .relaxed) == 1 }, "the entries queued before the leave did not finish")
        #expect(checks.load(ordering: .relaxed) <= 2, "\(checks.load(ordering: .relaxed)) readiness runs for 101 entries")
        #expect(cues.load(ordering: .relaxed) == 1)
    }

    /// B245: a check or command a test holds until it opens the gate. It never opens by itself on the test's timeline:
    /// a starved machine (CI) makes a test slow, never wrong. The bound only keeps a broken engine from hanging the
    /// suite, far above any wait in the tests; reaching it fails the test in `done`.
    private final class Hold: Sendable {
        static let lastResort: TimeInterval = 120
        private let semaphore = DispatchSemaphore(value: 0)
        private let timedOut = Atomic<Bool>(false)
        /// `turnstile`: once open, every later wait passes at once.
        func wait(turnstile: Bool = false) {
            if semaphore.wait(timeout: .now() + Self.lastResort) == .timedOut { timedOut.store(true, ordering: .relaxed) }
            if turnstile { semaphore.signal() }
        }
        func signal() { semaphore.signal() }
        /// Opens the gate (a `defer`), and fails the test if it ever opened by itself.
        func done(sourceLocation: SourceLocation = #_sourceLocation) {
            let opened = timedOut.load(ordering: .relaxed)
            #expect(!opened, "a held check opened by itself after \(Self.lastResort) s", sourceLocation: sourceLocation)
            semaphore.signal()
        }
    }

    /// B200: an engine whose `show.mode` and `cue.go` are the real commands on `store`, decided on its queue as after
    /// `start`; the readiness check passes once `gate` opens (a turnstile), or after `checkTime`. Show mode is entered
    /// for real (power assertions for the test's duration), with no state file; `changes` records enters and leaves.
    private final class HeldEntry: Sendable {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        let store = StateStore(project: [:], logger: testLogger)
        let gate = Hold()
        let checks = Atomic<Int>(0)
        let gos = Atomic<Int>(0)
        let changes = Mutex<[Bool]>([])
        init(checkTime: TimeInterval? = nil) {
            engine.store = store
            engine.readinessCheck = { [weak self] _, _ in
                guard let self else { return [] }
                checks.add(1, ordering: .relaxed)
                if let checkTime {
                    Thread.sleep(forTimeInterval: checkTime)
                } else {
                    gate.wait(turnstile: true)
                }
                return []
            }
            engine.showMode.onChange = { [weak self] on in self?.changes.withLock { $0.append(on) } }
            ShowCommands.register(on: store, hooks: ShowCommands.Hooks(
                go: { [weak self] in self?.gos.add(1, ordering: .relaxed) }, back: {}, goto: { _ in },
                showMode: { [weak self] in self?.engine.setShowMode($0) }, acknowledge: { _, _ in }, runReadiness: {}))
        }
        func done(sourceLocation: SourceLocation = #_sourceLocation) {
            gate.done(sourceLocation: sourceLocation)
            _ = store.execute("show.mode", args: ["on": false], role: .operator)
        }
        /// `show.mode true` as a WebSocket connection runs it, on its own queue; true when it was answered ok.
        func enter(in group: DispatchGroup, _ answered: @escaping @Sendable (Bool) -> Void) {
            ShowControlTests.onThread(group) { [self] in answered((try? store.execute("show.mode", args: ["on": true], role: .operator).get()) != nil) }
        }
    }

    /// Runs `body` on a thread of its own, as a WebSocket connection's queue runs a command. Not the global queue: under
    /// the full parallel suite its pool can be used up for seconds by blocked blocks (on CI a `cue.go` queued there did
    /// not start within 1 s; reproduced locally by holding about 64 global blocks for 5 s).
    private static func onThread(_ group: DispatchGroup, _ body: @escaping @Sendable () -> Void) {
        group.enter()
        Thread.detachNewThread {
            body()
            group.leave()
        }
    }

    /// B200: a cue command from OSC/MIDI (the hand-over) and one from the WebSocket (`store.execute`) both run while a
    /// show-mode entry's readiness check is held, whether OSC or the WebSocket started that entry; before, the entry
    /// held the control queue (and, from OSC, the command queue) until its checks were done.
    @Test(arguments: [true, false])
    func aCueCommandDoesNotWaitForAShowModeEntry(fromOSC: Bool) async throws {
        let held = HeldEntry()
        defer { held.done() }
        let entry = DispatchGroup()
        let answers = Mutex<[Bool]>([])
        if fromOSC {
            held.engine.handOver(.showMode(true), to: held.store)
        } else {
            held.enter(in: entry) { ok in answers.withLock { $0.append(ok) } }
        }
        #expect(await waitUntil { held.checks.load(ordering: .relaxed) == 1 }, "the entry's check started")
        held.engine.handOver(.cueGo, to: held.store)
        // the bounds are generous: the old code waits until the gate opens, which happens only after them
        #expect(await waitUntil(.seconds(5)) { held.gos.load(ordering: .relaxed) == 1 }, "the OSC cue go waited for the entry")
        let webSocket = DispatchGroup()
        Self.onThread(webSocket) { _ = held.store.execute("cue.go", role: .operator) }
        #expect(try await offPool { webSocket.wait(timeout: .now() + 5) } == .success, "the WebSocket cue go waited for the entry")
        #expect(held.gos.load(ordering: .relaxed) == 2 && !held.engine.showMode.isOn && answers.withLock { $0 }.isEmpty)
        held.gate.signal()
        #expect(await waitUntil { held.engine.showMode.isOn }, "the entry did not enter once its check passed")
        #expect(try await offPool { entry.wait(timeout: .now() + 5) } == .success)
        #expect(answers.withLock { $0 } == (fromOSC ? [] : [true]) && held.checks.load(ordering: .relaxed) == 1)
    }

    /// B200: `show.mode`s from one console keep their order while an entry's check is held, now that the entry is off
    /// the command queue: `1, 0, 1` ends on, `1, 0` ends off.
    @Test(arguments: [[true, false, true], [true, false]])
    func showModeFromOneConsoleKeepsItsOrder(sequence: [Bool]) async throws {
        let held = HeldEntry()
        defer { held.done() }
        held.engine.handOver(.showMode(true), to: held.store)
        #expect(await waitUntil { held.checks.load(ordering: .relaxed) == 1 })
        for on in sequence.dropFirst() { held.engine.handOver(.showMode(on), to: held.store) }
        held.gate.signal()
        #expect(await waitUntil { held.changes.withLock { $0 } == sequence })
        try await Task.sleep(for: .milliseconds(100))
        #expect(held.changes.withLock { $0 } == sequence && held.engine.showMode.isOn == sequence.last)
    }

    /// B200: a `show.mode false` during an entry runs at once and wins: the entry answers ok without entering. A second
    /// `show.mode true` during an entry waits for it and, the first having entered, answers ok without checks (B163).
    @Test func aLeaveDuringAnEntryWinsAndASecondEntryWaitsForTheFirst() async throws {
        let held = HeldEntry()
        defer { held.done() }
        let entry = DispatchGroup()
        let answers = Mutex<[Bool]>([])
        held.enter(in: entry) { ok in answers.withLock { $0.append(ok) } }
        #expect(await waitUntil { held.checks.load(ordering: .relaxed) == 1 })
        let leave = DispatchGroup()
        Self.onThread(leave) { _ = held.store.execute("show.mode", args: ["on": false], role: .operator) }
        #expect(try await offPool { leave.wait(timeout: .now() + 5) } == .success, "the leave waited for the entry")
        held.gate.signal()
        #expect(try await offPool { entry.wait(timeout: .now() + 5) } == .success)
        #expect(answers.withLock { $0 } == [true] && held.changes.withLock { $0 }.isEmpty, "the entry entered after the leave")

        let second = HeldEntry()
        defer { second.done() }
        let both = DispatchGroup()
        let results = Mutex<[Bool]>([])
        for _ in 0..<2 { second.enter(in: both) { ok in results.withLock { $0.append(ok) } } }
        #expect(await waitUntil { second.checks.load(ordering: .relaxed) == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(second.checks.load(ordering: .relaxed) == 1, "the second entry ran its checks alongside the first")
        second.gate.signal()
        #expect(try await offPool { both.wait(timeout: .now() + 5) } == .success)
        #expect(results.withLock { $0 } == [true, true] && second.changes.withLock { $0 } == [true] && second.checks.load(ordering: .relaxed) == 1)
        // `run` called around `execute` (so without `prepare`'s entry) refuses instead of answering ok
        let spec = try #require(second.store.commandSpecs.first { $0.name == "show.mode" })
        var project: JSONValue = [:]
        #expect(throws: CommandError("failed", "show mode entry did not run")) { _ = try spec.run(&project, ["on": true]) }
    }

    /// B200: a library root switch that starts and ends while an entry's checks run refuses the entry, which checked
    /// against the old root (B51); before, the checks held the control queue, where a switch starts. The switch is
    /// started as `project.set /library/root` starts it (`projectChanged` on the control queue); the engine has no
    /// library, so it ends at once on the library queue, as a fast real switch would. The test waits for that end on the
    /// library queue and checks no switch runs any more, so only the started count can refuse the entry (B258).
    @Test func aLibraryRootSwitchDuringAnEntryRefusesIt() async throws {
        let held = HeldEntry()
        defer { held.done() }
        let entry = DispatchGroup()
        let answer = Mutex<Result<CommandResult, CommandError>?>(nil)
        Self.onThread(entry) {
            let result = held.store.execute("show.mode", args: ["on": true], role: .operator)
            answer.withLock { $0 = result }
        }
        #expect(await waitUntil { held.checks.load(ordering: .relaxed) == 1 })
        held.store.queue.sync { held.engine.projectChanged(["library": ["root": "/tmp/fanous-b200-root"]]) }
        try await offPool { held.engine.libraryQueue.sync {} }  // the switch has run to its end
        #expect(held.engine.librarySwitches.load(ordering: .relaxed) == 0, "a switch still runs: the refusal would not be the started count's")
        held.gate.signal()
        #expect(try await offPool { entry.wait(timeout: .now() + 5) } == .success)
        #expect(answer.withLock { $0 } == .failure(CommandError("notReady", "readiness: libraryRootChanging")), "the entry ignored the switch")
        #expect(!held.engine.showMode.isOn)
    }

    /// B240: an engine that never started knows no project file, so a project change (a show-lock change, saved at
    /// once, or any other, saved after 2 s) schedules no save. The old code saved to `AppPaths.projectFile`: without
    /// FANOUS_HOME, the installed engine's project, 2 s after the test above. With a file, as after `start`, the rules
    /// of a started engine hold: the first change is written at once, a later one waits for the debounce, and a
    /// show-lock change is written at once.
    @Test func aNeverStartedEngineSavesNoProject() throws {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        engine.projectChanged(["name": "b240"])
        engine.projectChanged(["name": "b240", "showLock": true])
        engine.feedQueue.sync {}
        #expect(engine.autosave == nil, "a never-started engine scheduled a project save")
        let file = tempFile("b240-project", ext: "json")
        engine.projectFile = file
        defer { engine.autosave?.cancel() }  // the debounced save below would land after the temp file is removed
        let savedName = { (try? JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file)))?["name"] }
        // the first save is at once: the lock state on disk is not known yet, so `false` counts as a lock change
        engine.projectChanged(["name": "first", "showLock": false])
        engine.feedQueue.sync {}
        #expect(savedName() == "first", "the first change was not written at once")
        engine.projectChanged(["name": "debounced", "showLock": false])
        engine.feedQueue.sync {}
        #expect(savedName() == "first", "a change with the same lock state was not debounced")
        engine.projectChanged(["name": "locked", "showLock": true])
        engine.feedQueue.sync {}
        #expect(savedName() == "locked", "the show-lock change was not written at once")
    }

    /// B241, B242: an engine that never started knows no show-state file and no restart marker, so entering show mode
    /// writes no state and a stop removes no marker. The old code used `AppPaths.showStateFile` and
    /// `AppPaths.restartPendingFile`: without FANOUS_HOME, the installed engine's. The `#require`s end the test before
    /// it enters or stops if the engine knows a file; the files themselves are checked only with FANOUS_HOME set, so a
    /// run without it reads, writes or removes nothing under the real home.
    @Test func aNeverStartedEngineTouchesNoShowStateOrRestartMarker() throws {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        try #require(engine.showMode.stateFile == nil)
        try #require(engine.restartPendingFile == nil)
        let isolated = AppPaths.homeOverride != nil
        if isolated {
            try FileManager.default.createDirectory(at: AppPaths.applicationSupport, withIntermediateDirectories: true)
            try Data().write(to: AppPaths.restartPendingFile)
        }
        defer { if isolated { try? FileManager.default.removeItem(at: AppPaths.restartPendingFile) } }
        engine.showMode.enter()
        if isolated { #expect(!FileManager.default.fileExists(atPath: AppPaths.showStateFile.path), "entering wrote show-state.json") }
        engine.stop()
        #expect(!engine.showMode.isOn)
        if isolated {
            #expect(FileManager.default.fileExists(atPath: AppPaths.restartPendingFile.path), "the stop took the restart marker")
            #expect(!FileManager.default.fileExists(atPath: AppPaths.showStateFile.path), "the stop wrote show-state.json")
        }
    }

    /// B242: with the files `start` sets (temporary ones here), a stop takes a fresh restart marker through the
    /// engine's `restartPendingFile` and keeps show mode in the state file as a restart: Engine › Restart Engine on a
    /// started engine. Only temporary files, so it runs the same with or without FANOUS_HOME. A stop that took
    /// `AppPaths.restartPendingFile` instead would leave the temporary marker and keep nothing.
    @Test func aStopTakesTheRestartMarkerTheEngineKnows() throws {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        let state = tempFile("b242-show-state", ext: "json"), marker = tempFile("b242-restart-pending")
        engine.showMode.persist(to: state)
        engine.restartPendingFile = marker
        try Data().write(to: marker)
        engine.showMode.enter()
        engine.stop()
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the stop did not take the marker the engine knows")
        #expect(ShowModeState.load(from: state)?.restart == true, "show mode was not kept for the restart")
    }

    /// B243: the flush at stop writes the newest change the 2 s autosave has not written yet, at once and once; the
    /// debounced save firing afterwards (`perform()` stands in for its timer) and a second flush write nothing.
    @Test func theFlushAtStopWritesTheUnsavedChangeOnce() throws {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        let file = tempFile("b243-project", ext: "json")
        engine.projectFile = file
        defer { engine.autosave?.cancel() }
        let savedName = { (try? JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file)))?["name"] }
        engine.projectChanged(["name": "first", "showLock": false])  // the first save is at once (B240's test)
        engine.feedQueue.sync {}
        try FileManager.default.removeItem(at: file)
        engine.flushProjectSave()
        #expect(!FileManager.default.fileExists(atPath: file.path), "a flush with nothing unsaved wrote the project")
        engine.projectChanged(["name": "older", "showLock": false])
        engine.projectChanged(["name": "newer", "showLock": false])
        engine.flushProjectSave()
        #expect(savedName() == "newer", "the flush did not write the last unsaved change")
        try FileManager.default.removeItem(at: file)
        engine.autosave?.perform()
        engine.flushProjectSave()
        #expect(!FileManager.default.fileExists(atPath: file.path), "the change was written again after the flush")
    }

    /// B243: with saves still queued on the feed queue when the flush starts (two show-lock changes; the second cancels
    /// the first before it runs, so no older save is truly in flight here), the newest document is on disk after the
    /// flush and stays there. The pass does not depend on when the gate opens; the old flush's failure here does (it
    /// cancelled the queued newer save when it ran before the gate opened).
    @Test func theFlushAtStopRunsAfterTheSavesInFlight() {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        let file = tempFile("b243-inflight", ext: "json")
        engine.projectFile = file
        defer { engine.autosave?.cancel() }
        let savedName = { (try? JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file)))?["name"] }
        engine.projectChanged(["name": "first", "showLock": false])
        engine.feedQueue.sync {}
        let gate = DispatchSemaphore(value: 0)
        engine.feedQueue.async { _ = gate.wait(timeout: .now() + 10) }  // holds the queue: the saves below wait behind it
        engine.projectChanged(["name": "locked", "showLock": true])
        engine.projectChanged(["name": "newer", "showLock": true])
        // opens once the flush below waits on the queue too; the order holds whenever it opens
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { gate.signal() }
        engine.flushProjectSave()
        #expect(savedName() == "newer", "the flush did not end with the newest document on disk")
        engine.feedQueue.sync {}
        #expect(savedName() == "newer", "an older document landed after the flush")
    }

    /// B198: `1, 0, 1` ends on, also when it arrives while an entry runs; a `1` during that entry is dropped (it answers
    /// for it). The store's `show.mode` only records here, so show mode is not really entered.
    @Test func showModeOnOffOnDuringARunningEntryEndsOn() async throws {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        let gate = Hold()
        let started = Atomic<Bool>(false)
        let ran = Mutex<[Bool]>([])
        let store = StateStore(project: [:], logger: testLogger)
        store.register(CommandSpec(name: "show.mode", role: .operator, mutatesConfig: false, undoable: false, summary: "") { _, args in
            if !started.exchange(true, ordering: .relaxed) { gate.wait() }
            ran.withLock { $0.append(args["on"]?.bool ?? false) }
            return nil
        })
        defer { gate.done() }
        engine.handOver(.showMode(true), to: store)  // the running entry, held
        #expect(await waitUntil { started.load(ordering: .relaxed) })
        for command in [OSCCommand.showMode(true), .showMode(false), .showMode(true)] { engine.handOver(command, to: store) }
        gate.signal()
        #expect(await waitUntil { ran.withLock { $0.count } == 3 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(ran.withLock { $0 } == [true, false, true], "the repeat during the entry is dropped, the last state wins")
    }

    /// B193: a refused command logs once per (command, code) and window; the repeats go out with the pair's next line.
    @Test func refusalThrottleLogsTheFirstAndCountsTheRepeats() {
        var throttle = RefusalThrottle()
        #expect(throttle.admit("show.mode", code: "notReady", now: 100) == 0, "the first refusal logs")
        #expect(throttle.admit("show.mode", code: "notReady", now: 101) == nil, "a repeat inside the window is counted")
        #expect(throttle.admit("show.mode", code: "notReady", now: 102.9) == nil)
        #expect(throttle.admit("show.lock", code: "notReady", now: 102.9) == 0, "another command logs at once")
        #expect(throttle.admit("show.mode", code: "forbidden", now: 102.9) == 0, "another code logs at once")
        #expect(throttle.admit("show.mode", code: "notReady", now: 103) == 2, "the window ended: logs with its count")
        #expect(throttle.admit("show.mode", code: "notReady", now: 105.9) == nil, "a new window from that line")
        #expect(throttle.admit("show.mode", code: "notReady", now: 200) == 1)
        #expect(throttle.admit("show.mode", code: "notReady", now: 300) == 0, "nothing counted since the last line")
    }

    /// B193: `/fanous/show/mode 1` while readiness blocks, repeated as a console does, leaves one warning with the
    /// command, the code and the reason; the old code left none.
    @Test func aRefusedOSCCommandLeavesOneWarning() {
        let lines = HTTPSServerLogTests.Lines()
        let logger = Logger(label: "test") { _ in HTTPSServerLogTests.Capture(lines: lines) }
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: logger)
        engine.readinessCheck = { _, _ in
            [ReadinessItem(id: "outputs", title: "", state: .hard, detail: "", fix: ""), ReadinessItem(id: "spotlight", title: "", state: .hard, detail: "", fix: "")]
        }
        let store = StateStore(project: [:], logger: testLogger)
        ShowCommands.register(on: store, hooks: ShowCommands.Hooks(
            go: {}, back: {}, goto: { _ in }, showMode: { [weak engine] in engine?.setShowMode($0) }, acknowledge: { _, _ in }, runReadiness: {}))
        for _ in 0..<40 { engine.runCommand(.showMode(true), on: store) }
        engine.runCommand(.cueGo, on: store)  // accepted: no line
        let refused = lines.all.withLock { $0 }.filter { $0.hasPrefix("OSC/MIDI command refused") }
        #expect(refused == ["OSC/MIDI command refused code=notReady command=/fanous/show/mode 1 reason=readiness: outputs, spotlight"])
    }

    /// B210: the live document carries the last refused command for the OSC panel. A 40-message burst changes it once
    /// (the live document is diffed, so once is one patch); it goes when the same command is accepted, or
    /// `RefusalThrottle.shown` after its last line. The old code had no `refused` at all.
    @Test func aRefusedCommandIsInTheLiveDocumentUntilAcceptedOrAged() {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        let blocking = Atomic<Bool>(true)
        let store = StateStore(project: [:], logger: testLogger)  // `show.mode` refusing as the engine's does, without entering it
        store.register(CommandSpec(name: "show.mode", role: .operator, mutatesConfig: false, undoable: false, summary: "") { _, _ in
            if blocking.load(ordering: .relaxed) { throw CommandError("notReady", "readiness: outputs") }
            return nil
        })
        store.register(CommandSpec(name: "cue.go", role: .operator, mutatesConfig: false, undoable: false, summary: "") { _, _ in nil })
        #expect(engine.refusedLive() == .null)
        var seen: [JSONValue] = []
        for _ in 0..<40 {
            engine.runCommand(.showMode(true), on: store)
            if seen.last != engine.refusedLive() { seen.append(engine.refusedLive()) }
        }
        #expect(seen.count == 1, "a burst inside the throttle window changes the live document once")
        let refused = seen[0]
        #expect(refused["command"] == "/fanous/show/mode 1" && refused["code"] == "notReady" && refused["reason"] == "readiness: outputs")
        #expect((refused["at"]?.double ?? 0) > Date().timeIntervalSince1970 - 5)
        engine.runCommand(.cueGo, on: store)  // accepted, another command: the refusal stays
        #expect(engine.refusedLive() == refused)
        let now = ProcessInfo.processInfo.systemUptime
        #expect(engine.refusedLive(now: now + RefusalThrottle.shown) == .null, "aged out")
        blocking.store(false, ordering: .relaxed)
        engine.runCommand(.showMode(true), on: store)  // the cause fixed, the console sends it again: accepted
        #expect(engine.refusedLive() == .null)
    }

    /// B210 review: a console toggle sends `/fanous/show/mode 1` (refused), `0` (accepted) and `1` again within the
    /// throttle window. The accept ends the refusal, so the second `1` is a new one: logged and shown. Before, the
    /// throttle still held the pair and swallowed it: no line, an empty panel.
    @Test func aRefusalAfterAnAcceptIsShownAndLoggedAgain() {
        let lines = HTTPSServerLogTests.Lines()
        let logger = Logger(label: "test") { _ in HTTPSServerLogTests.Capture(lines: lines) }
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: logger)
        let store = StateStore(project: [:], logger: testLogger)  // `show.mode true` refused, `false` accepted
        store.register(CommandSpec(name: "show.mode", role: .operator, mutatesConfig: false, undoable: false, summary: "") { _, args in
            if args["on"]?.bool == true { throw CommandError("notReady", "readiness: outputs") }
            return nil
        })
        engine.runCommand(.showMode(true), on: store)
        #expect(engine.refusedLive() != .null)
        engine.runCommand(.showMode(false), on: store)
        #expect(engine.refusedLive() == .null, "accepted: the refusal is over")
        engine.runCommand(.showMode(true), on: store)
        #expect(engine.refusedLive()["command"] == "/fanous/show/mode 1", "pressed again: shown again")
        #expect(lines.all.withLock { $0 }.filter { $0.hasPrefix("OSC/MIDI command refused") }.count == 2, "and logged again")
    }

    /// B210 review: a `show.mode` refusal is stale once show mode is on (entered from the web UI, which does not pass
    /// through `runCommand`), and it does not come back when show mode is left. Show mode is entered for real (power
    /// assertions for the test's duration), with no state file.
    @Test func aShowModeRefusalGoesWhenShowModeIsOn() async throws {
        let engine = Engine(options: EngineOptions(webRoot: URL(fileURLWithPath: "/")), logger: testLogger)
        engine.readinessCheck = { _, _ in [] }
        let store = StateStore(project: [:], logger: testLogger)
        store.register(CommandSpec(name: "show.mode", role: .operator, mutatesConfig: false, undoable: false, summary: "") { _, _ in
            throw CommandError("notReady", "readiness: outputs")
        })
        engine.runCommand(.showMode(true), on: store)
        #expect(engine.refusedLive() != .null)
        #expect(try await offPool { engine.setShowMode(true) } == nil)
        #expect(engine.refusedLive() == .null, "show mode is on: the refusal no longer holds")
        #expect(try await offPool { engine.setShowMode(false) } == nil)
        #expect(engine.refusedLive() == .null, "and it does not come back")
    }

    @Test func readinessReflectsTheContextAndRunsEveryProbe() {
        var context = ReadinessContext()
        context.universesSilent = ["artnet:0.0.1"]
        context.interfacesMissing = ["sacn:2: en5"]
        context.outputsLost = [2]
        context.outputsBound = 1
        context.modeIssues = ["Output 1: unavailable"]
        context.layerErrors = []
        context.syncLost = ["Layer 2 (group 1)"]
        context.libraryRoot = NSHomeDirectory()
        let items = Readiness.check(context, acknowledged: ["dmx"])
        let ids = items.map(\.id)
        #expect(ids == ["project", "power", "thermal", "disk", "memory", "dmx", "interfaces", "artnetport", "sacnport", "oscport", "outputs", "modes", "syncmaster", "syncpackets", "camera", "screen", "microphone", "decoders", "maskimages", "library", "spotlight", "updates", "timemachine", "focus", "displaysleep", "hardware"])
        let dmx = items.first { $0.id == "dmx" }!
        #expect(dmx.state == .fail && dmx.acknowledged && !dmx.blocks)
        let outputs = items.first { $0.id == "outputs" }!
        #expect(outputs.state == .fail && outputs.blocks && outputs.detail.contains("lost: [2]"))
        #expect(items.first { $0.id == "focus" }!.state == .manual)
        let modes = items.first { $0.id == "modes" }!
        #expect(modes.state == .warn && !modes.blocks && modes.detail == "Output 1: unavailable")
        let interfaces = items.first { $0.id == "interfaces" }!
        #expect(interfaces.state == .warn && !interfaces.blocks && interfaces.detail == "not usable: sacn:2: en5")
        #expect(items.first { $0.id == "hardware" }!.state == .ok)
        #expect(items.first { $0.id == "syncmaster" }!.state == .ok)
        let sync = items.first { $0.id == "syncpackets" }!
        #expect(sync.state == .warn && !sync.blocks && sync.detail.contains("Layer 2 (group 1)"))
        #expect(items.first { $0.id == "library" }!.state == .ok)
        // B182: an exclusion under Spotlight Privacy is not readable without root, so the hint must not offer it
        #expect(items.first { $0.id == "spotlight" }!.fix == "sudo mdutil -i off <volume>")
        #expect(items.allSatisfy { !$0.fix.isEmpty && !$0.detail.isEmpty })
    }

    /// B180: show mode's PreventUserIdleDisplaySleep assertion keeps the display awake whatever `pmset` displaysleep says,
    /// so a timeout warns (never blocks); Never passes, and so does an unreadable value.
    @Test func displaySleepWarnsWhileShowModeHoldsTheDisplayAwake() {
        let never = Readiness.displaySleep(minutes: 0, acknowledged: [])
        #expect(never.id == "displaysleep" && never.state == .ok && never.detail == "never")
        let ten = Readiness.displaySleep(minutes: 10, acknowledged: [])
        #expect(ten.state == .warn && !ten.blocks && ten.detail == "10 min; show mode keeps the display awake")
        let unknown = Readiness.displaySleep(minutes: nil, acknowledged: [])
        #expect(unknown.state == .ok && !unknown.blocks && unknown.detail == "unknown")
    }

    @Test func showModeAssertionsToggle() {
        let controller = ShowModeController(logger: testLogger)
        let changes = Mutex<[Bool]>([])
        controller.onChange = { on in changes.withLock { $0.append(on) } }
        controller.enter()
        #expect(controller.isOn)
        controller.enter()  // idempotent
        controller.leave()
        #expect(!controller.isOn)
        #expect(changes.withLock { $0 } == [true, false])
    }

    /// Enter writes the state (with the write time), leave removes it; a run that ends without leaving keeps
    /// it for the next start.
    @Test func showModeStateSurvivesOnlyAnUncleanEnd() throws {
        let directory = try tempDir("fanous-show")
        let url = directory.appending(path: "show-state.json")
        #expect(ShowModeState.load(from: url) == nil)  // normal start

        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let crashed = showMode(persistingTo: url)
        crashed.enter(since: since)
        // a kill -9 here: nothing more runs, so the next start sees show mode on, just written
        let saved = try #require(ShowModeState.load(from: url))
        #expect(saved.since == since.timeIntervalSince1970 && saved.restart == nil)
        #expect(abs(saved.written - Date().timeIntervalSince1970) < 5)

        let restarted = showMode(persistingTo: url)
        restarted.enter(since: since)  // the resume keeps the original entry time
        #expect(ShowModeState.load(from: url)?.since == since.timeIntervalSince1970)
        restarted.leave()  // leaving
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(ShowModeState.load(from: url) == nil)
        crashed.leave()  // releases this test's assertions

        try Data(#"{"on":false,"since":0,"boot":0,"written":0}"#.utf8).write(to: url)
        #expect(ShowModeState.load(from: url) == nil)
        try Data(#"{"on":true,"since":0}"#.utf8).write(to: url)  // the first format: no write time, start normally
        #expect(ShowModeState.load(from: url) == nil)
        try Data("garbage".utf8).write(to: url)
        #expect(ShowModeState.load(from: url) == nil)  // unreadable: start normally
    }

    /// `touch()` refreshes the write time while on (the 30 s readiness timer), so a crash in a show longer than 2 h still
    /// resumes (B186); while off it writes nothing.
    @Test func showModeTouchRefreshesTheWriteTime() throws {
        let directory = try tempDir("fanous-show")
        let url = directory.appending(path: "show-state.json")
        let show = showMode(persistingTo: url)
        show.enter(since: Date(timeIntervalSince1970: 1_800_000_000))
        var old = try #require(ShowModeState.load(from: url))
        old.written -= 3 * 3600
        try JSONEncoder().encode(old).write(to: url)
        #expect(ShowModeState.decide(ShowModeState.load(from: url), now: Date().timeIntervalSince1970) == .stale)
        show.touch()
        let now = Date().timeIntervalSince1970  // after the write: a time before it would be a write in the future
        let fresh = try #require(ShowModeState.load(from: url))
        #expect(abs(fresh.written - now) < 5)
        #expect(ShowModeState.decide(fresh, now: now) == .resume(fresh))
        show.leave()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        show.touch()  // off: no file
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// B284: the cue list state rides in the state file: written on enter and on every change while on, kept for a
    /// restart, nothing while off, gone when show mode is left. A file of an older build (no `cue`) still loads.
    @Test func showModeStateCarriesTheCueListState() throws {
        let url = try tempDir("fanous-show").appending(path: "show-state.json")
        let show = showMode(persistingTo: url)
        let (three, four) = (UUID(), UUID())
        let held: [UUID: [CueValue]] = [
            three: [CueValue(fixture: .layer(3), parameter: .layer(.intensity), raw: 40000)],
            four: [CueValue(fixture: .master, parameter: .master(.intensity), raw: 65535)],
        ]
        show.setCue(three, number: 3, targets: held)
        #expect(!FileManager.default.fileExists(atPath: url.path), "off: no file")
        show.enter()
        let entered = try #require(ShowModeState.load(from: url))
        #expect(entered.cue == three && entered.cueNumber == 3 && entered.targets == held)
        show.setCue(four, number: 4, targets: [:])
        #expect(ShowModeState.load(from: url)?.cue == four && ShowModeState.load(from: url)?.held == nil)
        show.setCue(four, number: 4, targets: held)
        show.stop(keepingState: true)
        let kept = try #require(ShowModeState.load(from: url))
        #expect(kept.restart == true && kept.cue == four && kept.cueNumber == 4 && kept.targets == held)

        let left = showMode(persistingTo: url)
        left.setCue(four, number: 4, targets: held)
        left.enter()
        left.leave()
        #expect(!FileManager.default.fileExists(atPath: url.path), "leaving show mode removes the cue list state with it")

        try Data(#"{"on":true,"since":1,"written":2}"#.utf8).write(to: url)
        let old = try #require(ShowModeState.load(from: url))
        #expect(old.cue == nil && old.cueNumber == nil && old.targets.isEmpty)
        var stale = kept
        stale.written -= ShowModeState.maxAge + 1
        #expect(ShowModeState.decide(stale, now: kept.written) == .stale, "a stale file resumes nothing, cue included")
    }

    /// B284: a hand edit loses only itself, never the resume: a bad `cue` is no current cue, a bad `held` is no held
    /// values, and a bad entry in `held` (a raw beyond 0–65535 or not a number, a fixture or parameter that does not
    /// parse) is left out while the cue and the other values stay.
    @Test func aBadCueListStateStillResumesShowMode() throws {
        let url = try tempDir("fanous-show").appending(path: "show-state.json")
        let id = UUID().uuidString
        let other = UUID().uuidString
        let base = #"{"on":true,"since":1,"written":2"#
        for (json, cue) in [
            (base + #","cue":"nope","cueNumber":"x","held":[1]}"#, nil as UUID?),
            (base + #","cue":"\#(id)","cueNumber":3,"held":"x"}"#, UUID(uuidString: id)),
        ] {
            try Data(json.utf8).write(to: url)
            let state = try #require(ShowModeState.load(from: url), "\(json)")
            #expect(state.on && state.cue == cue && state.targets.isEmpty, "\(json)")
        }
        let entries = #""\#(id)":{"Layer 1/intensity":7,"Layer 2/intensity":70000,"Layer 3/intensity":-1,"Layer 4/intensity":"x","Layer 1/nope":1,"Moon/x":2},"#
            + #""\#(other)":{"Master/intensity":3},"x":{"Master/intensity":4}"#
        try Data((base + #","cue":"\#(id)","cueNumber":3,"held":{"# + entries + "}}").utf8).write(to: url)
        let state = try #require(ShowModeState.load(from: url))
        #expect(state.cue == UUID(uuidString: id) && state.cueNumber == 3)
        #expect(state.targets == [
            UUID(uuidString: id)!: [CueValue(fixture: .layer(1), parameter: .layer(.intensity), raw: 7)],
            UUID(uuidString: other)!: [CueValue(fixture: .master, parameter: .master(.intensity), raw: 3)],
        ])
    }

    /// B284: the list and the resumed state go in as one step at start, so the runner reports only the resumed state,
    /// never the empty one in between (a report of it could reach the file after the resumed one). The held values are
    /// back at once (no fade from 0); a change is reported, not a tick; the next GO fires the cue after the resumed
    /// one. After `stop` nothing changes.
    @Test func cueRunnerResumesTheStateAndReportsChanges() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        store.setPolicy(.internal)
        let runner = CueRunner(dmx: store)
        defer { runner.stop() }
        let reported = Mutex<[UUID?]>([])
        let lastTargets = Mutex<[UUID: [CueValue]]>([:])
        runner.onStateChange = { cue, targets in
            reported.withLock { $0.append(cue?.id) }
            lastTargets.withLock { $0 = targets }
        }
        let half = CueValue(fixture: .layer(1), parameter: .layer(.intensity), raw: 32768)
        let list = CueList(cues: [Cue(number: 1, fadeTime: 5, values: [half]), Cue(number: 2, fadeTime: 5), Cue(number: 3, fadeTime: 0)])
        runner.replace(list: list, resuming: (list.cues[1].id, 2, [list.cues[0].id: [half]]))
        // B354: the runner writes its status first, then calls onStateChange, and the values reach the snapshot later, on
        // the DMX queue: wait for the report, the last of the runner's steps, then let the DMX queue run what it was sent
        #expect(await waitUntil { !reported.withLock { $0 }.isEmpty })
        #expect(reported.withLock { $0 } == [list.cues[1].id], "only the resumed state is reported at start")
        #expect(runner.status.withLock { $0.current } == 2)
        try await offPool { store.queue.sync {} }
        // one read: a resume starts no tick timer, so a value that faded in from 0 would still be near 0 here
        #expect(abs(store.snapshots.withLatest { $0.layers[0].intensity } - 0.5) < 0.01, "the held value at once, not fading from 0")
        #expect(!runner.status.withLock { $0.fading })
        runner.go()
        #expect(await waitUntil { runner.status.withLock { $0.current } == 3 })
        #expect(await waitUntil { reported.withLock { $0 } == [list.cues[1].id, list.cues[2].id] })
        #expect(lastTargets.withLock { $0 } == [list.cues[0].id: [half]])
        runner.stop()
        runner.back()
        runner.stop()  // waits for the queued back
        #expect(runner.status.withLock { $0.current } == 3 && reported.withLock { $0.count } == 2, "a command after stop changed the state")
    }

    /// B284: at start the engine writes the state the runner will land on (a resume on a scratch `CueEngine`, as
    /// `Engine.start` does), so its direct write and the runner's later report put the same file down, in either order:
    /// for a stored cue that is gone (the earlier cue instead), an owner that left the list (dropped) and a raw beyond its
    /// range (clamped). Writing the stored state instead would leave the gone cue's id in the file until the next fire.
    @Test func theStartWriteEqualsTheRunnersReport() async throws {
        let dir = try tempDir("fanous-show")
        let one = CueValue(fixture: .layer(1), parameter: .layer(.intensity), raw: 20000)
        let mode = CueValue(fixture: .layer(1), parameter: .layer(.playMode), raw: 65535)
        let list = CueList(cues: [Cue(number: 1, values: [one]), Cue(number: 2, values: [mode])])
        let (gone, left) = (UUID(), UUID())
        let stored: [UUID: [CueValue]] = [list.cues[0].id: [one], list.cues[1].id: [mode], left: [CueValue(fixture: .layer(2), parameter: .layer(.intensity), raw: 9)]]

        var landed = CueEngine(list: list)
        landed.resume(current: gone, number: 2.5, targets: stored)
        let direct = showMode(persistingTo: dir.appending(path: "direct.json"))
        direct.setCue(landed.current?.id, number: landed.current?.number, targets: landed.targets)
        direct.enter()
        defer { direct.leave() }

        let runner = CueRunner(dmx: DMXStore(patch: .standard(layers: 2, outputs: 0), logger: testLogger))
        defer { runner.stop() }
        let report = Mutex<(cue: Cue?, targets: [UUID: [CueValue]])?>(nil)
        runner.onStateChange = { cue, targets in report.withLock { $0 = (cue, targets) } }
        runner.replace(list: list, resuming: (gone, 2.5, stored))
        #expect(await waitUntil { report.withLock { $0 } != nil })
        let reported = try #require(report.withLock { $0 })
        let viaRunner = showMode(persistingTo: dir.appending(path: "runner.json"))
        viaRunner.setCue(reported.cue?.id, number: reported.cue?.number, targets: reported.targets)
        viaRunner.enter()
        defer { viaRunner.leave() }

        let a = try #require(ShowModeState.load(from: dir.appending(path: "direct.json")))
        let b = try #require(ShowModeState.load(from: dir.appending(path: "runner.json")))
        #expect(a.cue == list.cues[1].id && a.cueNumber == 2, "the earlier cue, not the gone one")
        #expect(a.cue == b.cue && a.cueNumber == b.cueNumber && a.held == b.held)
        #expect(a.held?[left.uuidString] == nil, "the owner that left the list is dropped")
        #expect(a.held?[list.cues[1].id.uuidString]?.values.first == ChannelMap.spec(.layer(.playMode)).clamped(65535), "the raw clamped")
    }

    /// B284: a running fade is ticked at 50 Hz but changes no target: it reports at the GO (after the report of the list), not per tick or at
    /// its end.
    @Test func aRunningFadeReportsNothing() async throws {
        let store = DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger)
        let runner = CueRunner(dmx: store)
        defer { runner.stop() }
        let reported = Mutex(0)
        runner.onStateChange = { _, _ in reported.withLock { $0 += 1 } }
        let full = CueValue(fixture: .layer(1), parameter: .layer(.intensity), raw: 65535)
        runner.replace(list: CueList(cues: [Cue(number: 1, fadeTime: 0.3, values: [full])]))
        #expect(await waitUntil { runner.status.withLock { $0.count } == 1 })
        let fired = ContinuousClock.now
        runner.go()
        // only the end state: a poll that is held up for the 0.3 s of the fade never sees `fading` (seen on CI, B350)
        #expect(await waitUntil { runner.status.withLock { $0.current == 1 && !$0.fading } }, "the fade ends")
        #expect(ContinuousClock.now - fired >= .milliseconds(290), "a fade ran: the end state did not come at once")
        runner.stop()
        #expect(reported.withLock { $0 } == 2, "the list and the GO, nothing for the fade's ticks or its end")
    }

    /// Resume only within 2 h of the last write, whether the engine died or the Mac (B186): a crash nobody restarted
    /// does not resume show mode days later. A file written in the future (clock stepped back) is stale.
    @Test func showModeStartDecision() throws {
        let now = 1_800_000_000.0
        let state = ShowModeState(since: now - 3 * 3600, written: now - 600)
        #expect(ShowModeState.decide(nil, now: now) == .none)
        #expect(ShowModeState.decide(state, now: now) == .resume(state))  // 10 min old: crash, restart or reboot mid-show
        var old = state
        old.written = now - 3 * 3600
        #expect(ShowModeState.decide(old, now: now) == .stale)  // 3 h old, also on the same boot
        old.written = now - ShowModeState.maxAge
        #expect(ShowModeState.decide(old, now: now) == .stale)
        var future = state
        future.written = now + 60
        #expect(ShowModeState.decide(future, now: now) == .stale)
        var off = state
        off.on = false
        #expect(ShowModeState.decide(off, now: now) == .none)
        // a file of the previous format (with `boot`) still decodes
        let decoded = try JSONDecoder().decode(ShowModeState.self, from: Data(#"{"on":true,"since":1,"boot":2,"written":3}"#.utf8))
        #expect(decoded == ShowModeState(since: 1, written: 3))
    }

    /// Engine.stop: a fresh restart marker keeps show mode on disk (marked as a restart); no marker, an old one, or
    /// show mode off is a clean stop. Nothing enters after the stop began.
    @Test func showModeStopDecision() throws {
        let directory = try tempDir("fanous-show")
        let url = directory.appending(path: "show-state.json"), marker = directory.appending(path: "restart-pending")

        #expect(!ShowModeState.takeRestartMarker(at: marker))  // no marker: Stop Engine, logout, bootout
        try Data().write(to: marker)
        #expect(ShowModeState.takeRestartMarker(at: marker))
        #expect(!FileManager.default.fileExists(atPath: marker.path))  // consumed
        try Data().write(to: marker)
        #expect(!ShowModeState.takeRestartMarker(at: marker, now: Date().addingTimeInterval(120)))  // a failed restart's
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let restarting = showMode(persistingTo: url)
        let changes = Mutex<[Bool]>([])
        restarting.onChange = { on in changes.withLock { $0.append(on) } }
        restarting.enter(since: since)
        #expect(restarting.stop(keepingState: true))
        #expect(!restarting.isOn)
        #expect(changes.withLock { $0 } == [true])  // no leave side effects: ingest, display restore, canvas
        let kept = try #require(ShowModeState.load(from: url))
        #expect(kept.restart == true && kept.since == since.timeIntervalSince1970)
        #expect(ShowModeState.decide(kept, now: Date().timeIntervalSince1970) == .resume(kept))
        restarting.enter()  // refused while stopping
        #expect(!restarting.isOn)

        let stopping = showMode(persistingTo: url)
        stopping.enter()
        #expect(!stopping.stop(keepingState: false))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        stopping.enter()
        #expect(!stopping.isOn && !FileManager.default.fileExists(atPath: url.path))

        let idle = showMode(persistingTo: url)
        #expect(!idle.stop(keepingState: true))  // restart outside show mode: nothing kept
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

/// The ShowControlTests that need the GPU or a decoder: local and self-hosted runs only (scripts/test.sh --hosted leaves them out).
@Suite(.cleansTempFiles)
struct ShowControlGPUTests {
    @Test func compositorChasesTimecode() async throws {
        let context = try MetalContext()
        let (compositor, parameters) = try makeCompositor(context, size: (64, 36))
        // a movie of 100 frames at 25 fps; the chase only needs its frameCount and frameRate: the decoder never starts
        let url = tempFile("fanous-chase", ext: "mov")
        try await writePatternMovie(to: url, size: (64, 36), fps: 25, frames: 100, codec: .hap(.hap))
        let movie = try await MovieSource.open(url: url, device: context.device, poolSize: 3)  // ring + 1, as the loader opens it (B386)
        let ring = FrameRing(capacity: 2)
        let decoder = LayerDecoder(source: movie, ring: ring, logger: testLogger)
        let playback = LayerPlayback(key: MediaKey(folder: 1, file: 1), movie: movie, decoder: decoder, ring: ring)
        compositor.setLayers([.playing(playback)])
        let clock = TimecodeClock()
        compositor.timecode = clock
        compositor.timecodeOffsets = TimecodeOffsets(project: 25, layers: [1: 5])  // one second + five frames
        parameters.write { slot in
            slot.sequence = 1
            slot.layers[0].intensity = 1
            slot.layers[0].folder = 1
            slot.layers[0].file = 1
            slot.layers[0].playMode = .timecode
        }
        clock.update(Timecode(frameCount: 100, rate: .fps25), at: 1000, source: "test")
        compositor.tick(target: 1000, drawable: nil)
        // (100 − 25 − 5) frames at 25 fps = 2.8 s = frame 70 of the file
        #expect(abs(playback.clock.position - 70) < 1e-6, "\(playback.clock.position)")
    }
}
