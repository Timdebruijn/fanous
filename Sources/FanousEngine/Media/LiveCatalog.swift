// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import Synchronization

/// Numbered live inputs of folder 0 (B61, B73): the Syphon servers of other apps (files 150–169) and, to come, capture
/// devices (1–20), displays (21–28) and windows (29–32), numbered as they appear (the lowest free number), so a console
/// or the UI selects one like a generator. One that goes keeps its number (not running); one that comes back with the
/// same identity takes its old number again. The numbering is kept in the project (`/syphon`, B69, or the kind's
/// `projectKey`): the catalog starts from it, so numbers survive an engine restart. `syphon.forget` frees a number;
/// undo, redo and loading a version also drop the not-running numbers the restored project lacks.
/// Safe on any thread, except `start`/`stop` (one control thread).
public final class LiveCatalog: @unchecked Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case syphon, capture, screens, windows

        public var files: ClosedRange<Int> {
            switch self {
            case .capture: 1...20
            case .screens: 21...28
            case .windows: 29...32
            case .syphon: 150...169
            }
        }
        /// The project's key: `/syphon` `{"151": {app, server}}`, `/capture` `{"3": {uid, name}}`, `/screens`
        /// `{"21": {uuid, name}}`, `/windows` `{"29": {app, title}}`.
        public var projectKey: String { rawValue }
        /// An entry's `source` and `name` as the project names them.
        public var fields: (source: String, name: String) {
            switch self {
            case .syphon: ("app", "server")
            case .capture: ("uid", "name")
            case .screens: ("uuid", "name")
            case .windows: ("app", "title")
            }
        }
        /// Whether the name is part of the identity (a Syphon server's name, a window's title) or only what a device or
        /// a display is called (its uid or uuid alone names it, and a rename keeps the number).
        var nameIsIdentity: Bool { self == .syphon || self == .windows }
        /// In messages: "Syphon number 151", "Syphon server App/Server".
        var title: String {
            switch self {
            case .syphon: "Syphon"
            case .capture: "Capture"
            case .screens: "Screen"
            case .windows: "Window"
            }
        }
        var noun: String {
            switch self {
            case .syphon: "Syphon server"
            case .capture: "Capture device"
            case .screens: "Display"
            case .windows: "Window"
            }
        }
    }

    /// Syphon's `SyphonServerAnnounceRequest` (SyphonPrivate.h): every server answers, and every directory retires the
    /// servers that did not answer within 6 s, so a crashed app's server does not stay listed as running.
    static let announceRequest = Notification.Name("info.v002.Syphon.ServerAnnounceRequest")
    static let announceInterval = 5.0

    public struct Entry: Sendable, Equatable {
        public let kind: Kind
        public let file: Int
        /// Syphon's app, a capture device's uid, a display's uuid, a window's app.
        public var source: String
        /// Syphon's server name, a device's or display's name, a window's title.
        public var name: String
        /// The source's id while it runs (Syphon's directory id); nil once it has gone.
        public var runtimeID: String?
        /// From the project and not seen since the engine started (B69).
        public var gone = false
        public var running: Bool { runtimeID != nil }
        /// "App/Server", or "App" when the server has no name; a device's or display's name.
        public var label: String { name.isEmpty ? source : kind.nameIsIdentity ? "\(source)/\(name)" : name }
        /// The same source by its persistent identity.
        func same(_ other: Entry) -> Bool { source == other.source && (!kind.nameIsIdentity || name == other.name) }
    }

    private struct State {
        var entries: [Entry] = []
        /// The sources' list as last applied, so a number freed by `adopt` goes to a source waiting for one.
        var running: [Entry] = []
    }
    public let kind: Kind
    private let state = Mutex(State())
    /// This engine's own canvas server, never offered as an input.
    private let excluded: String?
    // start/stop only: they hold the directory observation and the announce timer alive
    private var watcher: SyphonInput?
    private var timer: DispatchSourceTimer?
    /// Runs after every change of numbers, names or running state (any thread); set before `start`.
    public var onChange: (@Sendable () -> Void)?

    /// `numbers`: the project's numbering (B69), taken as gone until they are seen.
    public init(_ kind: Kind, excluding runtimeID: String? = nil, numbers: [Entry] = []) {
        self.kind = kind
        excluded = runtimeID
        _ = adopt(numbers)
    }

    public var entries: [Entry] { state.withLock { $0.entries } }
    /// Running sources past the range, by label: they get a number when a forget frees one.
    public var unnumbered: [String] {
        state.withLock { s in
            s.running.filter { info in info.runtimeID?.isEmpty == false && !s.entries.contains { $0.runtimeID == info.runtimeID } }.map(\.label)
        }
    }
    public func entry(file: Int) -> Entry? { state.withLock { $0.entries.first { $0.file == file } } }

    /// Syphon: follows the directory from now on, and asks every server to announce itself every 5 s while one is
    /// listed as running, so one whose app crashed (no retire notification) is retired within about 11 s.
    public func start(device: MTLDevice) {
        precondition(kind == .syphon, "only Syphon's directory is followed")
        watcher = SyphonInput(device: device) { [weak self] in self?.update() }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.announceInterval, repeating: Self.announceInterval)
        timer.setEventHandler { [weak self] in
            guard self?.entries.contains(where: { $0.running }) == true else { return }
            DistributedNotificationCenter.default().postNotificationName(Self.announceRequest, object: nil, userInfo: nil, deliverImmediately: true)
        }
        timer.resume()
        self.timer = timer
        update()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        watcher = nil
    }

    /// Applies `running` (in the order they appeared, `file` unused), or Syphon's current directory when nil. The
    /// directory is read under the lock, so two notifications racing on different threads never apply an older list
    /// last (the directory does not call out while it holds its own lock, so this cannot deadlock).
    public func update(running: [Entry]? = nil) {
        let changed = state.withLock { s in
            s.running = (running ?? (kind == .syphon ? Self.syphonDirectory : s.running)).filter { $0.runtimeID != excluded }
            return Self.assign(&s.entries, running: s.running)
        }
        if changed { onChange?() }
    }

    static var syphonDirectory: [Entry] {
        SyphonInput.directoryServers.map { Entry(kind: .syphon, file: 0, source: $0.appName, name: $0.serverName, runtimeID: $0.uuid) }
    }

    /// Applies the project's numbering (start, a forget, undo, a loaded project); true when anything changed.
    @discardableResult public func adopt(_ numbers: [Entry]) -> Bool {
        let changed = state.withLock { s in
            let adopted = Self.adopt(&s.entries, numbers: numbers)
            return Self.assign(&s.entries, running: s.running) || adopted
        }
        if changed { onChange?() }
        return changed
    }

    /// An entry not running that `numbers` lists is kept or added (gone until it is seen); one it does not list is
    /// forgotten. A running entry always keeps its number: a project entry on its number is dropped, and so is a new
    /// entry with a running source's identity on another number (undo, a loaded version), or that source would move to
    /// the lower of the two at the next restart. The engine then writes the catalog back into the project.
    static func adopt(_ entries: inout [Entry], numbers: [Entry]) -> Bool {
        let before = entries
        let running = entries.filter(\.running)
        var next = running
        for entry in numbers where entry.kind.files.contains(entry.file) && !next.contains(where: { $0.file == entry.file }) {
            if let kept = entries.first(where: { $0.file == entry.file && !$0.running && $0.same(entry) }) {
                next.append(kept)  // also a gone twin of a running server (two engines' canvases share a name)
            } else if !running.contains(where: { $0.same(entry) }) {
                next.append(Entry(kind: entry.kind, file: entry.file, source: entry.source, name: entry.name, gone: true))
            }
        }
        entries = next.sorted { $0.file < $1.file }
        return entries != before
    }

    /// The numbering rules; true when anything changed.
    static func assign(_ entries: inout [Entry], running: [Entry]) -> Bool {
        let before = entries
        let alive = Set(running.compactMap(\.runtimeID))
        for i in entries.indices where entries[i].runtimeID.map({ !alive.contains($0) }) ?? false { entries[i].runtimeID = nil }
        for info in running {
            guard let id = info.runtimeID, !id.isEmpty else { continue }
            if let i = entries.firstIndex(where: { $0.runtimeID == id }) {
                entries[i].source = info.source  // a rename (SyphonServerUpdate) keeps the number
                entries[i].name = info.name
            } else if let i = entries.firstIndex(where: { $0.runtimeID == nil && $0.same(info) }) {
                entries[i].runtimeID = id
                entries[i].name = info.name  // a device renamed while gone (Syphon's name is its identity: unchanged)
                entries[i].gone = false
            } else if let file = info.kind.files.first(where: { file in !entries.contains { $0.file == file } }) {
                entries.append(Entry(kind: info.kind, file: file, source: info.source, name: info.name, runtimeID: id))
                entries.sort { $0.file < $1.file }
            }
            // past the range a new source gets none (`unnumbered`) until a forget frees one
        }
        return entries != before
    }
}
