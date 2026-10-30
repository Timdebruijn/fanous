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

struct ShowControlTests {
    static let logger = Logger(label: "test")

    @Test func cueFollowFiresWithoutAFade() async throws {
        let runner = CueRunner(dmx: DMXStore(patch: .standard(layers: 1, outputs: 1), logger: Self.logger))
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

    /// Acceptance: chase accuracy ±1 frame against a generated LTC file (the decoder → clock path of `LTCInput`).
    @Test func ltcFileChasesWithinOneFrame() throws {
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
        var chased: Double?
        var later: Double?
        while index < samples.count {
            let chunk = Array(samples[index..<min(samples.count, index + 512)])
            for frame in decoder.process(chunk) {
                clock.update(frame.timecode, at: Double(frame.endSampleIndex) / sampleRate, source: "LTC")
                decoded += 1
            }
            index += 512
            let now = Double(index) / sampleRate
            if chased == nil, now >= t { chased = clock.frames(at: now) }
            if later == nil, now >= t + 0.02 { later = clock.frames(at: now) }
        }
        #expect(decoded >= 70, "decoded \(decoded) of 75 frames")
        let atT = try #require(chased)
        #expect(abs(atT - Double(90_000 + 61)) <= 1, "chased \(atT - 90_000) at t ≈ \(t) s")
        let atLater = try #require(later)
        #expect(abs(atLater - Double(90_000 + 61.5)) <= 1, "chased \(atLater - 90_000) half a frame later")
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
            if input.status.withLock({ !$0.connected.contains(name) }) { input.setSources([uid: name]) }
            input.receive(words.map { ($0, hostTime) }, uid: uid)
        }
    }

    @Test func mtcQuarterFramesAssembleATimecode() {
        let clock = TimecodeClock()
        let input = MTCInput(clock: clock, logger: Self.logger)
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
        let input = MTCInput(clock: clock, logger: Self.logger)
        input.queue.sync { input.setSources([1: "Pad", 2: "Console"]) }
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
        input.queue.sync { input.setSources([1: "Pad"]) }
        #expect(input.status.withLock { $0.connected } == ["Pad"], "the device list drops it at once")
        #expect(clock.current(at: 10.5).state == .freewheel, "an unplugged source is signal loss: freewheel")
        input.queue.sync { input.receive(b.map { ($0, 11) }, uid: 2) }
        #expect(clock.current(at: 11).state == .freewheel, "words in flight from the gone source are dropped")
        #expect(clock.current(at: 12.5).state == .lost, "lost after the freewheel time (2 s)")
        #expect(clock.frames(at: 12.5) == nil)
        // the pad sends again: locked
        Self.feed(input, a, at: 13, uid: 1, name: "Pad")
        #expect(clock.current(at: 13).state == .locked)
        input.queue.sync { input.setSources([:]) }
        #expect(input.status.withLock { $0 }.error == "no MIDI source connected")
        input.stop()
        #expect(clock.current(at: 14).state == .off)
    }

    @Test func cueJSONRoundTripAndCommands() throws {
        let (store, _) = StateStoreTests.makeStore()
        let fired = Mutex<[String]>([])
        ShowCommands.register(
            on: store,
            hooks: ShowCommands.Hooks(
                go: { fired.withLock { $0.append("go") } }, back: { fired.withLock { $0.append("back") } }, goto: { number in fired.withLock { $0.append("goto \(number)") } },
                showMode: { _ in ["power"] }, acknowledge: { id in fired.withLock { $0.append("ack \(id)") } }, runReadiness: { fired.withLock { $0.append("run") } }))
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
        _ = try store.execute("timecode.set", args: ["path": "/source", "value": "mtc"], role: .programmer).get()
        _ = try store.execute("timecode.set", args: ["path": "/layerOffsets/3", "value": 12], role: .programmer).get()
        let settings = ShowCommands.timecodeSettings(from: store.project)
        #expect(settings.source == .mtc && settings.layerOffsets["3"] == 12)
        #expect(store.execute("timecode.set", args: ["path": "/source", "value": "vhs"], role: .programmer).failureCode == "invalidArgs")
        #expect(fired.withLock { $0 } == ["go", "goto 1.5", "ack power"])
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
        #expect(ids == ["power", "thermal", "disk", "memory", "dmx", "interfaces", "sacnport", "outputs", "modes", "syncmaster", "syncpackets", "decoders", "library", "spotlight", "updates", "timemachine", "focus", "displaysleep", "hardware"])
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
        #expect(items.allSatisfy { !$0.fix.isEmpty && !$0.detail.isEmpty })
    }

    @Test func showModeAssertionsToggle() {
        let controller = ShowModeController(logger: Self.logger)
        let changes = Mutex<[Bool]>([])
        controller.onChange = { on in changes.withLock { $0.append(on) } }
        controller.enter()
        #expect(controller.isOn)
        controller.enter()  // idempotent
        controller.leave()
        #expect(!controller.isOn)
        #expect(changes.withLock { $0 } == [true, false])
    }

