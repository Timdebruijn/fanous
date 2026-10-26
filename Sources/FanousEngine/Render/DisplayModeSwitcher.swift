// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import FanousCore
import Logging

/// Applies the outputs' desired display modes in show mode and restores the previous ones (DESIGN.md §9.6).
/// Choosing the mode is `DisplayModeMatching.best`; this type only talks to CoreGraphics.
@MainActor
final class DisplayModeSwitcher {
    private struct Saved {
        var modeID: Int32
        var descriptor: DisplayModeDescriptor
    }

    private let logger: Logger
    /// Display UUID → its mode before the first switch.
    private var previous: [String: Saved] = [:]
    /// Display UUID → the mode last asked for: a display is switched again only when that changes or it was replugged,
    /// so a display that refuses a mode does not loop through reconfigurations.
    private var requested: [String: DisplayModeConfig] = [:]

    init(logger: Logger) { self.logger = logger }

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
        guard configure(changes.map { ($0.display.id, $0.to) }) else {
            logger.error("display modes not applied", metadata: ["displays": "\(changes.map(\.display.name))"])
            return false
        }
        for change in changes {
            if previous[change.display.uuid] == nil {
                previous[change.display.uuid] = Saved(
                    modeID: change.from.ioDisplayModeID, descriptor: Self.descriptor(change.from))
            }
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

    /// Show mode off or engine stop: back to the modes the displays had. A display that is gone is skipped.
    func restore(connected: [DisplayInfo]) {
        defer {
            previous.removeAll()
            requested.removeAll()
        }
        var changes: [(CGDirectDisplayID, CGDisplayMode)] = []
        for (uuid, saved) in previous {
            guard let display = connected.first(where: { $0.uuid == uuid }) else { continue }
            let list = Self.modes(display.id)
            let index =
                list.firstIndex { $0.ioDisplayModeID == saved.modeID && Self.descriptor($0) == saved.descriptor }
                ?? DisplayModeMatching.best(
                    for: saved.descriptor.config, in: list.map(Self.descriptor), preferHiDPI: saved.descriptor.isHiDPI)
            guard let index else { continue }
            changes.append((display.id, list[index]))
            logger.warning(
                "display mode restored",
                metadata: [
                    "display": "\(display.name)", "mode": "\(DisplayModeMatching.text(saved.descriptor.config))",
                ])
        }
        if !changes.isEmpty, !configure(changes) { logger.error("display modes not restored") }
    }

    /// One `CGBeginDisplayConfiguration` transaction, for the login session: a crash leaves the mode until logout.
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
