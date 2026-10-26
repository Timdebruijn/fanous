// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import FanousCore
import Foundation
import Logging
import Synchronization

/// What the switcher needs from CoreGraphics; a fake in tests. A mode is its `ioDisplayModeID` plus descriptor.
protocol DisplayModeBackend: Sendable {
    func current(_ display: CGDirectDisplayID) -> DisplayModeLedger.Saved?
    func modes(_ display: CGDirectDisplayID) -> [DisplayModeLedger.Saved]
    /// One transaction; nil on success, else the failing step and its CGError.
    func configure(_ changes: [(CGDirectDisplayID, DisplayModeLedger.Saved)]) -> String?
    /// CG refuses (or stalls on) display configuration while the screen is locked or the session is not on console.
    var screenLocked: Bool { get }
}

/// Applies the outputs' desired display modes in show mode and restores the previous ones (DESIGN.md §9.6).
/// Choosing the mode is `DisplayModeMatching.best`. CG calls can block for seconds (a locked screen), so they run on
/// a serial queue: a restore queued behind an in-flight apply undoes it, and an apply still waiting when a restore
/// is requested (show mode left) never runs.
final class DisplayModeSwitcher: @unchecked Sendable {
    static let lockedReason = "screen locked: modes applied when unlocked"

    private let logger: Logger
    private let backend: DisplayModeBackend
    private let ledgerURL: URL?
    private let queue = DispatchQueue(label: "org.fanous.display-modes", qos: .userInitiated)
    /// Bumped by every restore request; an apply queued under an older value is superseded.
    private let generation = Mutex(0)
    /// Display UUID → why its mode was not applied; read by the engine for the status line and readiness.
    private let failureState = Mutex<[String: String]>([:])
    // queue only:
    /// Display UUID → its mode before the first switch, mirrored to `ledgerURL` (survives a crash or kill).
    private var ledger: DisplayModeLedger
    /// Display UUID → the mode last applied: switched again only when that changes or the display was replugged,
    /// so a display that ends up in another mode does not loop through reconfigurations.
    private var requested: [String: DisplayModeConfig] = [:]
    private var restoreLockedLogged = false
    /// After each apply or restore finished, on the switcher's queue.
    var onResult: (@Sendable () -> Void)?

    /// A ledger left by a crashed run is restored by the first `restore` (show mode is off at start).
    init(logger: Logger, backend: DisplayModeBackend = CGDisplayModeBackend(), ledgerURL: URL?) {
        self.logger = logger
        self.backend = backend
        self.ledgerURL = ledgerURL
        ledger = ledgerURL.map(DisplayModeLedger.load(from:)) ?? DisplayModeLedger()
        if !ledger.previous.isEmpty {
            logger.warning(
                "display modes left switched by a previous run", metadata: ["displays": "\(ledger.previous.count)"])
        }
    }

    var failures: [String: String] { failureState.withLock { $0 } }
    var ledgerSnapshot: DisplayModeLedger { queue.sync { ledger } }
    /// Waits for queued work (engine stop, tests).
    func flush() { queue.sync {} }

    /// Show mode on: switch every display whose current mode differs, in one transaction.
    func apply(_ wanted: [(display: DisplayInfo, mode: DisplayModeConfig)], connected: [DisplayInfo]) {
        let ticket = generation.withLock { $0 }
        queue.async { [self] in
            guard generation.withLock({ $0 }) == ticket else { return }  // show mode was left meanwhile
            applyNow(wanted, connected: connected)
            onResult?()
        }
    }

    /// Show mode off, engine stop, start after a crash, unlock: back to the modes the displays had. Supersedes
    /// every apply not started yet; runs after the one in flight.
    func restore(connected: [DisplayInfo]) {
        generation.withLock { $0 += 1 }
        queue.async { [self] in
            restoreNow(connected: connected)
            onResult?()
        }
    }

    private func applyNow(_ wanted: [(display: DisplayInfo, mode: DisplayModeConfig)], connected: [DisplayInfo]) {
        requested = requested.filter { uuid, _ in connected.contains { $0.uuid == uuid } }  // replugged → applied again
        var changes:
            [(
                display: DisplayInfo, mode: DisplayModeConfig, to: DisplayModeLedger.Saved,
                from: DisplayModeLedger.Saved
            )] = []
        var failed: [String: String] = [:]
        let locked = backend.screenLocked
        for (display, mode) in wanted where requested[display.uuid] != mode {
            guard let from = backend.current(display.id) else { continue }
            if DisplayModeMatching.same(from.descriptor.config, mode) {
                requested[display.uuid] = mode
                continue
            }
            let list = backend.modes(display.id)
            guard
                let index = DisplayModeMatching.best(
                    for: mode, in: list.map(\.descriptor), preferHiDPI: from.descriptor.isHiDPI)
            else {
                requested[display.uuid] = mode  // the status line names the closest mode; nothing to retry
                logger.warning(
                    "display mode not available",
                    metadata: ["display": "\(display.name)", "wanted": "\(DisplayModeMatching.text(mode))"])
                continue
            }
            if locked {
                failed[display.uuid] = Self.lockedReason
                continue
            }
            changes.append((display, mode, list[index], from))
        }
        defer { failureState.withLock { $0 = failed } }
        if !failed.isEmpty {
            logger.warning(
                "display modes wait for the screen to be unlocked", metadata: ["displays": "\(failed.count)"])
        }
        guard !changes.isEmpty else { return }
        // on disk before the switch: a crash during it still finds the mode to put back
        let added = changes.map(\.display.uuid).filter { ledger.previous[$0] == nil }
        for change in changes { ledger.record(change.display.uuid, change.from) }
        saveLedger()
        if let reason = backend.configure(changes.map { ($0.display.id, $0.to) }) {
            for uuid in added { ledger.previous[uuid] = nil }  // nothing changed: nothing to put back
            saveLedger()
            for change in changes { failed[change.display.uuid] = reason }
            logger.error(
                "display modes not applied",
                metadata: ["displays": "\(changes.map(\.display.name))", "reason": "\(reason)"])
            return
        }
        for change in changes {
            requested[change.display.uuid] = change.mode
            logger.warning(
                "display mode applied",
                metadata: [
                    "display": "\(change.display.name)",
                    "from": "\(DisplayModeMatching.text(change.from.descriptor.config))",
                    "to": "\(DisplayModeMatching.text(change.to.descriptor.config))",
                ])
        }
    }

