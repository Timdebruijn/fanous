// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Metal
import Syphon

public enum SyphonError: Error, CustomStringConvertible {
    case serverFailed(String)
    case serverNotFound(appName: String, serverName: String)
    case clientFailed(String)
    case notRunning(String)

    public var description: String {
        switch self {
        case .serverFailed(let name): "Syphon server '\(name)' could not be started"
        case .serverNotFound(let app, let name): "no Syphon server '\(name)' from '\(app)'"
        case .clientFailed(let name): "Syphon client for '\(name)' could not connect"
        case .notRunning(let uuid): "Syphon server \(uuid) is not running"
        }
    }
}

/// One Syphon server (Metal path) that publishes the engine's output to other applications.
/// Safe to call from any thread; Syphon locks internally.
public final class SyphonOutput: @unchecked Sendable {
    public let name: String
    private let server: SyphonMetalServer

    public init(name: String, device: MTLDevice) throws {
        guard let server = SyphonMetalServer(name: name, device: device, options: nil) else { throw SyphonError.serverFailed(name) }
        self.name = name
        self.server = server
    }

    deinit { server.stop() }

    /// True while at least one client is attached; skip `publish` when false.
    public var hasClients: Bool { server.hasClients }

    /// The description a client needs to connect to this server without the directory (also for private servers).
    public var serverDescription: [String: Any] { server.serverDescription.mapValues { $0 as Any } }

    /// The directory's id of this server (the catalog leaves the engine's own canvas out, B61).
    public var uuid: String? { server.serverDescription[SyphonServerDescriptionUUIDKey] as? String }

    public func stop() { server.stop() }

    /// Encodes a copy of the whole texture into the server's IOSurface on `commandBuffer`. The caller commits the
    /// buffer and calls `publishCompleted` once it has completed (B109: no completion handler per frame). Syphon
    /// surfaces are in OpenGL order (row 0 at the bottom); a Metal texture has row 0 at the top, so it is published
    /// `flipped` and Syphon draws it upside down into the surface. Checked 2026-10-26 with the Syphon Simple Client
    /// (OpenGL): with `flipped: false` it showed the canvas upside down. The texture needs `.shaderRead` usage and must
    /// not be `framebufferOnly`; the flip always takes Syphon's draw path (one quad), never the blit.
    public func publish(texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        _ = server.encodeFrameTexture(
            texture, on: commandBuffer,
            imageRegion: NSRect(x: 0, y: 0, width: texture.width, height: texture.height), flipped: true)
    }

    /// Tells the clients a new frame is in the surface: the buffer of the last `publish` has completed.
    public func publishCompleted() { server.publish() }
}
