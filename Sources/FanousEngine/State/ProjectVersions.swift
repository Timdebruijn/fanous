// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

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

        var json: JSONValue {
            [
                "id": .string(id), "at": .number(at), "name": .string(name), "automatic": .bool(automatic),
                "layers": .number(Double(layers)), "outputs": .number(Double(outputs)), "canvases": .number(Double(canvases)), "cues": .number(Double(cues)),
            ]
        }
    }

    private struct State {
        var lastAt: Double = 0
        var lastAutomatic: Double?
        /// Bumped on every write or delete, so the UI knows to fetch the list again.
        var serial = 0
        var warnedCorrupt: Set<String> = []
    }

    public let directory: URL
    private let logger: Logger
    /// Also serializes the file operations: the control queue (commands) and the feed queue (automatic) both write.
    private let state = Mutex(State())

    public init(directory: URL, logger: Logger) {
        self.directory = directory
        self.logger = logger
    }

    /// `live.versions`: when the newest automatic version was written and a change counter.
    public var live: JSONValue {
        state.withLock { s in ["lastAutomatic": s.lastAutomatic.map { .number($0) } ?? .null, "serial": .number(Double(s.serial))] }
    }

    // MARK: Files

    /// Newest first; files that do not load as a project are skipped (logged once per file).
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
        state.withLock { s in
            if let newest = listLocked(&s).first, let document = try? documentLocked(newest.id), Self.comparable(document) == Self.comparable(project) {
                return nil
            }
            do {
                return try saveLocked(project, name: reason.rawValue, automatic: true, now: now, &s)
            } catch {
                logger.error("automatic project version failed", metadata: ["reason": "\(reason.rawValue)", "error": "\(error)"])
                return nil
            }
        }
    }

    /// The project document of a version, without its `snapshot` member.
    public func document(id: String) throws -> JSONValue {
        try state.withLock { _ in try documentLocked(id) }
    }

    /// Deletes a named version; automatic ones expire by themselves.
    public func delete(id: String) throws {
        try state.withLock { s in
            guard let version = listLocked(&s).first(where: { $0.id == id }) else { throw Self.notFound(id) }
            guard !version.automatic else { throw CommandError.invalidArgs("automatic versions expire by themselves; only named versions can be deleted") }
            try FileManager.default.removeItem(at: url(id))
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

    /// What "the same project" means for skipping a snapshot: the show lock and the version info do not count.
    private static func comparable(_ project: JSONValue) -> JSONValue {
        guard case .object(var o) = project else { return project }
        o[metaKey] = nil
        o["showLock"] = nil
        return .object(o)
    }

    private func listLocked(_ s: inout State) -> [Version] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var versions: [Version] = []
        for file in files where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard let document = ProjectDocument.load(from: file), let meta = document[Self.metaKey], let at = meta["at"]?.double else {
                if s.warnedCorrupt.insert(id).inserted { logger.warning("project version skipped: not a readable project", metadata: ["file": "\(file.lastPathComponent)"]) }
                continue
            }
            versions.append(
                Version(
                    id: id, at: at, name: meta["name"]?.string ?? id, automatic: meta["automatic"]?.bool ?? true,
                    layers: document["layerCount"]?.int ?? 0, outputs: document["outputs"]?.array?.count ?? 0,
                    canvases: document["canvases"]?.array?.count ?? 0, cues: document["cues"]?.array?.count ?? 0))
        }
        versions.sort { ($0.at, $0.id) > ($1.at, $1.id) }
        s.lastAutomatic = versions.first(where: \.automatic)?.at
        return versions
    }

    private func documentLocked(_ id: String) throws -> JSONValue {
        // ids come from clients and OSC: only a plain file name in the versions directory
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix("."), FileManager.default.fileExists(atPath: url(id).path) else { throw Self.notFound(id) }
        guard var document = ProjectDocument.load(from: url(id)) else { throw CommandError("corrupt", "project version \(id) is not a readable project") }
        try? document.remove(at: JSONPointer(tokens: [Self.metaKey]))
        return document
    }

    private func saveLocked(_ project: JSONValue, name: String, automatic: Bool, now: Date, _ s: inout State) throws -> Version {
        // strictly increasing times: the newest version is always the last one written
        let at = max(now.timeIntervalSince1970, s.lastAt + 0.001)
        s.lastAt = at
        var document = project
        try document.set(["name": .string(name), "at": .number(at), "automatic": .bool(automatic)], at: JSONPointer(tokens: [Self.metaKey]))
        let id = "\(Self.stamp(at))-\(Self.slug(automatic ? "auto-\(name)" : name))"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ProjectDocument.save(document, to: url(id))  // atomic
        s.serial += 1
        if automatic {
            for old in listLocked(&s).filter(\.automatic).dropFirst(Self.keepAutomatic) {
                do { try FileManager.default.removeItem(at: url(old.id)) } catch { logger.warning("old project version not deleted", metadata: ["id": "\(old.id)", "error": "\(error)"]) }
            }
            s.lastAutomatic = at
        }
        return Version(
            id: id, at: at, name: name, automatic: automatic, layers: project["layerCount"]?.int ?? 0, outputs: project["outputs"]?.array?.count ?? 0,
            canvases: project["canvases"]?.array?.count ?? 0, cues: project["cues"]?.array?.count ?? 0)
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
}

// MARK: Commands

extension ProjectVersions {
    public static let maxNameLength = 80

    /// `showModeOn`: a revert is refused in show mode, like any other project load.
    public func registerCommands(on store: StateStore, showModeOn: @escaping @Sendable () -> Bool = { false }) {
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
                summary: "Restore a project version (refused in show mode). The current project is saved as a version first; the show lock stays as it is.",
                argsType: "{ id: string }"
            ) { [self] project, args in
                guard let id = args["id"]?.string else { throw CommandError.invalidArgs("id must be a version id") }
                guard !showModeOn() else { throw CommandError("showMode", "a version cannot be restored in show mode; leave show mode first") }
                var target = try document(id: id)
                let targetName = list().first { $0.id == id }?.name ?? id
                // the state being left is a version too, so the revert can be reverted after a restart
                let before: Version
                do {
                    before = try save(project, name: "\(Reason.beforeRevert.rawValue) to \(targetName)", automatic: true)
                } catch {
                    throw CommandError("failed", "cannot save the current project first: \(error)")
                }
                try target.set(project["showLock"] ?? false, at: "/showLock")
                project = target
                return ["reverted": .string(id), "saved": .string(before.id)]
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
