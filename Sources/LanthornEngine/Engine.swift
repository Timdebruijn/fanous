// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import Foundation
import LanthornCore
import Logging
import QuartzCore
import Synchronization

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
    private var coordinator: OutputCoordinator?
    private var displayManager: DisplayManager?
    private let displays = Mutex<[DisplayInfo]>([])
    private let outputStatus = Mutex<[OutputStatus]>([])
    private var lastOutputs: [OutputConfig] = []
    private var lastClockMaster: Int?
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
        // The standard patch sized to the scene until projects exist; the project document can change it (Phase 5).
        let layerCount = options.scene?.layerCount ?? 8
        let patch = Patch.standard(layers: layerCount, outputs: 4)
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

        var sceneWithOutputs = options.scene
        sceneWithOutputs?.managedOutputs = true  // the coordinator below owns displays and drivers (DESIGN.md §9.6)
        if let scene = sceneWithOutputs {
            let service = try MainActor.assumeIsolated {
                try RenderService(scene: scene, context: context, parameters: dmx.snapshots, metrics: metrics, logger: logger)
            }
            service.loader.resolver = { key in library.resolve(key) }
            render = service
        }

        // Phase 5: roles, the project and live documents and the WebSocket state server (DESIGN.md §11).
        let auth = RoleAuth(settingsURL: AppPaths.settingsFile, shellTokenURL: AppPaths.shellTokenFile, logger: logger)
        let project =
            ProjectDocument.load(from: AppPaths.projectFile, canvas: (options.scene?.canvasWidth ?? 1920, options.scene?.canvasHeight ?? 1080))
            ?? ProjectDocument.initial(
                patch: patch, layerCount: layerCount, libraryRoot: libraryRoot.path, policy: options.scene?.policy ?? .dmx,
                canvas: (options.scene?.canvasWidth ?? 1920, options.scene?.canvasHeight ?? 1080))
        if let loaded = ProjectDocument.effectivePatch(from: project), loaded != patch { dmx.setPatch(loaded) }
        let store = StateStore(project: project, logger: logger)
        ProjectDocument.registerCommands(on: store, auth: auth)
        store.onProjectChanged = { [weak self] document in self?.projectChanged(document) }
        let caps: JSONValue = [
            "schema": .number(Double(StateServer.schema)), "version": .string(LanthornVersion.string), "chip": .string(SystemInfo.chipName),
            "maxLayers": 32, "fps": .number(fps),
        ]
        let stateServer = StateServer(store: store, auth: auth, caps: caps, logger: logger)
        if let render {
            // 640×360 at 30 fps (DESIGN.md §11.3 default), on the compositor's own command buffer
            let height = 640 * render.scene.canvasHeight / max(1, render.scene.canvasWidth)
            let preview = try PreviewStreamer(context: context, width: 640, height: max(2, height), fps: min(30, fps), canvasFPS: fps, parameters: dmx.snapshots, logger: logger)
            render.compositor.previewTap = { canvas, commandBuffer, target in preview.tap(canvas: canvas, commandBuffer: commandBuffer, target: target) }
            stateServer.preview = preview
            let compiler = try OutputCompiler(device: context.device)
            stateServer.previewTarget = { [weak self] target in
                guard let self else { return false }
                if target == "canvas" {
                    preview.outputSet = nil
                    return true
                }
                let outputs = self.store?.project.outputsConfig ?? []
                guard target.hasPrefix("output:"), let id = Int(target.dropFirst(7)), let output = outputs.first(where: { $0.id == id }) else { return false }
                return self.previewOutput(output, in: outputs, compiler: compiler, preview: preview)
            }

            // Displays and output windows (DESIGN.md §9.6); the render service starts after the coordinator exists.
            let coordinator = try MainActor.assumeIsolated { () throws -> OutputCoordinator in
                let coordinator = try OutputCoordinator(compositor: render.compositor, context: context, fps: fps, displays: DisplayManager.current(), logger: logger)
                displays.withLock { $0 = coordinator.connectedDisplays }
                coordinator.onStatus = { [weak self] statuses in self?.outputStatus.withLock { $0 = statuses } }
                let manager = DisplayManager(logger: logger)
                manager.onChange = { [weak self] list in
                    self?.displays.withLock { $0 = list }
                    coordinator.displaysChanged(list)
                }
                manager.start()
                self.displayManager = manager
                // a scene "display" index on first start becomes a bound output in the project
                if ProjectDocument.outputs(from: project).isEmpty, let index = options.scene?.display {
                    let screens = NSScreen.screens
                    if index < screens.count, let number = (screens[index].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                        let display = coordinator.connectedDisplays.first(where: { $0.id == number })
                    {
                        _ = store.execute("output.add", args: ["display": ["uuid": .string(display.uuid), "name": .string(display.name)]], role: .programmer)
                    }
                }
                return coordinator
            }
            self.coordinator = coordinator
            let outputs = ProjectDocument.outputs(from: store.project)
            let clockMaster = ProjectDocument.canvases(from: store.project).first?.clockMaster
            lastOutputs = outputs
            lastClockMaster = clockMaster
            let log = logger
            Task { @MainActor in
                do { try await render.start() } catch { log.error("render start failed", metadata: ["error": "\(error)"]) }
                coordinator.apply(outputs: outputs, clockMaster: clockMaster)
            }
        }
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
        /// REST calls that change state need the programmer role: the session cookie, the shell token as a bearer, or an open role.
        @Sendable func programmerAllowed(_ request: HTTPRequest) -> Bool {
            let bearer = request.header("Authorization").flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
            let sessionRole = auth.role(forToken: bearer) ?? auth.role(forCookie: RoleAuth.cookie(in: request))
            return auth.grant(requested: .programmer, sessionRole: sessionRole) == .programmer
        }
        let server = try HTTPSServer(port: options.port, identity: identity, webRoot: options.webRoot, logger: logger) { request in
            if request.path.hasPrefix("/api/ingest") || request.path.hasPrefix("/api/upload/") {
                if request.method != "GET", !programmerAllowed(request) { return .text(403, "programmer role required") }
                return ingestAPI.handle(request, uploadedFile: nil)
            }
            if request.path == "/api/library/rescan" {
                // any role: it only re-reads the disk
                library.rescan()
                return .text(200, "rescanned")
            }
            if request.path == "/api/library/folder" {
                // POST {"number": N, "name": "…"} creates NNN_name under the root (and the root itself)
                guard request.method == "POST" else { return HTTPResponse(status: 405, headers: [HTTPHeader("Allow", "POST")]) }
                guard programmerAllowed(request) else { return .text(403, "programmer role required") }
                guard let body = try? JSONDecoder().decode(JSONValue.self, from: Data(request.body)), let number = body["number"]?.int, (1...255).contains(number),
                    let name = body["name"]?.string, !name.trimmingCharacters(in: .whitespaces).isEmpty
                else { return .text(400, "expected {\"number\": 1–255, \"name\": …}") }
                if library.snapshot.folders.contains(where: { $0.number == number }) { return .text(409, "folder \(number) exists") }
                try? FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
                guard let url = library.folderURL(number: number, createAs: name) else { return .text(500, "cannot create the folder") }
                library.rescan()
                return .text(200, url.lastPathComponent)
            }
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
            case "/api/channel-map.json":
                return .json(200, Array(store.encode(ChannelMapDocument.json()).utf8))
            case "/api/library":
                return .json(200, Array((try? encoder.encode(library.snapshot)) ?? Data()))
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
        // large uploads stream to _incoming/ before the route runs (role checked before the body is accepted)
        server.uploadSink = { request in programmerAllowed(request) ? ingestAPI.uploadTarget(for: request) : nil }
        server.uploadRoute = { request, file in ingestAPI.handle(request, uploadedFile: file) }
        server.upgradeRoute = { request in stateServer.upgrade(request) }
        server.start()
        self.server = server
    }

    /// Compiles one output for the preview size; overlaps and feathers scale with the preview.
    /// `outputs` is passed in: this runs on the control queue from `projectChanged`, where `store.project` would deadlock.
    private func previewOutput(_ output: OutputConfig, in outputs: [OutputConfig], compiler: OutputCompiler, preview: PreviewStreamer) -> Bool {
        var scaled = output
        let region = output.region ?? displays.withLock { list in
            list.first { $0.uuid == output.display?.uuid }.map { PixelRect(x: 0, y: 0, w: $0.pixelWidth, h: $0.pixelHeight) }
        } ?? PixelRect(x: 0, y: 0, w: 1920, h: 1080)
        let factor = Double(preview.width) / Double(max(1, region.w))
        scaled.region = nil
        for edge in [\OutputConfig.blend.left, \.blend.right, \.blend.top, \.blend.bottom] { scaled[keyPath: edge].overlap *= factor }
        scaled.blend.liftFeather *= factor
        for i in scaled.slices.indices { scaled.slices[i].mask?.feather *= factor }
        let index = (outputs.firstIndex { $0.id == output.id } ?? 0) + 1
        do {
            preview.outputSet = OutputSet(plans: [try compiler.compile(scaled, index: index, drawable: (preview.width, preview.height))])
            return true
        } catch {
            logger.error("preview output compile failed", metadata: ["output": "\(output.id)", "error": "\(error)"])
            return false
        }
    }

    /// Control queue: re-applies the patch when it changed and schedules the autosave (2 s after the last change).
    private func projectChanged(_ document: JSONValue) {
        if let dmx, let patch = ProjectDocument.effectivePatch(from: document), patch != dmx.currentPatch { dmx.setPatch(patch) }
        let outputs = ProjectDocument.outputs(from: document)
        let clockMaster = ProjectDocument.canvases(from: document).first?.clockMaster
        if outputs != lastOutputs || clockMaster != lastClockMaster, let coordinator {
            lastOutputs = outputs
            lastClockMaster = clockMaster
            Task { @MainActor in coordinator.apply(outputs: outputs, clockMaster: clockMaster) }
            // the preview follows its output when that one changed
            if let preview = stateServer?.preview, preview.outputSet != nil, let id = preview.outputSet?.plans.first?.id, let output = outputs.first(where: { $0.id == id }),
                let compiler = try? OutputCompiler(device: render?.context.device ?? MTLCreateSystemDefaultDevice()!)
            {
                _ = previewOutput(output, in: outputs, compiler: compiler, preview: preview)
            }
        }
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
                "scannedAt": .number(snapshot.scannedAt),
            ],
            "layers": .array(
                (render?.layers ?? []).map { layer in
                    let s = layer.mediaStatus.withLock { $0 }
                    return [
                        "index": .number(Double(layer.index + 1)), "folder": .number(Double(s.folder)), "file": .number(Double(s.file)),
                        "name": s.name.map { .string($0) } ?? .null, "kind": .string(s.kind), "codec": .string(s.codec),
                        "width": .number(Double(s.width)), "height": .number(Double(s.height)), "fps": .number(s.fps),
                        "frames": .number(Double(s.frames)), "frame": .number(Double(layer.currentFrame)), "error": s.error.map { .string($0) } ?? .null,
                    ]
                }),
            "clients": ["count": .number(Double(store.clientCount)), "lagging": .number(Double(store.laggingClients))],
            "displays": .array(
                displays.withLock { $0 }.map { d in
                    [
                        "uuid": .string(d.uuid), "name": .string(d.name), "width": .number(Double(d.pixelWidth)), "height": .number(Double(d.pixelHeight)),
                        "hz": .number(d.hz), "main": .bool(d.isMain), "builtin": .bool(d.isBuiltin),
                        "modes": .array(d.modes.prefix(24).map { ["width": .number(Double($0.width)), "height": .number(Double($0.height)), "hz": .number($0.hz)] }),
                    ]
                }),
            "outputs": .array(
                outputStatus.withLock { $0 }.map { s in
                    [
                        "id": .number(Double(s.id)), "state": .string(s.state.rawValue), "display": s.display.map { .string($0) } ?? .null,
                        "width": .number(Double(s.width)), "height": .number(Double(s.height)), "hz": .number(s.hz), "master": .bool(s.isMaster),
                    ]
                }),
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
        if let coordinator, let displayManager {
            MainActor.assumeIsolated {
                displayManager.stop()
                coordinator.stop()
            }
        }
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
