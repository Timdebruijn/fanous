// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import FanousCore
import Foundation
import Logging
import Synchronization
import Testing

@testable import FanousEngine

/// The switcher's ordering and bookkeeping against a fake CoreGraphics; no display is ever switched.
struct DisplayModeSwitcherTests {
    typealias Saved = DisplayModeLedger.Saved
    static func mode(_ id: Int32, _ hz: Double) -> Saved {
        Saved(
            modeID: id,
            descriptor: DisplayModeDescriptor(width: 3024, height: 1964, pointWidth: 1512, pointHeight: 982, hz: hz))
    }
    static let m120 = mode(54, 120), m60 = mode(55, 60), m48 = mode(56, 48)
    static let display = DisplayInfo(
        id: 1, uuid: "A", name: "Built-in", pixelWidth: 3024, pixelHeight: 1964, scale: 2, hz: 120, isMain: true,
        isBuiltin: true, modes: [])

    final class FakeBackend: DisplayModeBackend, @unchecked Sendable {
        struct State {
            var current = DisplayModeSwitcherTests.m120
            var locked = false
            var fail: String?
            var calls: [[Int32]] = []
            var blockNext = false
        }
        let state = Mutex(State())
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)

        func current(_ display: CGDirectDisplayID) -> Saved? { state.withLock { $0.current } }
        func modes(_ display: CGDirectDisplayID) -> [Saved] { [m120, m60, m48] }
        var screenLocked: Bool { state.withLock { $0.locked } }
        func configure(_ changes: [(CGDirectDisplayID, Saved)]) -> String? {
            let block = state.withLock { s in
                defer { s.blockNext = false }
                return s.blockNext
            }
            if block {  // a CG call that hangs, like the one on a locked screen
                entered.signal()
                gate.wait()
            }
            return state.withLock { s in
                s.calls.append(changes.map(\.1.modeID))
                if let fail = s.fail { return fail }
                s.current = changes[0].1
                return nil
            }
        }
    }

    static func make() -> (DisplayModeSwitcher, FakeBackend, URL) {
        let backend = FakeBackend()
        let url = FileManager.default.temporaryDirectory.appending(
            path: "fanous-switcher-\(UUID().uuidString)/display-modes.json")
        return (DisplayModeSwitcher(logger: Logger(label: "test"), backend: backend, ledgerURL: url), backend, url)
    }

    @Test func leavingSupersedesAPendingApplyAndUndoesTheOneInFlight() {
        let (switcher, backend, url) = Self.make()
        backend.state.withLock { $0.blockNext = true }
        switcher.apply([(Self.display, Self.m60.descriptor.config)], connected: [Self.display])
        backend.entered.wait()  // the apply is stuck in CG
        #expect(FileManager.default.fileExists(atPath: url.path))  // the pre-show mode is on disk before the switch
        switcher.apply([(Self.display, Self.m48.descriptor.config)], connected: [Self.display])  // e.g. an output edit
        switcher.restore(connected: [Self.display])  // show mode left
        backend.gate.signal()
        switcher.flush()
        let state = backend.state.withLock { $0 }
        #expect(state.calls == [[55], [54]])  // 48 Hz never applied; 120 Hz back after the stuck 60 Hz
        #expect(state.current == Self.m120)
        #expect(switcher.ledgerSnapshot.previous.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func lockedScreenWaitsAndTouchesNothing() {
        let (switcher, backend, url) = Self.make()
        backend.state.withLock { $0.locked = true }
        switcher.apply([(Self.display, Self.m60.descriptor.config)], connected: [Self.display])
        switcher.flush()
        #expect(backend.state.withLock { $0.calls }.isEmpty)
        #expect(switcher.failures == ["A": DisplayModeSwitcher.lockedReason])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // unlock: the engine syncs again
        backend.state.withLock { $0.locked = false }
        switcher.apply([(Self.display, Self.m60.descriptor.config)], connected: [Self.display])
        switcher.flush()
        #expect(backend.state.withLock { $0.current } == Self.m60 && switcher.failures.isEmpty)
        #expect(switcher.ledgerSnapshot.previous == ["A": Self.m120])
        switcher.restore(connected: [Self.display])
        switcher.flush()
        #expect(backend.state.withLock { $0.current } == Self.m120)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func failedSwitchReportsTheReasonAndClearsTheLedger() {
        let (switcher, backend, url) = Self.make()
        let reason = "CGCompleteDisplayConfiguration: cannot complete (1004)"
        backend.state.withLock { $0.fail = reason }
        switcher.apply([(Self.display, Self.m60.descriptor.config)], connected: [Self.display])
        switcher.flush()
        #expect(switcher.failures == ["A": reason])
        #expect(switcher.ledgerSnapshot.previous.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // not marked as requested: the next sync tries again
        backend.state.withLock { $0.fail = nil }
        switcher.apply([(Self.display, Self.m60.descriptor.config)], connected: [Self.display])
        switcher.flush()
        #expect(backend.state.withLock { $0.current } == Self.m60)
    }

    @Test func aLedgerFromACrashedRunIsRestoredOnStart() throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "fanous-switcher-\(UUID().uuidString)/display-modes.json")
        var ledger = DisplayModeLedger()
        ledger.record("A", Self.m120)
        try ledger.save(to: url)
        let backend = FakeBackend()
        backend.state.withLock { $0.current = Self.m60 }  // the show mode the crash left behind
        let switcher = DisplayModeSwitcher(logger: Logger(label: "test"), backend: backend, ledgerURL: url)
        switcher.restore(connected: [])  // display not there yet: entry kept
        switcher.flush()
        #expect(FileManager.default.fileExists(atPath: url.path))
        switcher.restore(connected: [Self.display])  // re-plug
        switcher.flush()
        #expect(backend.state.withLock { $0.current } == Self.m120)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Show mode resumed after a crash: the engine applies (not restores), the display is already in its show mode,
    /// so nothing is switched and the ledger stays for the restore when show mode is left.
    @Test func resumedShowModeKeepsTheLedgerAndSwitchesNothing() throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "fanous-switcher-\(UUID().uuidString)/display-modes.json")
        var ledger = DisplayModeLedger()
        ledger.record("A", Self.m120)
        try ledger.save(to: url)
        let backend = FakeBackend()
        backend.state.withLock { $0.current = Self.m60 }
        let switcher = DisplayModeSwitcher(logger: Logger(label: "test"), backend: backend, ledgerURL: url)
        for _ in 0..<2 {  // first sync, then a rebind's sync
            switcher.apply([(Self.display, Self.m60.descriptor.config)], connected: [Self.display])
        }
        switcher.flush()
        #expect(backend.state.withLock { $0.calls }.isEmpty)  // no restore-then-reapply flip-flop
        #expect(switcher.ledgerSnapshot.previous == ["A": Self.m120])
        #expect(FileManager.default.fileExists(atPath: url.path))
        switcher.restore(connected: [Self.display])  // show mode left later
        switcher.flush()
        #expect(backend.state.withLock { $0.calls } == [[54]])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
