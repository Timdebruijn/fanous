// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousCore

@Suite struct CueTests {
    static func list() -> CueList {
        CueList(cues: [
            Cue(number: 1, name: "Fade up", fadeTime: 1, values: [CueValue(fixture: .layer(1), parameter: .layer(.intensity), raw: 65535)]),
            Cue(number: 2, name: "Reverse", fadeTime: 1, values: [CueValue(fixture: .layer(1), parameter: .layer(.playMode), raw: 17)]),
            Cue(number: 3, name: "Timed", fadeTime: 0, values: [CueValue(fixture: .master, parameter: .master(.intensity), raw: 0)],
                timecodeTrigger: Timecode(hours: 0, minutes: 0, seconds: 10, frames: 0, rate: .fps25)),
        ])
    }

    @Test func goFadesContinuousAndSnapsBands() {
        var engine = CueEngine(list: Self.list())
        #expect(engine.current == nil && engine.next?.number == 1)
        engine.go(at: 0)
        #expect(engine.current?.number == 1)
        let half = engine.tick(at: 0.5)
        #expect(half == [CueValue(fixture: .layer(1), parameter: .layer(.intensity), raw: 32768)])
        #expect(engine.isFading)
        #expect(engine.tick(at: 1.0).first?.raw == 65535)
        #expect(!engine.isFading)
        engine.go(at: 2)
        let outputs = engine.tick(at: 2.0)
        #expect(outputs.contains(CueValue(fixture: .layer(1), parameter: .layer(.playMode), raw: 17)))
        #expect(outputs.contains(CueValue(fixture: .layer(1), parameter: .layer(.intensity), raw: 65535)))
        engine.back(at: 3)
        #expect(engine.current?.number == 1)
        engine.goto(number: 3, at: 4)
        #expect(engine.current?.number == 3)
        #expect(engine.tick(at: 4).contains(CueValue(fixture: .master, parameter: .master(.intensity), raw: 0)))
        engine.goto(number: 99, at: 5)
        #expect(engine.current?.number == 3)
    }

    @Test func timecodeTriggersOnceAndRearmsOnJumpBack() {
        var engine = CueEngine(list: Self.list())
        func tc(_ s: Int, _ f: Int) -> Timecode { Timecode(hours: 0, minutes: 0, seconds: s, frames: f, rate: .fps25) }
        engine.timecode(tc(9, 20), at: 0)
        engine.timecode(tc(9, 24), at: 0.1)
        #expect(engine.current == nil)
        engine.timecode(tc(10, 0), at: 0.2)
        #expect(engine.current?.number == 3)
        engine.go(at: 0.3)  // nothing after cue 3
        #expect(engine.current?.number == 3)
        engine.timecode(tc(10, 1), at: 0.4)
        #expect(engine.current?.number == 3)
        engine.timecode(tc(9, 0), at: 0.5)  // jump back re-arms
        engine.goto(number: 1, at: 0.6)
        engine.timecode(tc(10, 3), at: 0.7)
        #expect(engine.current?.number == 3)
        engine.goto(number: 1, at: 0.8)
        engine.timecode(tc(20, 0), at: 0.9)  // a jump of 10 s does not fire
        #expect(engine.current?.number == 1)
    }

    @Test func followFiresTheNextCue() {
        var list = Self.list()
        list.insert(Cue(number: 1, fadeTime: 0, values: [], followTime: 0.5))
        var engine = CueEngine(list: list)
        engine.go(at: 0)
        _ = engine.tick(at: 0.4)
        #expect(engine.current?.number == 1)
        _ = engine.tick(at: 0.6)
        #expect(engine.current?.number == 2)
    }

    @Test func listKeepsCuesSortedAndUnique() {
        var list = CueList(cues: [Cue(number: 5), Cue(number: 1)])
        #expect(list.cues.map(\.number) == [1, 5])
        list.insert(Cue(number: 3))
        list.insert(Cue(number: 5, name: "replaced"))
        #expect(list.cues.map(\.number) == [1, 3, 5])
        #expect(list.cues.last?.name == "replaced")
        #expect(list.index(ofNumber: 3) == 1)
        list.remove(id: list.cues[0].id)
        #expect(list.cues.count == 2)
    }

    @Test func timecodeTriggerComparesInSecondsAcrossRates() {
        let cue = Cue(number: 1, timecodeTrigger: Timecode(hours: 0, minutes: 0, seconds: 10, frames: 0, rate: .fps25))
        func tc30(_ s: Int, _ f: Int) -> Timecode { Timecode(hours: 0, minutes: 0, seconds: s, frames: f, rate: .fps30) }
        var engine = CueEngine(list: CueList(cues: [cue]))
        engine.timecode(tc30(9, 0), at: 0)
        engine.timecode(tc30(9, 29), at: 0.1)  // 9.97 s: a frame-count compare (250 vs 299) would fire here
        #expect(engine.current == nil)
        engine.timecode(tc30(10, 0), at: 0.2)
        #expect(engine.current?.number == 1)
    }

