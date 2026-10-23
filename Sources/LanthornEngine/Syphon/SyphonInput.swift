// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import Synchronization
import Syphon

/// Latest frame of a Syphon client, written by Syphon's frame-notification thread, read by the compositor.
/// The critical section is one reference move, so the reader never waits for anything slower than that.
private final class FrameSlot: Sendable {
    // MTLTexture is not Sendable; the slot only hands the reference over, nothing mutates it here
    private struct Held: @unchecked Sendable { var texture: MTLTexture? }
    private let held = Mutex(Held(texture: nil))
    private let count = Atomic<Int>(0)

    var frames: Int { count.load(ordering: .relaxed) }
    func load() -> MTLTexture? { held.withLock { $0.texture } }
    func clear() { held.withLock { $0.texture = nil } }
    func store(_ texture: MTLTexture?) {
        held.withLock { $0.texture = texture }
        count.wrappingAdd(1, ordering: .relaxed)
    }
}

/// Watches the Syphon server directory and receives frames from one chosen server.
/// `connect`/`disconnect` belong to one control thread; `latestTexture`, `servers` and `frames` are safe anywhere.
public final class SyphonInput: @unchecked Sendable {
    public struct ServerInfo: Sendable, Hashable {
        public let appName: String
        public let serverName: String
        public let uuid: String
    }

    private let device: MTLDevice
    private let slot = FrameSlot()
    private var client: SyphonMetalClient?
    private var observers: [any NSObjectProtocol] = []

    /// Number of new-frame notifications received since creation.
    public var frames: Int { slot.frames }

    /// `onServersChanged` runs on whatever thread Syphon posts the announce / update / retire notification on.
    public init(device: MTLDevice, onServersChanged: (@Sendable () -> Void)? = nil) {
        self.device = device
        let directory = SyphonServerDirectory.shared()
        for name in [Notification.Name.SyphonServerAnnounce, .SyphonServerUpdate, .SyphonServerRetire] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: directory, queue: nil) { _ in
                    onServersChanged?()
                })
        }
    }

    deinit {
        disconnect()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Servers the directory currently knows about (all processes, including this one).
    public var servers: [ServerInfo] {
        SyphonServerDirectory.shared().servers.map { description in
            ServerInfo(
                appName: description[SyphonServerDescriptionAppNameKey] as? String ?? "",
                serverName: description[SyphonServerDescriptionNameKey] as? String ?? "",
                uuid: description[SyphonServerDescriptionUUIDKey] as? String ?? "")
        }
    }

    /// The newest frame, or nil before the first frame or after `disconnect`. The texture is backed by the
    /// server's IOSurface and may update in place; take it again every frame rather than holding on to it.
    public var latestTexture: MTLTexture? { slot.load() }

    public var isConnected: Bool { client?.isValid ?? false }

    public func connect(appName: String, serverName: String) throws {
        // Syphon treats an empty name as "any", so a match here is never ambiguous in the sense of a wrong server type
        guard let description = SyphonServerDirectory.shared().servers(matchingName: serverName, appName: appName).first else {
            throw SyphonError.serverNotFound(appName: appName, serverName: serverName)
        }
        try connect(description: description)
    }

    /// Connects with a server description, e.g. `SyphonOutput.serverDescription` for a private server.
    public func connect(description: [String: Any]) throws {
        disconnect()
        let slot = self.slot
        let new = SyphonMetalClient(serverDescription: description, device: device, options: nil) { client in
            slot.store(client.newFrameImage())
        }
        let name = description[SyphonServerDescriptionNameKey] as? String ?? "?"
        guard let new, new.isValid else {
            new?.stop()
            throw SyphonError.clientFailed(name)
        }
        client = new
    }

    public func disconnect() {
        client?.stop()
        client = nil
        slot.clear()
    }
}

extension SyphonInput: LiveTextureSource {
    public func stop() { disconnect() }
}
