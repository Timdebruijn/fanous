// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CryptoKit
import Foundation
import FanousCore
import Logging
import Synchronization

/// Project versions (DESIGN.md §11.5, B23): full project documents in `versions/` next to `project.json`, one file
/// per version, `<timestamp>-<name>.json`. A version is the project document plus a `snapshot` member (name, time,
/// automatic), so a version file still loads as a project. Automatic versions (engine start, show mode, every 10
/// minutes after a change, before a revert) keep the newest `keepAutomatic`; named versions never expire.
public final class ProjectVersions: Sendable {
    public static let keepAutomatic = 50
    /// Periodic snapshot interval; a snapshot is only written when the project differs from the newest version.
    public static let periodicInterval: TimeInterval = 600
    static let metaKey = "snapshot"

    public enum Reason: String, Sendable {
        case start = "Engine start"
        case showMode = "Show mode"
        case periodic = "Periodic"
        case manual = "Manual"
        case beforeRevert = "Before revert"
    }

    public struct Version: Sendable, Equatable {
        public var id: String
        /// Epoch seconds.
        public var at: Double
        public var name: String
        public var automatic: Bool
        public var layers: Int
        public var outputs: Int
        public var canvases: Int
        public var cues: Int

        init(id: String, at: Double, name: String, automatic: Bool, project: JSONValue) {
            self.id = id
            self.at = at
            self.name = name
            self.automatic = automatic
            layers = project["layerCount"]?.int ?? 0
            outputs = project["outputs"]?.array?.count ?? 0
            canvases = project["canvases"]?.array?.count ?? 0
            cues = project["cues"]?.array?.count ?? 0
        }

        var json: JSONValue {
            [
                "id": .string(id), "at": .number(at), "name": .string(name), "automatic": .bool(automatic),
                "layers": .number(Double(layers)), "outputs": .number(Double(outputs)), "canvases": .number(Double(canvases)), "cues": .number(Double(cues)),
            ]
        }
    }

    private struct State {
        var lastAt: Double = 0
        /// Bumped on every write or delete, so the UI knows to fetch the list again.
        var serial = 0
        /// Version metadata per file name: a version file is never rewritten, so each is parsed once.
        var cache: [String: Version] = [:]
        /// File names that did not load as a version (logged once).
        var unreadable: Set<String> = []
        var loaded = false
        /// Digest of the newest version's document, so "changed since the last version" reads no file.
        var newestID: String?
        var newestDigest: Data?
    }

    public let directory: URL
    private let logger: Logger
    /// Also serializes the file operations: the control queue (commands) and the versions queue (automatic) both write.
    private let state = Mutex(State())

    public init(directory: URL, logger: Logger) {
        self.directory = directory
        self.logger = logger
    }

    /// `live.versions`: when the newest automatic version was written and a change counter.
    public var live: JSONValue {
        state.withLock { s in
            let last = s.cache.values.filter(\.automatic).map(\.at).max()
            return ["lastAutomatic": last.map { .number($0) } ?? .null, "serial": .number(Double(s.serial))]
        }
    }

    // MARK: Files

    /// Newest first; files that do not load as a version are skipped (logged once per file).
    public func list() -> [Version] {
        state.withLock { listLocked(&$0) }
    }

    /// Writes a version of `project`. `automatic` ones beyond `keepAutomatic` are deleted, oldest first.
    @discardableResult
    public func save(_ project: JSONValue, name: String, automatic: Bool, now: Date = Date()) throws -> Version {
        try state.withLock { s in try saveLocked(project, name: name, automatic: automatic, now: now, &s) }
    }

    /// An automatic version, unless the project equals the newest version (show lock and version info aside).
    /// Errors are logged: an automatic snapshot never fails what triggered it.
    @discardableResult
    public func saveAutomatic(_ project: JSONValue, reason: Reason, now: Date = Date()) -> Version? {
        do {
            return try saveIfChanged(project, name: reason.rawValue, now: now)
        } catch {
            logger.error("automatic project version failed", metadata: ["reason": "\(reason.rawValue)", "error": "\(error)"])
            return nil
        }
    }

    /// An automatic version named `name`, nil when the project equals the newest version.
    func saveIfChanged(_ project: JSONValue, name: String, now: Date = Date()) throws -> Version? {
        try state.withLock { s in
            if let newest = listLocked(&s).first {
                if s.newestID != newest.id {
                    s.newestID = newest.id
                    s.newestDigest = (try? documentLocked(newest.id, &s)).flatMap(Self.digest)
                }
                if s.newestDigest != nil, s.newestDigest == Self.digest(project) { return nil }
            }
            return try saveLocked(project, name: name, automatic: true, now: now, &s)
        }
    }

    /// The project document of a version, without its `snapshot` member.
    public func document(id: String) throws -> JSONValue {
        try state.withLock { s in try documentLocked(id, &s) }
    }