    @Test func listEditsKeepCurrentCueAndReleaseRemovedValues() {
        func cue(_ n: Double, _ raw: UInt16) -> Cue { Cue(number: n, values: [CueValue(fixture: .layer(1), parameter: .layer(.intensity), raw: raw)]) }
        var engine = CueEngine(list: CueList(cues: [cue(2, 100), cue(3, 200)]))
        engine.go(at: 0)
        #expect(engine.current?.number == 2)
        var edited = engine.list
        edited.insert(cue(1, 50))  // before the current cue
        engine.replace(list: edited)
        #expect(engine.current?.number == 2)
        engine.go(at: 1)
        #expect(engine.current?.number == 3, "GO fires the cue after the current one, not the one now at the old index")
        var removed = engine.list
        removed.remove(id: engine.current!.id)
        engine.replace(list: removed)
        #expect(engine.tick(at: 2).isEmpty, "values of the removed cue are released")
        #expect(engine.current?.number == 2)
    }

    // MARK: B284 resume

    static func value(_ layer: Int, _ raw: UInt16) -> CueValue { CueValue(fixture: .layer(layer), parameter: .layer(.intensity), raw: raw) }
    static func tc(_ s: Int, _ f: Int = 0) -> Timecode { Timecode(hours: 0, minutes: 0, seconds: s, frames: f, rate: .fps25) }
    /// 1 brings Layer 1 up, 2 Layer 2 (timecode 10 s), 3 takes Layer 1 down and brings Layer 3 up, 4 takes Layer 2 out.
    static let show = CueList(cues: [
        Cue(number: 1, fadeTime: 2, values: [value(1, 65535)]),
        Cue(number: 2, fadeTime: 1, values: [value(2, 30000)], timecodeTrigger: tc(10)),
        Cue(number: 3, fadeTime: 3, values: [value(1, 20000), value(3, 40000)]),
        Cue(number: 4, fadeTime: 0, values: [value(2, 0)]),
    ])

    /// An engine started again from what `before` would have written: its targets and current cue.
    static func restarted(_ before: CueEngine, list: CueList? = nil, targets: [UUID: [CueValue]]? = nil) -> CueEngine {
        var after = CueEngine(list: list ?? before.list)
        after.resume(current: before.current?.id, number: before.current?.number, targets: targets ?? before.targets)
        return after
    }

    /// The operator's sequences: the resumed engine holds at once exactly what the old one holds once its fades end, is on
    /// the same cue, fades nothing, and its GO and Back go where the old one's go.
    @Test(arguments: [
        ("GO GO GO", [("go", 0), ("go", 5), ("go", 10)]),
        ("GO, Go to 3", [("go", 0), ("goto 3", 5)]),
        ("GO GO GO Back", [("go", 0), ("go", 5), ("go", 10), ("back", 20)]),
        ("Go to 3 while cue 2 fades", [("go", 0), ("go", 5), ("goto 3", 5.5)]),
    ] as [(String, [(String, Double)])])
    func resumeIsExact(_ name: String, _ steps: [(String, Double)]) {
        var before = CueEngine(list: Self.show)
        for (step, at) in steps {
            switch step {
            case "go": before.go(at: at)
            case "back": before.back(at: at)
            default: before.goto(number: 3, at: at)
            }
        }
        var after = Self.restarted(before)
        #expect(after.current?.id == before.current?.id, "\(name)")
        #expect(!after.isFading && !after.hasPendingFollow, "\(name)")
        #expect(after.tick(at: 0) == before.tick(at: 100), "\(name): the held values")
        var (go1, go2) = (before, after)
        go1.go(at: 200)
        go2.go(at: 200)
        #expect(go2.current?.id == go1.current?.id && go2.tick(at: 300) == go1.tick(at: 300), "\(name): the next GO")
        var (back1, back2) = (before, after)
        back1.back(at: 200)
        back2.back(at: 200)
        #expect(back2.current?.id == back1.current?.id && back2.tick(at: 300) == back1.tick(at: 300), "\(name): Back")
    }

