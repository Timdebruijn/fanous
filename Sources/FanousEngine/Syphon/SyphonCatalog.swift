// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import Synchronization

/// Folder 0 files 150–169 (B61): the Syphon servers of other apps, numbered in the order the directory announces
/// them, so a console or the UI selects one like a generator. A server that goes keeps its number (not running)
/// until the engine restarts, so numbers never shift under a console; one that comes back with the same app and
/// server name takes its old number again. Safe on any thread.
public final class SyphonCatalog: @unchecked Sendable {
    public static let files = 150...169

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
    private var watcher: SyphonInput?  // set once by `start`
    private var excluded: String?
    /// Runs after every change of numbers or running state (any thread); set before `start`.
    public var onChange: (@Sendable () -> Void)?

    public init() {}

    public var servers: [Server] { state.withLock { $0 } }
    public func server(file: Int) -> Server? { state.withLock { list in list.first { $0.file == file } } }

    /// Follows Syphon's directory from now on. `excluding` is this engine's own canvas server, never offered as input.
    public func start(device: MTLDevice, excluding uuid: String?) {
        excluded = uuid
        watcher = SyphonInput(device: device) { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        guard let watcher else { return }
        update(running: watcher.servers.filter { $0.uuid != excluded })
    }

    /// Applies the directory's current list (in announce order).
    public func update(running: [SyphonInput.ServerInfo]) {
        if state.withLock({ Self.assign(&$0, running: running) }) { onChange?() }
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
            // ponytail: past 20 numbers a new server gets none until the engine restarts; reuse gone slots if that bites
        }
        return servers != before
    }
}
