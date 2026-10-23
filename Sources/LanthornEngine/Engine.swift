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
    private var library: LibraryIndex?
    private var ingest: IngestQueue?
    private var auth: RoleAuth?
    private var store: StateStore?
    private var stateServer: StateServer?
    private var liveTimer: DispatchSourceTimer?
    private var dmxTimer: DispatchSourceTimer?
    private var autosave: DispatchWorkItem?
    private let feedQueue = DispatchQueue(label: "org.lanthorn.feed", qos: .utility)
    public let metrics = MetricsRing()

    /// The command registry as `lanthornd protocol-dts` sees it: no engine needed.
    public static func commandSpecs() -> [CommandSpec] {
        let logger = Logger(label: "protocol")
        let store = StateStore(project: [:], logger: logger)
        ProjectDocument.registerCommands(on: store, auth: RoleAuth(settingsURL: nil, shellTokenURL: nil, logger: logger))
        return store.commandSpecs
    }

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

        // The library is always indexed (DESIGN.md §8); scenes may add explicit entries (Syphon inputs, test files).
        let context = try MetalContext()
        let libraryRoot = options.scene?.library.map { URL(fileURLWithPath: $0) } ?? AppPaths.defaultLibrary
        let library = LibraryIndex(root: libraryRoot, cacheDirectory: AppPaths.cache, logger: logger)
        let thumbnailer = Thumbnailer(context: context, directory: AppPaths.cache.appending(path: "thumbnails"), logger: logger)
        library.thumbnailer = { url, metadata, kind in thumbnailer.make(for: url, metadata: metadata, kind: kind) }
        library.start()
        self.library = library

        // Ingest queue (DESIGN.md §8.3): one job at a time at utility priority; yields while the compositor is busy.
        let ingest = IngestQueue(persistenceURL: AppPaths.ingestQueueFile, logger: logger)
        let metrics = self.metrics
        let fps = options.scene?.fps ?? 60
        ingest.shouldYield = {
            let budget = 0.7 / fps * 1e6
            return metrics.recent(seconds: 0.25, now: CACurrentMediaTime()).contains { Double($0.cpuMicros + $0.gpuMicros) > budget }
        }
        ingest.start()
        self.ingest = ingest

        if let scene = options.scene {
            let service = try MainActor.assumeIsolated {
                try RenderService(scene: scene, context: context, parameters: dmx.snapshots, metrics: metrics, logger: logger)
            }
            service.loader.resolver = { key in library.resolve(key) }
            render = service
            let log = logger
            Task { @MainActor in
                do { try await service.start() } catch { log.error("render start failed", metadata: ["error": "\(error)"]) }
            }
        }

        // Phase 5: roles, the project and live documents and the WebSocket state server (DESIGN.md §11).
        let auth = RoleAuth(settingsURL: AppPaths.settingsFile, shellTokenURL: AppPaths.shellTokenFile, logger: logger)
        let project =
            ProjectDocument.load(from: AppPaths.projectFile)
            ?? ProjectDocument.initial(
                patch: patch, layerCount: options.scene?.layerCount ?? 8, libraryRoot: libraryRoot.path, policy: options.scene?.policy ?? .dmx)
        if let loaded = ProjectDocument.patch(from: project), loaded != patch { dmx.setPatch(loaded) }
        let store = StateStore(project: project, logger: logger)
        ProjectDocument.registerCommands(on: store, auth: auth)
        store.onProjectChanged = { [weak self] document in self?.projectChanged(document) }
        let caps: JSONValue = [
            "schema": .number(Double(StateServer.schema)), "version": .string(LanthornVersion.string), "chip": .string(SystemInfo.chipName),
            "maxLayers": 32, "fps": .number(fps),
        ]
        let stateServer = StateServer(store: store, auth: auth, caps: caps, logger: logger)
        self.auth = auth
        self.store = store
        self.stateServer = stateServer
        startFeeds()

        let startedAt = self.startedAt
        let webRoot = options.webRoot
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let ingestAPI = IngestAPI(library: library, queue: ingest, encoder: encoder, logger: logger)
        let server = try HTTPSServer(port: options.port, identity: identity, webRoot: options.webRoot, logger: logger) { request in
            if request.path.hasPrefix("/api/ingest") || request.path.hasPrefix("/api/upload/") { return ingestAPI.handle(request, uploadedFile: nil) }
            switch request.path {
            case "/healthz":
                let health = HealthStatus(
                    uptimeSeconds: Int(Date().timeIntervalSince(startedAt)), chip: SystemInfo.chipName, webRoot: webRoot.path)
                return .json(200, Array((try? encoder.encode(health)) ?? Data()))
            case "/api/live":
                return .json(200, Array((try? encoder.encode(dmx.snapshot())) ?? Data()))
            case "/api/login":
                guard request.method == "POST" else { return HTTPResponse(status: 405, headers: [HTTPHeader("Allow", "POST")]) }
                guard let body = try? JSONDecoder().decode(JSONValue.self, from: Data(request.body)),
                    let role = body["role"]?.string.flatMap(Role.init(rawValue:))
                else { return .text(400, "expected {\"role\": …, \"password\": …}") }
                do {
                    let cookie = try auth.login(role: role, password: body["password"]?.string ?? "", from: request.remoteAddress)
                    return HTTPResponse(status: 204, headers: [HTTPHeader("Set-Cookie", RoleAuth.cookieHeader(cookie))])
                } catch RoleAuth.LoginError.rateLimited {
                    return .text(429, "too many attempts; wait a minute")
                } catch {
                    return .text(401, "wrong password")
                }
            case "/api/logout":
                guard request.method == "POST" else { return HTTPResponse(status: 405, headers: [HTTPHeader("Allow", "POST")]) }
                if let cookie = RoleAuth.cookie(in: request) { auth.logout(cookie: cookie) }
                return HTTPResponse(status: 204, headers: [HTTPHeader("Set-Cookie", "\(RoleAuth.cookieName)=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0")])
            case "/api/session":
                let role = auth.role(forCookie: RoleAuth.cookie(in: request))
                let session: JSONValue = [
                    "role": role.map { .string($0.rawValue) } ?? .null,
                    "open": .array(Role.allCases.filter { auth.isOpen($0) }.map { .string($0.rawValue) }),
                ]
                return .json(200, Array(store.encode(session).utf8))
            case "/api/patch":
                return .json(200, Array((try? encoder.encode(patch)) ?? Data()))
            case "/api/gdtf":
                return HTTPResponse(
                    status: 200,
                    headers: [HTTPHeader("Content-Type", "application/zip"), HTTPHeader("Content-Disposition", "attachment; filename=\"Lanthorn.gdtf\"")],
                    body: GDTFExporter.gdtf())
            case "/api/channel-map.md":
                return .text(200, ChannelMapDocument.markdown())
            case "/api/library":
                return .json(200, Array((try? encoder.encode(library.snapshot)) ?? Data()))
            case "/api/library/rescan":
                library.rescan()
                return .text(200, "rescanned")
            case let path where path.hasPrefix("/api/thumbnail/"):
                // thumbnail file names are hashes written by the engine itself: no path component may escape the cache
                let name = String(path.dropFirst("/api/thumbnail/".count))
                guard !name.contains("/"), !name.contains(".."), name.hasSuffix(".jpg"),
                    let data = try? Data(contentsOf: thumbnailer.directory.appending(path: name))
                else { return .text(404, "no thumbnail") }
                return HTTPResponse(status: 200, headers: [HTTPHeader("Content-Type", "image/jpeg"), HTTPHeader("Cache-Control", "max-age=86400")], body: Array(data))
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
        // large uploads stream to _incoming/ before the route runs
        server.uploadSink = { request in ingestAPI.uploadTarget(for: request) }
        server.uploadRoute = { request, file in ingestAPI.handle(request, uploadedFile: file) }
        server.upgradeRoute = { request in stateServer.upgrade(request) }
        server.start()
        self.server = server
    }

    /// Control queue: re-applies the patch when it changed and schedules the autosave (2 s after the last change).
    private func projectChanged(_ document: JSONValue) {
        if let dmx, let patch = ProjectDocument.patch(from: document), patch != dmx.currentPatch { dmx.setPatch(patch) }
        autosave?.cancel()
        let logger = logger
        let work = DispatchWorkItem {
            do { try ProjectDocument.save(document, to: AppPaths.projectFile) } catch { logger.error("autosave failed", metadata: ["error": "\(error)"]) }
        }
        autosave = work
        feedQueue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Live document at 10 Hz and the DMX monitor stream at 20 Hz, both off the render and DMX threads.
    private func startFeeds() {
        let live = DispatchSource.makeTimerSource(queue: feedQueue)
        live.schedule(deadline: .now() + 0.1, repeating: 0.1)
        live.setEventHandler { [weak self] in self?.publishLive() }
        live.resume()
        liveTimer = live
        let dmxStream = DispatchSource.makeTimerSource(queue: feedQueue)
        dmxStream.schedule(deadline: .now() + 0.05, repeating: 0.05)
        dmxStream.setEventHandler { [weak self] in self?.streamDMX() }
        dmxStream.resume()
        dmxTimer = dmxStream
    }

    private func publishLive() {
        guard let dmx, let store, let auth, let ingest, let library else { return }
        let summary = metrics.summary(seconds: 1, now: CACurrentMediaTime())
        func ms(_ v: Double) -> JSONValue { .number((v * 100).rounded() / 100) }
        let snapshot = library.snapshot
        let live: JSONValue = [
            "engine": [
                "version": .string(LanthornVersion.string), "chip": .string(SystemInfo.chipName),
                "uptimeSeconds": .number(Date().timeIntervalSince(startedAt).rounded()), "rendering": .bool(render != nil),
            ],
            "metrics": [
                "frames": .number(Double(summary.frames)), "missed": .number(Double(summary.missed)), "late": .number(Double(summary.late)),
                "textureMisses": .number(Double(summary.textureMisses)), "cpuP50": ms(summary.cpuP50), "cpuP99": ms(summary.cpuP99),
                "gpuP50": ms(summary.gpuP50), "gpuP99": ms(summary.gpuP99), "dmxP99": ms(summary.dmxP99),
            ],
            "dmx": (try? JSONValue(encoding: dmx.snapshot())) ?? [:],
            "ingest": (try? JSONValue(encoding: ingest.jobs)) ?? [],
            "library": [
                "root": .string(snapshot.root), "rootExists": .bool(snapshot.rootExists), "folders": .number(Double(snapshot.folders.count)),
                "fileCount": .number(Double(snapshot.fileCount)), "invalidCount": .number(Double(snapshot.invalidCount)),
            ],
            "clients": ["count": .number(Double(store.clientCount)), "lagging": .number(Double(store.laggingClients))],
            "security": ["webUIOpen": .bool(auth.isOpen(.programmer))],
        ]
        store.updateLive(live)
    }

    private func streamDMX() {
        guard let dmx, let stateServer else { return }
        var slots: [String: [UInt8]] = [:]
        for (connection, stream, universe) in stateServer.dmxSubscriptions() {
            if slots[universe] == nil {
                guard let id = UniverseID(parsing: universe), let data = dmx.slots(for: id) else { continue }
                slots[universe] = data
            }
            _ = connection.send(stream: stream, kind: .dmx, payload: slots[universe]!)
        }
    }

    public func stop() {
        liveTimer?.cancel()
        dmxTimer?.cancel()
        if let autosave, !autosave.isCancelled {
            autosave.cancel()
            autosave.perform()
        }
        server?.stop()
        ingest?.stop()
        library?.stop()
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
