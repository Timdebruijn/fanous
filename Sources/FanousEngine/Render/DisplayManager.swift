// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import CoreGraphics
import Foundation
import FanousCore
import Logging

/// A connected display as the engine sees it (DESIGN.md §9.6).
public struct DisplayInfo: Sendable, Equatable {
    public var id: CGDirectDisplayID
    public var uuid: String
    public var name: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var hz: Double
    public var isMain: Bool
    public var isBuiltin: Bool
    public var modes: [DisplayModeConfig]

    public var identity: DisplayIdentity { DisplayIdentity(uuid: uuid, name: name) }
    public var mode: DisplayModeConfig { DisplayModeConfig(width: pixelWidth, height: pixelHeight, hz: hz) }
}

/// Enumerates displays by stable identity and reports reconfigurations (hot-plug, mode changes).
@MainActor
public final class DisplayManager {
    private let logger: Logger
    private var registered = false
    private var pending: DispatchWorkItem?
    /// Called on the main actor after the display set settled (300 ms after the last change).
    public var onChange: (@MainActor ([DisplayInfo]) -> Void)?

    public init(logger: Logger) { self.logger = logger }

    public static func current() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let screens = NSScreen.screens
        return ids.prefix(Int(count)).compactMap { id -> DisplayInfo? in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let mode = CGDisplayCopyDisplayMode(id)
            let screen = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            let modes = DisplayModeMatching.offered(DisplayModeSwitcher.modes(id).map(DisplayModeSwitcher.descriptor)).map(\.config)
            var unique: [DisplayModeConfig] = []
            for m in modes where !unique.contains(m) { unique.append(m) }
            let hz = mode?.refreshRate ?? 0
            return DisplayInfo(
                id: id, uuid: CFUUIDCreateString(nil, uuid) as String, name: screen?.localizedName ?? "Display \(id)",
                pixelWidth: mode?.pixelWidth ?? Int(CGDisplayPixelsWide(id)), pixelHeight: mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(id)),
                scale: Double(screen?.backingScaleFactor ?? 1), hz: hz > 0 ? hz : 60, isMain: CGDisplayIsMain(id) != 0,
                isBuiltin: CGDisplayIsBuiltin(id) != 0, modes: unique.sorted { ($0.width, $0.height, $0.hz) > ($1.width, $1.height, $1.hz) })
        }
    }

    public func start() {
        guard !registered else { return }
        registered = true
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, pointer)
    }

    public func stop() {
        guard registered else { return }
        registered = false
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Several callbacks arrive per event (begin/end per display); act once they stop coming.
    fileprivate func changed(flags: CGDisplayChangeSummaryFlags) {
        guard !flags.contains(.beginConfigurationFlag) else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let displays = Self.current()
            logger.info("displays changed", metadata: ["count": "\(displays.count)", "names": "\(displays.map(\.name))"])
            onChange?(displays)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
    MainActor.assumeIsolated { manager.changed(flags: flags) }
}