    /// On the last cue GO does nothing and Back fires cue 3; a cue edited after it fired comes back as it was on stage,
    /// not as edited.
    @Test func resumeOnTheLastCueAndAfterAnEdit() {
        var before = CueEngine(list: Self.show)
        for at in [0.0, 5, 10, 15] { before.go(at: at) }
        var edited = Self.show
        edited.insert(Cue(id: Self.show.cues[1].id, number: 2, fadeTime: 1, values: [Self.value(2, 1000)]))
        before.replace(list: edited)
        var after = Self.restarted(before)
        #expect(after.current?.number == 4 && after.tick(at: 0) == before.tick(at: 100))
        after.go(at: 200)
        #expect(after.current?.number == 4)
        before.back(at: 200)
        after.back(at: 200)
        #expect(after.current?.number == 3 && after.tick(at: 300) == before.tick(at: 300))
    }

    /// A cue removed from the list: what it held is dropped, as `replace(list:)` releases it; a current cue that is
    /// gone resumes on the nearest earlier cue by number, where the list edit's fallback lands too.
    @Test func resumeDropsWhatARemovedCueHeld() {
        var before = CueEngine(list: Self.show)
        for at in [0.0, 5, 10] { before.go(at: at) }
        let targets = before.targets
        var without = Self.show
        without.remove(id: Self.show.cues[1].id)
        before.replace(list: without)
        var after = Self.restarted(before, list: without, targets: targets)
        #expect(after.tick(at: 0) == before.tick(at: 100) && after.current?.number == 3)
        without.remove(id: Self.show.cues[2].id)
        var gone = CueEngine(list: without)
        gone.resume(current: Self.show.cues[2].id, number: 3, targets: targets)
        before.replace(list: without)
        #expect(gone.current?.number == 1 && gone.current?.id == before.current?.id)
        #expect(gone.tick(at: 0) == before.tick(at: 100), "cue 3 held Layer 1 last: released, as a list edit does")
        var none = CueEngine(list: without)
        none.resume(current: UUID(), number: 0.5, targets: [:])
        #expect(none.current == nil, "nothing numbered before it")
    }

    /// GO to cue 5, a crash, and the restart loads an older project version without cue 5 (PR #399's fallback when
    /// `project.json` is unreadable): the list is on cue 4, not on none, and GO fires cue 6, not cue 1.
    @Test func resumeOnAnOlderVersionWithoutTheCurrentCue() {
        let cues = (1...6).map { Cue(number: Double($0), values: [Self.value($0, 1000)]) }
        var before = CueEngine(list: CueList(cues: cues))
        for at in 0..<5 { before.go(at: Double(at)) }
        #expect(before.current?.number == 5)
        var older = CueList(cues: cues)
        older.remove(id: cues[4].id)
        var after = Self.restarted(before, list: older)
        #expect(after.current?.number == 4)
        #expect(after.tick(at: 0) == (1...4).map { Self.value($0, 1000) }, "cue 5's value left with it")
        after.go(at: 10)
        #expect(after.current?.number == 6)
    }

    /// A stored raw beyond its parameter's range (a hand edit; the file holds 0–65535) is clamped as a fire would.
    @Test func resumeClampsARawBeyondTheRange() {
        let mode = ChannelMap.spec(.layer(.playMode))
        #expect(mode.clamped(65535) < 65535)
        var engine = CueEngine(list: Self.show)
        engine.resume(current: nil, number: nil, targets: [Self.show.cues[0].id: [CueValue(fixture: .layer(1), parameter: .layer(.playMode), raw: 65535)]])
        #expect(engine.tick(at: 0) == [CueValue(fixture: .layer(1), parameter: .layer(.playMode), raw: mode.clamped(65535))])
    }

    /// The engine `resume` lands in need not be fresh: whatever it held, fades and follows is gone, and timecode is unarmed,
    /// so a first frame at or past a trigger that fell while the engine was down fires nothing.
    @Test func resumeClearsThePastAndFiresNoPassedTrigger() {
        var before = CueEngine(list: Self.show)
        for at in [0.0, 5, 10] { before.go(at: at) }
        var list = Self.show
        list.insert(Cue(id: Self.show.cues[0].id, number: 1, fadeTime: 2, values: [Self.value(1, 65535)], followTime: 1))
        var after = CueEngine(list: list)
        after.go(at: 0)  // cue 1 fading, its follow pending
        after.timecode(Self.tc(9, 20), at: 0)  // timecode armed just before cue 2's trigger
        after.resume(current: before.current?.id, number: before.current?.number, targets: before.targets)
        #expect(!after.isFading && !after.hasPendingFollow)
        #expect(after.tick(at: 0) == before.tick(at: 100))
        after.timecode(Self.tc(10), at: 1)  // the trigger frame itself
        after.timecode(Self.tc(10, 1), at: 2)
        #expect(after.current?.number == 3, "the trigger at 10 s fired after the resume")
        _ = after.tick(at: 100)
        #expect(after.current?.number == 3, "a follow fired after the resume")
    }
}
