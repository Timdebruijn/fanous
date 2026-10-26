// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import FanousCore
import Foundation
import Logging

/// Applies the outputs' desired display modes in show mode and restores the previous ones (DESIGN.md §9.6).
/// Choosing the mode is `DisplayModeMatching.best`; this type only talks to CoreGraphics.
@MainActor
final class DisplayModeSwitcher {
    private let logger: Logger
    /// Display UUID → its mode before the first switch, mirrored to `ledgerURL` (survives a crash or kill).
    private var ledger: DisplayModeLedger
    private let ledgerURL: URL?
    /// Display UUID → the mode last asked for: a display is switched again only when that changes or it was replugged,
    /// so a display that refuses a mode does not loop through reconfigurations.
    private var requested: [String: DisplayModeConfig] = [:]

    /// A ledger left by a crashed run is restored by the first `restore` (show mode is off at start).
    init(logger: Logger, ledgerURL: URL?) {
        self.logger = logger
        self.ledgerURL = ledgerURL
        ledger = ledgerURL.map(DisplayModeLedger.load(from:)) ?? DisplayModeLedger()
        if !ledger.previous.isEmpty {
            logger.warning(
                "display modes left switched by a previous run", metadata: ["displays": "\(ledger.previous.count)"])
        }
    }

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

    /// Show mode on: switch every display whose current mode differs, in one transaction. True when it switched.
    @discardableResult func apply(_ wanted: [(display: DisplayInfo, mode: DisplayModeConfig)], connected: [DisplayInfo])
        -> Bool
    {
        requested = requested.filter { uuid, _ in connected.contains { $0.uuid == uuid } }  // replugged → applied again
        var changes: [(display: DisplayInfo, to: CGDisplayMode, from: CGDisplayMode)] = []
        for (display, mode) in wanted where requested[display.uuid] != mode {
            requested[display.uuid] = mode
            guard let current = CGDisplayCopyDisplayMode(display.id) else { continue }
            let from = Self.descriptor(current)
            if DisplayModeMatching.same(from.config, mode) { continue }
            let list = Self.modes(display.id)
            guard
                let index = DisplayModeMatching.best(
                    for: mode, in: list.map(Self.descriptor), preferHiDPI: from.isHiDPI)
            else {
                logger.warning(
                    "display mode not available",
                    metadata: ["display": "\(display.name)", "wanted": "\(DisplayModeMatching.text(mode))"])
                continue
            }
            changes.append((display, list[index], current))
        }
        guard !changes.isEmpty else { return false }
        // on disk before the switch: a crash right after it still finds the mode to put back
        for change in changes {
            ledger.record(
                change.display.uuid,
                .init(modeID: change.from.ioDisplayModeID, descriptor: Self.descriptor(change.from)))
        }
        saveLedger()
        guard configure(changes.map { ($0.display.id, $0.to) }) else {
            logger.error("display modes not applied", metadata: ["displays": "\(changes.map(\.display.name))"])
            return false
        }
        for change in changes {
            logger.warning(
                "display mode applied",
                metadata: [
                    "display": "\(change.display.name)",
                    "from": "\(DisplayModeMatching.text(Self.descriptor(change.from).config))",
                    "to": "\(DisplayModeMatching.text(Self.descriptor(change.to).config))",
                ])
        }
        return true
    }

    /// Show mode off, engine stop or start after a crash: back to the modes the displays had. An entry stays in the
    /// ledger until its restore succeeded (display unplugged, no matching mode, failed transaction): the next call,
    /// after every rebind and so on re-plug, tries again.
    func restore(connected: [DisplayInfo]) {
        requested.removeAll()
        var changes: [(uuid: String, display: DisplayInfo, mode: CGDisplayMode)] = []
        for (uuid, saved) in ledger.previous {
            guard let display = connected.first(where: { $0.uuid == uuid }) else { continue }
            let list = Self.modes(display.id)
            let index =
                list.firstIndex { $0.ioDisplayModeID == saved.modeID && Self.descriptor($0) == saved.descriptor }
                ?? DisplayModeMatching.best(
                    for: saved.descriptor.config, in: list.map(Self.descriptor), preferHiDPI: saved.descriptor.isHiDPI)
            guard let index else { continue }
            changes.append((uuid, display, list[index]))
        }
        guard !changes.isEmpty else { return }
        guard configure(changes.map { ($0.display.id, $0.mode) }) else {
            logger.error("display modes not restored", metadata: ["displays": "\(changes.map(\.display.name))"])
            return
        }
        for change in changes {
            logger.warning(
                "display mode restored",
                metadata: [
                    "display": "\(change.display.name)",
                    "mode": "\(DisplayModeMatching.text(Self.descriptor(change.mode).config))",
                ])
            ledger.previous[change.uuid] = nil
        }
        saveLedger()
    }

    private func saveLedger() {
        guard let ledgerURL else { return }
        do { try ledger.save(to: ledgerURL) } catch {
            logger.error("display mode ledger not saved", metadata: ["error": "\(error)"])
        }
    }

    /// One `CGBeginDisplayConfiguration` transaction for the login session; the ledger covers a crash in between.
    private func configure(_ changes: [(CGDirectDisplayID, CGDisplayMode)]) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for (display, mode) in changes where CGConfigureDisplayWithDisplayMode(config, display, mode, nil) != .success {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}
