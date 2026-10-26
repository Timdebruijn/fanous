// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousCore

struct DisplayModeMatchingTests {
    static func mode(_ w: Int, _ h: Int, _ hz: Double, points: Int? = nil, usable: Bool = true) -> DisplayModeDescriptor
    {
        let pw = points ?? w
        return DisplayModeDescriptor(
            width: w, height: h, pointWidth: pw, pointHeight: h * pw / w, hz: hz, usable: usable)
    }

    @Test func prefersTheExactRateThenItsNTSCNeighbour() {
        let list = [
            Self.mode(1920, 1080, 59.94), Self.mode(1920, 1080, 60), Self.mode(1920, 1080, 50),
            Self.mode(1280, 720, 60),
        ]
        #expect(DisplayModeMatching.best(for: DisplayModeConfig(width: 1920, height: 1080, hz: 60), in: list) == 1)
        #expect(DisplayModeMatching.best(for: DisplayModeConfig(width: 1920, height: 1080, hz: 59.94), in: list) == 0)
        // only 59.94 listed: 60 still matches it
        #expect(
            DisplayModeMatching.best(for: DisplayModeConfig(width: 1920, height: 1080, hz: 60), in: [list[0], list[2]])
                == 0)
        #expect(DisplayModeMatching.best(for: DisplayModeConfig(width: 1920, height: 1080, hz: 30), in: list) == nil)
        #expect(DisplayModeMatching.best(for: DisplayModeConfig(width: 3840, height: 2160, hz: 60), in: list) == nil)
    }

    @Test func matchesPixelsAndKeepsTheCurrentScale() {
        // 3840×2160 pixels: native 1× and the 1920×1080-point HiDPI mode, plus a mode not usable for the desktop
        let list = [
            Self.mode(3840, 2160, 60, usable: false), Self.mode(3840, 2160, 60, points: 1920),
            Self.mode(3840, 2160, 60), Self.mode(1920, 1080, 60),
        ]
        let uhd = DisplayModeConfig(width: 3840, height: 2160, hz: 60)
        #expect(DisplayModeMatching.best(for: uhd, in: list, preferHiDPI: false) == 2)
        #expect(DisplayModeMatching.best(for: uhd, in: list, preferHiDPI: true) == 1)
        // a 1920×1080 output means pixels, not the HiDPI mode's points
        #expect(DisplayModeMatching.best(for: DisplayModeConfig(width: 1920, height: 1080, hz: 60), in: list) == 3)
    }

    @Test func refreshMustBeAWholeMultipleOfTheCanvas() {
        #expect(DisplayModeMatching.refreshFits(60, fps: 60))
        #expect(DisplayModeMatching.refreshFits(59.94, fps: 60))
        #expect(DisplayModeMatching.refreshFits(120, fps: 60))
        #expect(DisplayModeMatching.refreshFits(50, fps: 25))
        #expect(!DisplayModeMatching.refreshFits(50, fps: 60))
        #expect(!DisplayModeMatching.refreshFits(30, fps: 60))
        #expect(!DisplayModeMatching.refreshFits(75, fps: 60))
    }

    @Test func checkTextsForTheStatusLineAndReadiness() {
        let current = DisplayModeConfig(width: 1920, height: 1080, hz: 59.94)
        let available = [
            current, DisplayModeConfig(width: 1920, height: 1080, hz: 60),
            DisplayModeConfig(width: 3840, height: 2160, hz: 30),
        ]
        let want60 = DisplayModeConfig(width: 1920, height: 1080, hz: 60)
        // 59.94 and 60 count as the same rate: nothing to say
        #expect(
            DisplayModeMatching.check(desired: want60, current: current, available: available, showMode: false, fps: 60)
                == .init())
        #expect(
            DisplayModeMatching.check(desired: nil, current: current, available: available, showMode: true, fps: 60)
                == .init())

        let want50 = DisplayModeConfig(width: 1920, height: 1080, hz: 50)
        let outside = DisplayModeMatching.check(
            desired: want50, current: current, available: available + [want50], showMode: false, fps: 50)
        #expect(outside.note == "Mode differs: 1920 × 1080 @ 59.94, wanted @ 50. Applied in show mode.")
        #expect(outside.issue == nil)
        let inside = DisplayModeMatching.check(
            desired: want50, current: current, available: available + [want50], showMode: true, fps: 50)
        #expect(inside.issue == "Mode differs: 1920 × 1080 @ 59.94, wanted @ 50. Not applied: see the log.")

        let uhd60 = DisplayModeConfig(width: 3840, height: 2160, hz: 60)
        let missing = DisplayModeMatching.check(
            desired: uhd60, current: current, available: available, showMode: false, fps: 60)
        #expect(missing.note == "Mode 3840 × 2160 @ 60 is not available on this display; closest 3840 × 2160 @ 30.")
        #expect(missing.issue == missing.note)

        let judder = DisplayModeMatching.check(
            desired: want50, current: want50, available: [], showMode: false, fps: 60)
        #expect(judder.note == "50 Hz is not a multiple of the canvas 60 fps: motion judders.")
        #expect(judder.issue == judder.note)
    }

    @Test func unusableModesOnlyWhenNothingElseMatches() {
        let unusable = Self.mode(1920, 1080, 60, usable: false)
        let usable = Self.mode(1920, 1080, 59.94)
        let want = DisplayModeConfig(width: 1920, height: 1080, hz: 60)
        // a usable 59.94 beats an unusable exact 60
        #expect(DisplayModeMatching.best(for: want, in: [unusable, usable]) == 1)
        #expect(DisplayModeMatching.best(for: want, in: [unusable]) == 0)
        #expect(DisplayModeMatching.offered([unusable, usable]) == [usable])
        #expect(DisplayModeMatching.offered([unusable]) == [unusable])
    }

    @Test func firstOutputWithAModeWinsItsDisplay() {
        func output(_ id: Int, _ uuid: String?, _ mode: DisplayModeConfig?) -> OutputConfig {
            var o = OutputConfig(id: id)
            o.display = uuid.map { DisplayIdentity(uuid: $0, name: "D") }
            o.mode = mode
            return o
        }
        let hd60 = DisplayModeConfig(width: 1920, height: 1080, hz: 60)
        let outputs = [
            output(1, "A", nil), output(2, "A", hd60),
            output(3, "A", DisplayModeConfig(width: 1920, height: 1080, hz: 59.94)),
            output(4, "A", DisplayModeConfig(width: 1280, height: 720, hz: 60)), output(5, "B", hd60),
            output(6, nil, hd60),
        ]
        let resolved = DisplayModeMatching.resolve(outputs)
        #expect(resolved.wanted == ["A": hd60, "B": hd60])
        #expect(resolved.conflicts.mapValues(\.id) == [4: 2])  // 59.94 is the same rate, no conflict
        #expect(
            DisplayModeMatching.conflict(with: outputs[1]).issue
                == "Conflicts with Output 2 on the same display: its mode 1920 × 1080 @ 60 is used.")
    }

    @Test func ledgerKeepsThePreShowModeAndRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "fanous-ledger-\(UUID().uuidString)/display-modes.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(DisplayModeLedger.load(from: url) == DisplayModeLedger())  // no file: nothing to restore

        let original = DisplayModeLedger.Saved(modeID: 73, descriptor: Self.mode(3840, 2160, 60, points: 1920))
        let show = DisplayModeLedger.Saved(modeID: 12, descriptor: Self.mode(1920, 1080, 50))
        var ledger = DisplayModeLedger()
        ledger.record("A", original)
        try ledger.save(to: url)
        // after a crash the next run loads the file; re-applying must not overwrite the pre-show mode
        var reloaded = DisplayModeLedger.load(from: url)
        #expect(reloaded == ledger)
        reloaded.record("A", show)
        reloaded.record("B", show)
        #expect(reloaded.previous["A"] == original && reloaded.previous["B"] == show)

        // restored entries go; the file goes with the last one
        reloaded.previous["A"] = nil
        try reloaded.save(to: url)
        #expect(DisplayModeLedger.load(from: url).previous.keys.sorted() == ["B"])
        reloaded.previous["B"] = nil
        try reloaded.save(to: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
