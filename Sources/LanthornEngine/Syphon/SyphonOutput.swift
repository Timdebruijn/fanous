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

    public var description: String {
        switch self {
        case .serverFailed(let name): "Syphon server '\(name)' could not be started"
        case .serverNotFound(let app, let name): "no Syphon server '\(name)' from '\(app)'"
        case .clientFailed(let name): "Syphon client for '\(name)' could not connect"
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

    public func stop() { server.stop() }

    /// Encodes a copy of the whole texture into the server's IOSurface on `commandBuffer`; Syphon tells the
    /// clients when that buffer completes. The caller commits the buffer. Metal textures have their origin top
    /// left, which is what Syphon's Metal path expects, so `flipped` is false and clients see the image upright.
    /// The texture needs `.shaderRead` usage and must not be `framebufferOnly` (same format = blit, else a draw).
    public func publish(texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        server.publishFrameTexture(
            texture, on: commandBuffer,
            imageRegion: NSRect(x: 0, y: 0, width: texture.width, height: texture.height), flipped: false)
    }
}
