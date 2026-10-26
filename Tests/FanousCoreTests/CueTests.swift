// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

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
        #expect(half == [CueOutput(fixture: .layer(1), parameter: .layer(.intensity), raw: 32768)])
        #expect(engine.isFading)
        #expect(engine.tick(at: 1.0).first?.raw == 65535)
        #expect(!engine.isFading)
        engine.go(at: 2)
        let outputs = engine.tick(at: 2.0)
        #expect(outputs.contains(CueOutput(fixture: .layer(1), parameter: .layer(.playMode), raw: 17)))
        #expect(outputs.contains(CueOutput(fixture: .layer(1), parameter: .layer(.intensity), raw: 65535)))
        engine.back(at: 3)
        #expect(engine.current?.number == 1)
        engine.goto(number: 3, at: 4)
        #expect(engine.current?.number == 3)
        #expect(engine.tick(at: 4).contains(CueOutput(fixture: .master, parameter: .master(.intensity), raw: 0)))
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
}
