// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import Synchronization

/// Folder 0 files 150–169 (B61): the Syphon servers of other apps, numbered in the order the directory announces
/// them, so a console or the UI selects one like a generator. A server that goes keeps its number (not running)
/// until the engine restarts, so numbers never shift under a console; one that comes back with the same app and
/// server name takes its old number again. Safe on any thread, except `start`/`stop` (one control thread).
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
        public var running: Bool { uuid != nil }
        /// "App/Server", or "App" when the server has no name.
        public var name: String { server.isEmpty ? app : "\(app)/\(server)" }
    }

    private let state = Mutex<[Server]>([])
    /// This engine's own canvas server, never offered as an input.
    private let excluded: String?
    // start/stop only: they hold the directory observation and the announce timer alive
    private var watcher: SyphonInput?
    private var timer: DispatchSourceTimer?
    /// Runs after every change of numbers, names or running state (any thread); set before `start`.
    public var onChange: (@Sendable () -> Void)?

    public init(excluding uuid: String? = nil) {
        excluded = uuid
    }

    public var servers: [Server] { state.withLock { $0 } }
    public func server(file: Int) -> Server? { state.withLock { list in list.first { $0.file == file } } }

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
        let changed = state.withLock { list in
            Self.assign(&list, running: (running ?? SyphonInput.directoryServers).filter { $0.uuid != excluded })
        }
        if changed { onChange?() }
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
            } else if servers.count < files.count {
                servers.append(Server(file: files.lowerBound + servers.count, app: info.appName, server: info.serverName, uuid: info.uuid))
            }
            // ponytail: past 20 numbers a new server gets none until the engine restarts (B69: forget gone servers)
        }
        return servers != before
    }
}
