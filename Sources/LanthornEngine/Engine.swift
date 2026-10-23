// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import LanthornCore
import Logging
import QuartzCore

public struct EngineOptions: Sendable {
    public var port: UInt16
    public var webRoot: URL
    /// Phase 2: a static scene to render (until projects exist in Phase 5).
    public var scene: SceneConfig?

    public init(port: UInt16 = 8443, webRoot: URL, scene: SceneConfig? = nil) {
        self.port = port
        self.webRoot = webRoot
        self.scene = scene
    }
}

struct HealthStatus: Encodable {
    var status = "ok"
    var version = LanthornVersion.string
    var uptimeSeconds: Int
    var chip: String
    var webRoot: String
}

/// Phase 0 engine: logs the machine, owns the TLS identity and serves the UI.
public final class Engine: @unchecked Sendable {
    private let options: EngineOptions
    private let logger: Logger
    private var server: HTTPSServer?
    private let startedAt = Date()
    private var dmx: DMXStore?
    private var artnet: ArtNetReceiver?
    private var sacn: SACNReceiver?
    private var osc: OSCReceiver?
    private var render: RenderService?
    public let metrics = MetricsRing()

    public init(options: EngineOptions, logger: Logger) {
        self.options = options
        self.logger = logger
    }

    public func start() throws {
        try AppPaths.ensureDirectories()
        logger.info(
            "lanthornd starting",
            metadata: [
                "version": "\(LanthornVersion.string)", "chip": "\(SystemInfo.chipName)",
                "memoryGB": "\(SystemInfo.physicalMemoryBytes / 1_073_741_824)", "os": "\(SystemInfo.osVersion)",
                "webRoot": "\(options.webRoot.path)",
            ])
        let host = SystemInfo.hostName
        var hostnames = ["localhost", host]
        if !host.hasSuffix(".local") { hostnames.append(host + ".local") }
        let identity = try TLSIdentity.loadOrCreate(
            directory: AppPaths.tls, hostnames: hostnames, ipAddresses: ["127.0.0.1", "::1"] + SystemInfo.ipv4Addresses,
            logger: logger)
        // Phase 1: the standard patch until projects exist (Phase 5).
        let patch = Patch.standard()
        let dmx = DMXStore(patch: patch, logger: logger)
        if let policy = options.scene?.policy, policy != .dmx {
            for entry in patch.entries { dmx.setPolicy(policy, for: entry.fixture) }
        }
        dmx.start()
        let artnet = ArtNetReceiver(store: dmx, logger: logger, nodeName: Attribution.projectName)
        try artnet.start()
        let sacn = SACNReceiver(store: dmx, logger: logger)
        try sacn.start(universes: [1, 2, 3])
        let osc = OSCReceiver(store: dmx, logger: logger)
        try osc.start()
        self.dmx = dmx
        self.artnet = artnet
        self.sacn = sacn
        self.osc = osc

        if let scene = options.scene {
            let context = try MetalContext()
            let service = try MainActor.assumeIsolated {
                try RenderService(scene: scene, context: context, parameters: dmx.snapshots, metrics: metrics, logger: logger)
            }
            render = service
            let log = logger
            Task { @MainActor in
                do { try await service.start() } catch { log.error("render start failed", metadata: ["error": "\(error)"]) }
            }
        }

        let startedAt = self.startedAt
        let webRoot = options.webRoot
        let metrics = self.metrics
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let server = try HTTPSServer(port: options.port, identity: identity, webRoot: options.webRoot, logger: logger) { request in
            switch request.path {
            case "/healthz":
                let health = HealthStatus(
                    uptimeSeconds: Int(Date().timeIntervalSince(startedAt)), chip: SystemInfo.chipName, webRoot: webRoot.path)
                return .json(200, Array((try? encoder.encode(health)) ?? Data()))
            case "/api/live":
                return .json(200, Array((try? encoder.encode(dmx.snapshot())) ?? Data()))
            case "/api/patch":
                return .json(200, Array((try? encoder.encode(patch)) ?? Data()))
            case "/api/gdtf":
                return HTTPResponse(
                    status: 200,
                    headers: [HTTPHeader("Content-Type", "application/zip"), HTTPHeader("Content-Disposition", "attachment; filename=\"Lanthorn.gdtf\"")],
                    body: GDTFExporter.gdtf())
            case "/api/channel-map.md":
                return .text(200, ChannelMapDocument.markdown())
            case "/api/metrics":
                var text = metrics.summary(seconds: 10, now: CACurrentMediaTime()).description
                if let audio = self.render?.mixer?.statistics {
                    text += String(format: "\naudio: callbacks %llu  underruns %llu  corrections %llu  max drift %.1f ms", audio.callbacks, audio.underruns, audio.corrections, audio.maxDriftMillis)
                }
                return .text(200, text)
            default:
                return nil
            }
        }
        server.start()
        self.server = server
    }

    public func stop() {
        server?.stop()
        artnet?.stop()
        sacn?.stop()
        osc?.stop()
        dmx?.stop()
        logger.info("lanthornd stopped")
    }
}

public enum WebRoot {
    /// --web-root flag > $LANTHORN_WEB_ROOT > <bundle>/Contents/Resources/web > web/dist near a dev build.
    public static func locate() -> URL {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["LANTHORN_WEB_ROOT"] { return URL(fileURLWithPath: env) }
        if let resources = Bundle.main.resourceURL?.appending(path: "web"), fm.fileExists(atPath: resources.path) {
            return resources
        }
        var directory = Bundle.main.executableURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = directory.appending(path: "web/dist")
            if fm.fileExists(atPath: candidate.appending(path: "index.html").path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: "web/dist")
    }
}
