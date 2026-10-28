// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import Synchronization

/// Folder 0 files 150–169 (B61): the Syphon servers of other apps, numbered as the directory announces them (the
/// lowest free number), so a console or the UI selects one like a generator. A server that goes keeps its number (not
/// running); one that comes back with the same app and server name takes its old number again. The numbering is kept
/// in the project (`syphon`, B69): the catalog starts from it, so numbers survive an engine restart, and only
/// `syphon.forget` frees one. Safe on any thread, except `start`/`stop` (one control thread).
public final class SyphonCatalog: @unchecked Sendable {
    public static let files = 150...169
    /// Syphon's `SyphonServerAnnounceRequest` (SyphonPrivate.h): every server answers, and every directory retires the
    /// servers that did not answer within 6 s, so a crashed app's server does not stay listed as running.
    static let announceRequest = Notification.Name("info.v002.Syphon.ServerAnnounceRequest")
    static let announceInterval = 5.0

    public struct Server: Sendable, Equatable {
        public let file: Int
        public var app: String
        public var server: String
        /// The directory's id while the server runs; nil once it has gone.
        public var uuid: String?
        /// From the project and not announced since the engine started (B69).
        public var gone = false
        public var running: Bool { uuid != nil }
        /// "App/Server", or "App" when the server has no name.
        public var name: String { server.isEmpty ? app : "\(app)/\(server)" }
    }

    private struct State {
        var servers: [Server] = []
        /// The directory's list as last applied, so a number freed by `adopt` goes to a server waiting for one.
        var running: [SyphonInput.ServerInfo] = []
    }
    private let state = Mutex(State())
    /// This engine's own canvas server, never offered as an input.
    private let excluded: String?
    // start/stop only: they hold the directory observation and the announce timer alive
    private var watcher: SyphonInput?
    private var timer: DispatchSourceTimer?
    /// Runs after every change of numbers, names or running state (any thread); set before `start`.
    public var onChange: (@Sendable () -> Void)?

    /// `numbers`: the project's numbering (B69), taken as gone servers until they announce.
    public init(excluding uuid: String? = nil, numbers: [Server] = []) {
        excluded = uuid
        _ = adopt(numbers)
    }

    public var servers: [Server] { state.withLock { $0.servers } }
    /// Running servers past the 20 numbers, as "App/Server": they get one when `syphon.forget` frees it.
    public var unnumbered: [String] {
        state.withLock { s in
            s.running.filter { info in !s.servers.contains { $0.uuid == info.uuid } }.map { Server(file: 0, app: $0.appName, server: $0.serverName).name }
        }
    }
    public func server(file: Int) -> Server? { state.withLock { $0.servers.first { $0.file == file } } }

    /// Follows Syphon's directory from now on, and asks every server to announce itself every 5 s while one is listed
    /// as running, so one whose app crashed (no retire notification) is retired within about 11 s.
    public func start(device: MTLDevice) {
        watcher = SyphonInput(device: device) { [weak self] in self?.update() }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.announceInterval, repeating: Self.announceInterval)
        timer.setEventHandler { [weak self] in
            guard self?.servers.contains(where: { $0.running }) == true else { return }
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

    /// Applies `running` (in announce order), or the directory's current list when nil. The directory is read under the
    /// lock, so two notifications racing on different threads never apply an older list last (the directory does not
    /// call out while it holds its own lock, so this cannot deadlock).
    public func update(running: [SyphonInput.ServerInfo]? = nil) {
        let changed = state.withLock { s in
            s.running = (running ?? SyphonInput.directoryServers).filter { $0.uuid != excluded }
            return Self.assign(&s.servers, running: s.running)
        }
        if changed { onChange?() }
    }

    /// Applies the project's numbering (start, `syphon.forget`, undo, a loaded project); true when anything changed.
    @discardableResult public func adopt(_ numbers: [Server]) -> Bool {
        let changed = state.withLock { s in
            let adopted = Self.adopt(&s.servers, numbers: numbers)
            return Self.assign(&s.servers, running: s.running) || adopted
        }
        if changed { onChange?() }
        return changed
    }

    /// A server not running that `numbers` lists is kept or added (gone until it announces); one it does not list is
    /// forgotten. A running server always keeps its number: an entry on its number is dropped (the engine then writes
    /// the catalog back into the project).
    static func adopt(_ servers: inout [Server], numbers: [Server]) -> Bool {
        let before = servers
        var next = servers.filter(\.running)
        for entry in numbers where files.contains(entry.file) && !next.contains(where: { $0.file == entry.file }) {
            let kept = servers.first { $0.file == entry.file && !$0.running && $0.app == entry.app && $0.server == entry.server }
            next.append(kept ?? Server(file: entry.file, app: entry.app, server: entry.server, gone: true))
        }
        servers = next.sorted { $0.file < $1.file }
        return servers != before
    }

    /// The numbering rules; true when anything changed.
    static func assign(_ servers: inout [Server], running: [SyphonInput.ServerInfo]) -> Bool {
        let before = servers
        let alive = Set(running.map(\.uuid))
        for i in servers.indices where servers[i].uuid.map({ !alive.contains($0) }) ?? false { servers[i].uuid = nil }
        for info in running where !info.uuid.isEmpty {
            if let i = servers.firstIndex(where: { $0.uuid == info.uuid }) {
                servers[i].app = info.appName  // a rename (SyphonServerUpdate) keeps the number
                servers[i].server = info.serverName
            } else if let i = servers.firstIndex(where: { $0.uuid == nil && $0.app == info.appName && $0.server == info.serverName }) {
                servers[i].uuid = info.uuid
                servers[i].gone = false
            } else if let file = files.first(where: { file in !servers.contains { $0.file == file } }) {
                servers.append(Server(file: file, app: info.appName, server: info.serverName, uuid: info.uuid))
                servers.sort { $0.file < $1.file }
            }
            // past 20 numbers a new server gets none (`unnumbered`) until `syphon.forget` frees one
        }
        return servers != before
    }
}