    /// Enter writes the state (with the boot and write time), leave removes it; a run that ends without leaving keeps
    /// it for the next start.
    @Test func showModeStateSurvivesOnlyAnUncleanEnd() throws {
        let directory = try tempDir("fanous-show")
        let url = directory.appending(path: "show-state.json")
        #expect(ShowModeState.load(from: url) == nil)  // normal start

        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let crashed = ShowModeController(logger: Self.logger, stateURL: url)
        crashed.enter(since: since)
        // a kill -9 here: nothing more runs, so the next start sees show mode on, written in this boot
        let saved = try #require(ShowModeState.load(from: url))
        #expect(saved.since == since.timeIntervalSince1970 && saved.restart == nil)
        #expect(saved.boot == ShowModeState.bootTime && saved.boot > 0)
        #expect(abs(saved.written - Date().timeIntervalSince1970) < 5)

        let restarted = ShowModeController(logger: Self.logger, stateURL: url)
        restarted.enter(since: since)  // the resume keeps the original entry time
        #expect(ShowModeState.load(from: url)?.since == since.timeIntervalSince1970)
        restarted.leave()  // leaving
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(ShowModeState.load(from: url) == nil)
        crashed.leave()  // releases this test's assertions

        try Data(#"{"on":false,"since":0,"boot":0,"written":0}"#.utf8).write(to: url)
        #expect(ShowModeState.load(from: url) == nil)
        try Data(#"{"on":true,"since":0}"#.utf8).write(to: url)  // the first format: no boot time, start normally
        #expect(ShowModeState.load(from: url) == nil)
        try Data("garbage".utf8).write(to: url)
        #expect(ShowModeState.load(from: url) == nil)  // unreadable: start normally
    }

    /// Same boot (engine crash or kill): resume however old. Other boot: resume only within 2 h (power loss, panic).
    @Test func showModeStartDecision() {
        let boot = 1_800_000_000.0, now = boot + 10 * 3600
        let state = ShowModeState(since: boot + 60, boot: boot, written: boot + 120)
        #expect(ShowModeState.decide(nil, boot: boot, now: now) == .none)
        #expect(ShowModeState.decide(state, boot: boot, now: now) == .resume(state))  // 10 h old, same boot
        #expect(ShowModeState.decide(state, boot: boot + 2, now: now) == .resume(state))  // clock stepped a little
        var young = state
        young.written = now - 3600
        #expect(ShowModeState.decide(young, boot: now - 60, now: now) == .resume(young))  // rebooted mid-show
        #expect(ShowModeState.decide(state, boot: now - 60, now: now) == .stale)  // rebooted, file from a show long ago
        var off = state
        off.on = false
        #expect(ShowModeState.decide(off, boot: boot, now: now) == .none)
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
        let restarting = ShowModeController(logger: Self.logger, stateURL: url)
        let changes = Mutex<[Bool]>([])
        restarting.onChange = { on in changes.withLock { $0.append(on) } }
        restarting.enter(since: since)
        #expect(restarting.stop(keepingState: true))
        #expect(!restarting.isOn)
        #expect(changes.withLock { $0 } == [true])  // no leave side effects: ingest, display restore, canvas
        let kept = try #require(ShowModeState.load(from: url))
        #expect(kept.restart == true && kept.since == since.timeIntervalSince1970)
        #expect(ShowModeState.decide(kept, boot: ShowModeState.bootTime, now: Date().timeIntervalSince1970) == .resume(kept))
        restarting.enter()  // refused while stopping
        #expect(!restarting.isOn)

        let stopping = ShowModeController(logger: Self.logger, stateURL: url)
        stopping.enter()
        #expect(!stopping.stop(keepingState: false))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        stopping.enter()
        #expect(!stopping.isOn && !FileManager.default.fileExists(atPath: url.path))

        let idle = ShowModeController(logger: Self.logger, stateURL: url)
        #expect(!idle.stop(keepingState: true))  // restart outside show mode: nothing kept
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func compositorChasesTimecode() throws {
        let context = try MetalContext()
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) }
        let compositor = try Compositor(
            context: context, canvasWidth: 64, canvasHeight: 36, fps: 60, maxLayers: 1, metrics: MetricsRing(capacity: 16), parameters: parameters, logger: Self.logger)
        let still = try OutputPassTests.flat(context.device, value: 100)
        // a "movie" of 250 frames at 25 fps built from the still: the clock only needs frameCount and frameRate
        let playback = LayerPlayback(key: MediaKey(folder: 1, file: 1), still: still)
        let layer = RenderLayer(index: 0)
        layer.current = playback
        layer.wanted.store(MediaKey(folder: 1, file: 1).packed, ordering: .relaxed)
        compositor.setLayers([layer])
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
        // (100 − 25 − 5) frames at 25 fps = 2.8 s; a still has one frame, so the chase clamps to it
        #expect(playback.clock.position == 0)
        #expect(playback.frameCount == 1)
    }
}