    /// An entry stays in the ledger until its display is back in that mode (unplugged, no matching mode, locked or a
    /// failed transaction keep it); the next call, after every rebind, on re-plug and on unlock, tries again.
    private func restoreNow(connected: [DisplayInfo]) {
        requested.removeAll()
        failureState.withLock { $0.removeAll() }
        guard !ledger.previous.isEmpty else { return }
        var changes: [(uuid: String, display: DisplayInfo, mode: DisplayModeLedger.Saved)] = []
        var unchanged: [String] = []
        for (uuid, saved) in ledger.previous {
            guard let display = connected.first(where: { $0.uuid == uuid }) else { continue }
            if let current = backend.current(display.id), current.descriptor.config == saved.descriptor.config {
                unchanged.append(uuid)  // never switched, or already back
                continue
            }
            let list = backend.modes(display.id)
            let index =
                list.firstIndex(of: saved)
                ?? DisplayModeMatching.best(
                    for: saved.descriptor.config, in: list.map(\.descriptor), preferHiDPI: saved.descriptor.isHiDPI)
            guard let index else { continue }
            changes.append((uuid, display, list[index]))
        }
        for uuid in unchanged { ledger.previous[uuid] = nil }
        defer { saveLedger() }
        guard !changes.isEmpty else { return }
        if backend.screenLocked {
            if !restoreLockedLogged { logger.warning("display modes restored when the screen is unlocked") }
            restoreLockedLogged = true
            return
        }
        restoreLockedLogged = false
        if let reason = backend.configure(changes.map { ($0.display.id, $0.mode) }) {
            logger.error(
                "display modes not restored",
                metadata: ["displays": "\(changes.map(\.display.name))", "reason": "\(reason)"])
            return
        }
        for change in changes {
            logger.warning(
                "display mode restored",
                metadata: [
                    "display": "\(change.display.name)",
                    "mode": "\(DisplayModeMatching.text(change.mode.descriptor.config))",
                ])
            ledger.previous[change.uuid] = nil
        }
    }

    private func saveLedger() {
        guard let ledgerURL else { return }
        do { try ledger.save(to: ledgerURL) } catch {
            logger.error("display mode ledger not saved", metadata: ["error": "\(error)"])
        }
    }
}

/// The real thing: one `CGBeginDisplayConfiguration` transaction for the login session (the ledger covers a crash).
struct CGDisplayModeBackend: DisplayModeBackend {
    /// Every mode of a display, the HiDPI ones and their 1× duplicates included.
    static func modes(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        return CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
    }

    static func descriptor(_ mode: CGDisplayMode) -> DisplayModeDescriptor {
        // fixed-rate panels report 0 Hz; DisplayManager treats them as 60 too
        DisplayModeDescriptor(
            width: mode.pixelWidth, height: mode.pixelHeight, pointWidth: mode.width, pointHeight: mode.height,
            hz: mode.refreshRate > 0 ? mode.refreshRate : 60, usable: mode.isUsableForDesktopGUI())
    }

    static func saved(_ mode: CGDisplayMode) -> DisplayModeLedger.Saved {
        .init(modeID: mode.ioDisplayModeID, descriptor: descriptor(mode))
    }

    func current(_ display: CGDirectDisplayID) -> DisplayModeLedger.Saved? {
        CGDisplayCopyDisplayMode(display).map(Self.saved)
    }
    func modes(_ display: CGDirectDisplayID) -> [DisplayModeLedger.Saved] { Self.modes(display).map(Self.saved) }

    var screenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if session["CGSSessionScreenIsLocked"] as? Bool == true { return true }
        return session[kCGSessionOnConsoleKey as String] as? Bool == false
    }

    func configure(_ changes: [(CGDirectDisplayID, DisplayModeLedger.Saved)]) -> String? {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { return "CGBeginDisplayConfiguration: \(Self.name(begin))" }
        for (display, saved) in changes {
            guard let mode = Self.modes(display).first(where: { Self.saved($0) == saved }) else {
                CGCancelDisplayConfiguration(config)
                return "mode \(DisplayModeMatching.text(saved.descriptor.config)) no longer listed"
            }
            let result = CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
            if result != .success {
                CGCancelDisplayConfiguration(config)
                return "CGConfigureDisplayWithDisplayMode: \(Self.name(result))"
            }
        }
        let complete = CGCompleteDisplayConfiguration(config, .forSession)
        return complete == .success ? nil : "CGCompleteDisplayConfiguration: \(Self.name(complete))"
    }

    static func name(_ error: CGError) -> String {
        let names: [CGError: String] = [
            .failure: "failure", .illegalArgument: "illegal argument", .invalidConnection: "invalid connection",
            .invalidContext: "invalid context", .cannotComplete: "cannot complete", .notImplemented: "not implemented",
            .rangeCheck: "range check", .typeCheck: "type check", .invalidOperation: "invalid operation",
            .noneAvailable: "none available",
        ]
        return "\(names[error] ?? "CGError") (\(error.rawValue))"
    }
}
