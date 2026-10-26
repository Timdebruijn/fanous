// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// A display mode as CoreGraphics lists it, reduced to what matching needs (DESIGN.md §9.6).
public struct DisplayModeDescriptor: Codable, Equatable, Sendable {
    /// Framebuffer size in pixels.
    public var width: Int
    public var height: Int
    /// Desktop size in points; half the pixels for a HiDPI mode.
    public var pointWidth: Int
    public var pointHeight: Int
    public var hz: Double
    /// `CGDisplayModeIsUsableForDesktopGUI`
    public var usable: Bool

    public init(width: Int, height: Int, pointWidth: Int, pointHeight: Int, hz: Double, usable: Bool = true) {
        self.width = width
        self.height = height
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.hz = hz
        self.usable = usable
    }

    public var isHiDPI: Bool { pointWidth != width }
    public var config: DisplayModeConfig { DisplayModeConfig(width: width, height: height, hz: hz) }
}

/// Pure part of applying an output's desired mode in show mode (DESIGN.md §9.6, §14).
public enum DisplayModeMatching {
    /// 59.94 and 60 are the same rate to a projector: 0.15 % covers every 1000/1001 pair (23.976, 29.97, 59.94).
    public static func sameRate(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(a, b) * 0.0015 }

    public static func same(_ a: DisplayModeConfig, _ b: DisplayModeConfig) -> Bool {
        a.width == b.width && a.height == b.height && sameRate(a.hz, b.hz)
    }

    /// The mode to switch to: same pixel size and rate, usable for the desktop unless no usable one matches; the
    /// exact rate before its 1000/1001 neighbour, then the HiDPI-ness of the current mode (the drawable keeps its scale).
    public static func best(
        for desired: DisplayModeConfig, in modes: [DisplayModeDescriptor], preferHiDPI: Bool = false
    ) -> Int? {
        func rank(_ m: DisplayModeDescriptor) -> (Int, Int) {
            (abs(m.hz - desired.hz) < 0.01 ? 0 : 1, m.isHiDPI == preferHiDPI ? 0 : 1)
        }
        let matching = modes.indices.filter { same(modes[$0].config, desired) }
        let usable = matching.filter { modes[$0].usable }
        return (usable.isEmpty ? matching : usable).min { rank(modes[$0]) < rank(modes[$1]) }
    }

    /// The modes to offer: the ones usable for the desktop, or all of them when none is.
    public static func offered(_ modes: [DisplayModeDescriptor]) -> [DisplayModeDescriptor] {
        let usable = modes.filter(\.usable)
        return usable.isEmpty ? modes : usable
    }

    /// One mode per display: the first output (project order) with a mode on that display wins. Outputs on the same
    /// display that want another mode lose: loser id → winner.
    public static func resolve(_ outputs: [OutputConfig]) -> (
        wanted: [String: DisplayModeConfig], conflicts: [Int: OutputConfig]
    ) {
        var wanted: [String: DisplayModeConfig] = [:]
        var winners: [String: OutputConfig] = [:]
        var conflicts: [Int: OutputConfig] = [:]
        for output in outputs {
            guard let uuid = output.display?.uuid, let mode = output.mode else { continue }
            if let winner = winners[uuid] {
                if !same(mode, wanted[uuid]!) { conflicts[output.id] = winner }
            } else {
                winners[uuid] = output
                wanted[uuid] = mode
            }
        }
        return (wanted, conflicts)
    }

    /// The nearest mode by size, then refresh, for "not available; closest …".
    public static func closest(to desired: DisplayModeConfig, in modes: [DisplayModeConfig]) -> DisplayModeConfig? {
        modes.min { a, b in
            (abs(a.width - desired.width) + abs(a.height - desired.height), abs(a.hz - desired.hz))
                < (abs(b.width - desired.width) + abs(b.height - desired.height), abs(b.hz - desired.hz))
        }
    }

    /// A display rate that is a whole multiple of the canvas rate (60 for 60, 120 for 60, 59.94 for 60).
    public static func refreshFits(_ hz: Double, fps: Double) -> Bool {
        guard hz > 0, fps > 0 else { return true }
        let multiple = (hz / fps).rounded()
        return multiple >= 1 && sameRate(hz, multiple * fps)
    }

    /// "1920 × 1080 @ 59.94", like the web UI's `modeText`.
    public static func text(_ mode: DisplayModeConfig) -> String { "\(mode.width) × \(mode.height) @ \(rate(mode.hz))" }

    static func rate(_ hz: Double) -> String {
        let rounded = (hz * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    /// What the Outputs list and the readiness check say about one bound output.
    public struct Check: Equatable, Sendable {
        /// Yellow status line; nil = nothing to say.
        public var note: String?
        /// Readiness warning; nil = fine for the show (a mode that show mode will apply is not an issue).
        public var issue: String?
    }

    /// For an output that lost `resolve` to an earlier output on the same display.
    public static func conflict(with winner: OutputConfig) -> Check {
        let line = "Conflicts with \(winner.name) on the same display: its mode \(winner.mode.map(text) ?? "") is used."
        return Check(note: line, issue: line)
    }

    /// `available` is the display's mode list (empty = unknown, not checked); `failure` why show mode could not
    /// switch the display (CG error, locked screen).
    public static func check(
        desired: DisplayModeConfig?, current: DisplayModeConfig, available: [DisplayModeConfig], showMode: Bool,
        fps: Double, failure: String? = nil
    ) -> Check {
        guard let desired else { return Check() }
        var note: String?
        var issue: String?
        if !same(current, desired) {
            if !available.isEmpty, !available.contains(where: { same($0, desired) }) {
                let closest = closest(to: desired, in: available).map { "; closest \(text($0))" } ?? ""
                note = "Mode \(text(desired)) is not available on this display\(closest)."
                issue = note
            } else {
                let wanted =
                    current.width == desired.width && current.height == desired.height
                    ? "@ \(rate(desired.hz))" : text(desired)
                note =
                    "Mode differs: \(text(current)), wanted \(wanted)."
                    + (showMode
                        ? " Not applied: \(failure ?? "switching, or refused by the display")."
                        : " Applied in show mode.")
                if showMode { issue = note }
            }
        }
        if !refreshFits(desired.hz, fps: fps) {
            let warning = "\(rate(desired.hz)) Hz is not a multiple of the canvas \(rate(fps)) fps: motion judders."
            note = note.map { "\($0) \(warning)" } ?? warning
            issue = issue.map { "\($0) \(warning)" } ?? warning
        }
        return Check(note: note, issue: issue)
    }
}

/// The modes displays had before show mode switched them, by display UUID. Persisted while any is switched, so a
/// crash or kill does not make the show mode the "previous" one after the restart (DESIGN.md §9.6).
public struct DisplayModeLedger: Codable, Equatable, Sendable {
    public struct Saved: Codable, Equatable, Sendable {
        /// `CGDisplayModeGetIODisplayModeID`, tried first when restoring.
        public var modeID: Int32
        public var descriptor: DisplayModeDescriptor
        public init(modeID: Int32, descriptor: DisplayModeDescriptor) {
            self.modeID = modeID
            self.descriptor = descriptor
        }
    }

    public var previous: [String: Saved] = [:]
    public init() {}

    /// Only the first mode of a display counts: a later one is already a show mode.
    public mutating func record(_ uuid: String, _ saved: Saved) {
        if previous[uuid] == nil { previous[uuid] = saved }
    }

    public static func load(from url: URL) -> DisplayModeLedger {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? DisplayModeLedger()
    }

    /// Writes the ledger, or removes the file once nothing is left to restore.
    public func save(to url: URL) throws {
        if previous.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