    /// Deletes a named version; automatic ones expire by themselves.
    public func delete(id: String) throws {
        try state.withLock { s in
            guard let version = listLocked(&s).first(where: { $0.id == id }) else { throw Self.notFound(id) }
            guard !version.automatic else { throw CommandError.invalidArgs("automatic versions expire by themselves; only named versions can be deleted") }
            try FileManager.default.removeItem(at: url(id))
            s.cache[id] = nil
            s.serial += 1
        }
    }

    /// OSC `/fanous/project/load <name|id>`: the newest named version with that name (case-insensitive), else the
    /// version with that id.
    public func resolve(_ key: String) -> String? {
        let versions = list()
        return versions.first { !$0.automatic && $0.name.caseInsensitiveCompare(key) == .orderedSame }?.id ?? versions.first { $0.id == key }?.id
    }

    private func url(_ id: String) -> URL { directory.appending(path: id + ".json") }

    private static func notFound(_ id: String) -> CommandError { CommandError("notFound", "no project version \(id)") }

    /// What "the same project" means for skipping a snapshot or a revert: the show lock and the version info do not count.
    static func comparable(_ project: JSONValue) -> JSONValue {
        guard case .object(var o) = project else { return project }
        o[metaKey] = nil
        o["showLock"] = nil
        return .object(o)
    }

    static func digest(_ project: JSONValue) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(comparable(project))).map { Data(SHA256.hash(data: $0)) }
    }

    private func listLocked(_ s: inout State) -> [Version] {
        let names = Set(
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent })
        s.cache = s.cache.filter { names.contains($0.key) }  // deleted by hand
        for id in names where s.cache[id] == nil && !s.unreadable.contains(id) {
            guard let document = ProjectDocument.load(from: url(id)), let meta = document[Self.metaKey], let at = meta["at"]?.double else {
                s.unreadable.insert(id)
                logger.warning("project version skipped: not a readable version", metadata: ["file": "\(id).json"])
                continue
            }
            s.cache[id] = Version(id: id, at: at, name: meta["name"]?.string ?? id, automatic: meta["automatic"]?.bool ?? true, project: document)
        }
        let versions = s.cache.values.sorted { ($0.at, $0.id) > ($1.at, $1.id) }
        if !s.loaded {
            s.loaded = true
            // a clock set back since the newest version must not make the next one sort (or prune) below it
            s.lastAt = max(s.lastAt, versions.first?.at ?? 0)
        }
        return versions
    }

    private func documentLocked(_ id: String, _ s: inout State) throws -> JSONValue {
        // ids come from clients and OSC: only a listed version (a plain file name in the directory, with snapshot info)
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix("."), listLocked(&s).contains(where: { $0.id == id }) else { throw Self.notFound(id) }
        guard var document = ProjectDocument.load(from: url(id)), document[Self.metaKey] != nil else {
            throw CommandError("corrupt", "project version \(id) is not a readable version")
        }
        try? document.remove(at: JSONPointer(tokens: [Self.metaKey]))
        return document
    }

    private func saveLocked(_ project: JSONValue, name: String, automatic: Bool, now: Date, _ s: inout State) throws -> Version {
        let existing = listLocked(&s)
        // strictly increasing times: the newest version is always the last one written, also when the clock went back
        let at = max(now.timeIntervalSince1970, s.lastAt + 0.000_001)
        s.lastAt = at
        var document = project
        try document.set(["name": .string(name), "at": .number(at), "automatic": .bool(automatic)], at: JSONPointer(tokens: [Self.metaKey]))
        // two saves within one millisecond share the stamp: a counter keeps the ids apart
        let stamp = Self.stamp(at), slug = Self.slug(automatic ? "auto-\(name)" : name)
        var id = "\(stamp)-\(slug)"
        var n = 1
        while s.cache[id] != nil || s.unreadable.contains(id) || FileManager.default.fileExists(atPath: url(id).path) {
            n += 1
            id = "\(stamp)-\(n)-\(slug)"
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ProjectDocument.save(document, to: url(id))  // atomic
        let version = Version(id: id, at: at, name: name, automatic: automatic, project: project)
        s.cache[id] = version
        s.newestID = id
        s.newestDigest = Self.digest(project)
        s.serial += 1
        if automatic {
            // by time, newest first; the version just written stays whatever the clock says
            let older = existing.filter(\.automatic).dropFirst(Self.keepAutomatic - 1)
            for old in older where old.id != id {
                do {
                    try FileManager.default.removeItem(at: url(old.id))
                    s.cache[old.id] = nil
                } catch { logger.warning("old project version not deleted", metadata: ["id": "\(old.id)", "error": "\(error)"]) }
            }
        }
        return version
    }

    /// "20261026T143012.345Z" (UTC, sorts by time).
    static func stamp(_ at: Double) -> String {
        Date(timeIntervalSince1970: at).formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeSeparator(.omitted).dateSeparator(.omitted)) + "Z"
    }

    /// File-name part of a name: letters and digits, everything else one dash, at most 40 characters.
    static func slug(_ name: String) -> String {
        var out = ""
        for c in name.lowercased() {
            if c.isLetter || c.isNumber { out.append(c) } else if !out.hasSuffix("-") { out.append("-") }
        }
        let trimmed = String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
        return trimmed.isEmpty ? "version" : trimmed
    }

    /// A version is restored only when a live command could have made it: the same limits as `layers.setCount`,
    /// `patch.set` and `canvas.*`.
    static func checkRestorable(_ project: JSONValue) throws {
        func refuse(_ reason: String) -> CommandError { CommandError.invalidArgs("this version cannot be restored: \(reason)") }
        guard let layers = project["layerCount"]?.int, (1...64).contains(layers) else { throw refuse("the layer count must be 1–64") }
        guard ProjectDocument.effectivePatch(from: project) != nil else { throw refuse("the patch has an unknown fixture, universe or address") }
        let canvases = ProjectDocument.canvases(from: project)
        guard (1...ProjectDocument.maxCanvases).contains(canvases.count) else { throw refuse("it needs 1–\(ProjectDocument.maxCanvases) readable canvases") }
        do {
            for c in canvases { _ = try ProjectDocument.validated((c.width, c.height, c.fps)) }
            try ProjectDocument.checkTotalPixels(canvases)
        } catch let error as CommandError {
            throw refuse(error.message)
        }
    }
}

// MARK: Commands

extension ProjectVersions {
    public static let maxNameLength = 80

    /// `showModeOn`: a revert is refused in show mode, like any other project load, and so is its undo or redo.
    public func registerCommands(on store: StateStore, showModeOn: @escaping @Sendable () -> Bool = { false }) {
        let showModeRefusal = CommandError("showMode", "a version cannot be restored in show mode; leave show mode first")
        store.register(
            CommandSpec(
                name: "project.snapshot", role: .programmer, mutatesConfig: false, undoable: false,
                summary: "Save a version of the project now; with a name it never expires, without one it is an automatic version.",
                argsType: "{ name?: string }"
            ) { [self] project, args in
                let name = args["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard name.count <= Self.maxNameLength else { throw CommandError.invalidArgs("name: at most \(Self.maxNameLength) characters") }
                do {
                    return try save(project, name: name.isEmpty ? Reason.manual.rawValue : name, automatic: name.isEmpty).json
                } catch {
                    throw CommandError("failed", "cannot save the version: \(error)")
                }
            })
        store.register(
            CommandSpec(
                name: "project.versions", role: .monitor, mutatesConfig: false, undoable: false,
                summary: "List the project versions, newest first: id, at (epoch s), name, automatic, layers, outputs, canvases, cues."
            ) { [self] _, _ in .array(list().map(\.json)) })
        store.register(
            CommandSpec(
                name: "project.revert", role: .programmer,
                summary: "Restore a project version (refused in show mode, also its undo and redo). The current project is saved as a version first; the show lock stays as it is.",
                argsType: "{ id: string }",
                replayCheck: { patch, project in
                    if showModeOn() { throw showModeRefusal }
                    // the revert diffs `/syphon` too: its undo or redo must not overwrite a number taken meanwhile (B91)
                    try ProjectDocument.checkSyphonReplay(patch, on: project)
                }
            ) { [self] project, args in
                guard let id = args["id"]?.string else { throw CommandError.invalidArgs("id must be a version id") }
                guard !showModeOn() else { throw showModeRefusal }
                var target = try document(id: id)
                try Self.checkRestorable(target)
                if Self.comparable(target) == Self.comparable(project) {
                    logger.info("revert skipped: the project already equals the version", metadata: ["id": "\(id)"])
                    return ["reverted": .string(id), "unchanged": true]
                }
                let targetName = list().first { $0.id == id }?.name ?? id
                // the state being left is a version too (unless the newest one already is), so a revert can be
                // reverted after a restart
                let before: Version?
                do {
                    before = try saveIfChanged(project, name: "\(Reason.beforeRevert.rawValue) to \(targetName)")
                } catch {
                    throw CommandError("failed", "cannot save the current project first: \(error)")
                }
                try target.set(project["showLock"] ?? false, at: "/showLock")
                project = target
                return ["reverted": .string(id), "saved": before.map { .string($0.id) } ?? .null]
            })
        store.register(
            CommandSpec(
                name: "project.deleteVersion", role: .programmer, undoable: false, summary: "Delete a named project version (automatic ones expire by themselves).",
                argsType: "{ id: string }"
            ) { [self] _, args in
                guard let id = args["id"]?.string else { throw CommandError.invalidArgs("id must be a version id") }
                try delete(id: id)
                return nil
            })
    }
}
