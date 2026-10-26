// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import Foundation
import FanousCore
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
    var version = FanousVersion.string
    var uptimeSeconds: Int
    var chip: String
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
    /// Main actor only: desired display modes in show mode (DESIGN.md §9.6).
    private var modeSwitcher: DisplayModeSwitcher?
    private var lastModeConflicts: [Int: Int] = [:]
    private var unlockObservers: [NSObjectProtocol] = []
    /// Output id → what the status line and readiness say about its display mode; written on the main actor.
    private let modeChecks = Mutex<[Int: DisplayModeMatching.Check]>([:])
    private var lastOutputs: [OutputConfig] = []
    private var lastClockMaster: Int?
    private var lastLayerCanvas: [Int] = []
    /// What the project assigns to canvases, as last seen by Control; applied (main actor) against the canvases that
    /// actually render, so a switch deferred in show mode or a failed one never leaves layers or slices on nothing.
    private struct CanvasUse: Sendable {
        var outputs: [OutputConfig] = []
        var clockMaster: Int?
        var layers: [Int] = []
        var canvases: Set<Int> = [1]
    }
    private let canvasUse = Mutex(CanvasUse())
    /// B31: keeps the rendered canvas in step with the project's.
    private var canvasSwitch: CanvasSwitch?
    // Phase 7: show control
    private let timecodeClock = TimecodeClock()
    private var ltc: LTCInput?
    private var mtc: MTCInput?
    private var lastTimecodeSettings = ShowCommands.TimecodeSettings()
    private var cues: CueRunner?
    private var lastCues = CueList()
    private let showMode: ShowModeController
    private let readiness = Mutex<(items: [ReadinessItem], acknowledged: Set<String>, checkedAt: Double)>(([], [], 0))
    private var readinessTimer: DispatchSourceTimer?
    /// When show mode came back by itself after an unclean stop (live `show.resumedAt`); cleared when show mode is left.
    private let showResumedAt = Mutex<Double?>(nil)
    /// The show lock as last written to disk: a change is saved at once, not with the 2 s autosave.
    private let savedShowLock = Mutex<Bool?>(nil)
    /// Main actor: after a resume the first display sync runs readiness at once instead of after 30 s.
    private var readinessOnNextSync = false
    private let oscLog = Mutex<[JSONValue]>([])
    private var lastPolicy: SourcePolicy?
    private var lastLibraryRootWarning: String?
    private var citp: CITPServer?
    private var stateServer: StateServer?
    private var liveTimer: DispatchSourceTimer?
    private var dmxTimer: DispatchSourceTimer?
    private var autosave: DispatchWorkItem?
    private let feedQueue = DispatchQueue(label: "org.fanous.feed", qos: .utility)
    public let metrics = MetricsRing()

    /// The command registry as `fanousd protocol-dts` sees it: no engine needed.
    public static func commandSpecs() -> [CommandSpec] {
        let logger = Logger(label: "protocol")
        let store = StateStore(project: [:], logger: logger)
        ProjectDocument.registerCommands(on: store, auth: RoleAuth(settingsURL: nil, shellTokenURL: nil, logger: logger))
        ShowCommands.register(on: store, hooks: ShowCommands.Hooks(go: {}, back: {}, goto: { _ in }, showMode: { _ in nil }, acknowledge: { _ in }, runReadiness: {}))
        ControlCommands.register(on: store, hooks: ControlCommands.Hooks(set: { _, _, _ in }, release: { _ in }, keep: { _ in }))
        return store.commandSpecs
    }

    public init(options: EngineOptions, logger: Logger) {
        self.options = options
        self.logger = logger
        showMode = ShowModeController(logger: logger, stateURL: AppPaths.showStateFile)
    }

    public func start() throws {
        try AppPaths.ensureDirectories()
        logger.info(
            "fanousd starting",
            metadata: [
                "version": "\(FanousVersion.string)", "chip": "\(SystemInfo.chipName)",
                "memoryGB": "\(SystemInfo.physicalMemoryBytes / 1_073_741_824)", "os": "\(SystemInfo.osVersion)",
                "webRoot": "\(options.webRoot.path)",
            ])
        // DESIGN.md §14: show mode left on by an unclean end or kept for Engine › Restart Engine resumes; decided
        // first so ingest never starts in a show.
        var resumeShow: ShowModeState?
        switch ShowModeState.decide(ShowModeState.load(from: AppPaths.showStateFile), boot: ShowModeState.bootTime, now: Date().timeIntervalSince1970) {
        case .resume(let state): resumeShow = state
        case .stale:
            logger.warning("stale show state ignored")
            try? FileManager.default.removeItem(at: AppPaths.showStateFile)
        case .none: break
        }
        let host = SystemInfo.hostName
        var hostnames = ["localhost", host]
        if !host.hasSuffix(".local") { hostnames.append(host + ".local") }
        let identity = try TLSIdentity.loadOrCreate(
            directory: AppPaths.tls, hostnames: hostnames, ipAddresses: ["127.0.0.1", "::1"] + SystemInfo.ipv4Addresses,
            logger: logger)
        tlsFingerprint = identity.fingerprintSHA256
        // The project document comes first: without a scene file (the bundled agent) it is the source of the layer
        // count, canvas, source policy and library root (DESIGN.md §2.4); a scene file (development, bench) wins,
        // and its canvas is mirrored into the project so the UI shows what renders.
        var loadedProject = ProjectDocument.load(from: AppPaths.projectFile)
        let startCanvas = Self.startCanvas(project: loadedProject, scene: options.scene)
        if options.scene != nil, var project = loadedProject {
            try? ProjectDocument.setCanvasFormat(startCanvas, in: &project)
            loadedProject = project
        }
        // every canvas of the project from the first tick (also after a restart in show mode, which defers switches)
        let startLayout = ProjectDocument.layout(from: loadedProject ?? .null, start: startCanvas)
        let canvasSwitch = CanvasSwitch(
            rendered: startLayout, isDeferred: { [weak self] in self?.showMode.isOn ?? false },
            apply: { [weak self] layout in
                guard let coordinator = self?.coordinator else { throw RenderError.pipeline("no compositor") }
                try coordinator.setCanvases(layout)
            },
            revert: { [weak self] rendered, error in self?.canvasSwitchFailed(keeping: rendered, error: error) })
        canvasSwitch.applied = { [weak self] format in self?.canvasSwitched(to: format) }
        self.canvasSwitch = canvasSwitch
        let layerCount = options.scene?.layerCount ?? loadedProject?["layerCount"]?.int ?? 8
        let patch = ProjectDocument.effectivePatch(from: loadedProject ?? .null) ?? Patch.standard(layers: layerCount, outputs: 4)
        let policy = options.scene?.policy ?? loadedProject?["policy"]?.string.flatMap(SourcePolicy.init(rawValue:)) ?? .dmx
        let dmx = DMXStore(patch: patch, logger: logger)
        if policy != .dmx {
            for entry in patch.entries { dmx.setPolicy(policy, for: entry.fixture) }
        }
        dmx.start()
        let artnet = ArtNetReceiver(store: dmx, logger: logger, nodeName: Attribution.projectName)
        try artnet.start()
        let sacn = SACNReceiver(store: dmx, logger: logger)
        try sacn.start(universes: Self.sacnUniverses(patch))
        let osc = OSCReceiver(store: dmx, logger: logger)
        try osc.start()
        self.dmx = dmx
        self.artnet = artnet
        self.sacn = sacn
        self.osc = osc

        // The library is always indexed (DESIGN.md §8); scenes may add explicit entries (Syphon inputs, test files).
        let context = try MetalContext()
        let libraryRoot = (options.scene?.library ?? loadedProject?["library"]?["root"]?.string).map { URL(fileURLWithPath: $0) } ?? AppPaths.defaultLibrary
        let library = LibraryIndex(root: libraryRoot, cacheDirectory: AppPaths.cache, logger: logger)
        let thumbnailer = Thumbnailer(context: context, directory: AppPaths.cache.appending(path: "thumbnails"), logger: logger)
        library.thumbnailer = { url, metadata, kind in thumbnailer.make(for: url, metadata: metadata, kind: kind) }
        library.start()
        self.library = library

        // Ingest queue (DESIGN.md §8.3): one job at a time at utility priority; yields while the compositor is busy.
        let ingest = IngestQueue(persistenceURL: AppPaths.ingestQueueFile, logger: logger)
        let metrics = self.metrics
        let fps = startCanvas.fps
        ingest.shouldYield = { [weak self] in
            let budget = 0.7 / (self?.canvasSwitch?.rendered.fps ?? fps) * 1e6
            return metrics.recent(seconds: 0.25, now: CACurrentMediaTime()).contains { Double($0.cpuMicros + $0.gpuMicros) > budget }
        }
        if resumeShow != nil { ingest.paused = true }  // DESIGN.md §14: before the first job can start
        ingest.start()
        self.ingest = ingest

        var sceneWithOutputs = options.scene ?? Self.defaultScene(canvas: startCanvas, layerCount: layerCount, policy: policy, library: libraryRoot)
        sceneWithOutputs.managedOutputs = true  // the coordinator below owns displays and drivers (DESIGN.md §9.6)
        do {
            let scene = sceneWithOutputs
            let service = try MainActor.assumeIsolated {
                try RenderService(scene: scene, context: context, parameters: dmx.snapshots, metrics: metrics, logger: logger)
            }
            service.loader.resolver = { key in library.resolve(key) }
            service.audioKeepRunning = { [weak self] in self?.showMode.isOn ?? false }
            if startLayout.canvases.count > 1 {
                // nothing ticks yet; on failure canvas 1 runs alone and takes the others' layers and slices meanwhile
                do {
                    try service.compositor.reconfigure(startLayout)
                } catch {
                    logger.error("canvases could not be made at start; canvas 1 runs alone", metadata: ["error": "\(error)"])
                    canvasSwitch.startFailed(rendering: .init(fps: startLayout.fps, canvases: [startLayout.canvases[0]]), error: "at start: \(error)")
                }
            }
            render = service
        }

        // Phase 5: roles, the project and live documents and the WebSocket state server (DESIGN.md §11).
        let auth = RoleAuth(settingsURL: AppPaths.settingsFile, shellTokenURL: AppPaths.shellTokenFile, logger: logger)
        let project = loadedProject ?? ProjectDocument.initial(patch: patch, layerCount: layerCount, libraryRoot: libraryRoot.path, policy: policy, canvas: startCanvas)
        let store = StateStore(project: project, logger: logger)
        ProjectDocument.registerCommands(on: store, auth: auth, showModeOn: { [weak self] in self?.showMode.isOn ?? false })
        // Phase 7: cues, timecode, show mode (DESIGN.md §14–15)
        let cues = CueRunner(dmx: dmx, logger: logger)
        cues.replace(list: ShowCommands.cueList(from: project))
        lastCues = ShowCommands.cueList(from: project)
        self.cues = cues
        timecodeClock.onFrame = { [weak self] timecode, _ in self?.cues?.timecode(timecode) }
        ControlCommands.register(on: store, hooks: ControlCommands.Hooks(set: { dmx.setUI($0, $1, raw: $2) }, release: { dmx.releaseUI($0) }, keep: { dmx.keepUI($0) }))
        ShowCommands.register(
            on: store,
            hooks: ShowCommands.Hooks(
                go: { cues.go() }, back: { cues.back() }, goto: { cues.goto($0) },
                showMode: { [weak self] on in self?.setShowMode(on) ?? nil },
                acknowledge: { [weak self] id in
                    // flag the stored items too, so the UI sees it now and not at the next 30 s run
                    self?.readiness.withLock { r in
                        r.acknowledged.insert(id)
                        for i in r.items.indices where r.items[i].id == id { r.items[i].acknowledged = true }
                    }
                    self?.publishReadiness()
                },
                runReadiness: { [weak self] in self?.runReadiness() }))
        // OSC: cue, show and timecode commands (DESIGN.md §15.3); the parameter ones stay on the DMX queue
        dmx.onCommand = { [weak self] command in
            guard let self, let store = self.store else { return }
            self.oscLog.withLock { log in
                log.append(["at": .number(Date().timeIntervalSince1970), "command": .string("\(command)")])
                if log.count > 50 { log.removeFirst(log.count - 50) }
            }
            switch command {
            case .cueGo: _ = store.execute("cue.go", role: .operator)
            case .cueBack: _ = store.execute("cue.back", role: .operator)
            case .cueGoto(let number): _ = store.execute("cue.goto", args: ["number": .number(number)], role: .operator)
            case .showLock(let on): _ = store.execute(on ? "show.lock" : "show.unlock", role: .programmer)
            case .showMode(let on): _ = store.execute("show.mode", args: ["on": .bool(on)], role: .operator)
            case .timecodeEnable(let on): _ = store.execute("timecode.enable", args: ["on": .bool(on)], role: .operator)
            case .projectLoad: self.logger.warning("OSC project load is not available until project bundles exist (B23)")
            default: break
            }
        }
        showMode.onChange = { [weak self] on in
            guard let self else { return }
            self.ingest?.paused = on  // DESIGN.md §14: ingest paused in show mode
            if on { self.startReadinessTimer() } else { self.stopReadinessTimer() }
            if !on {
                self.showResumedAt.withLock { $0 = nil }
                self.canvasSwitch?.run()  // a canvas change deferred during show mode (B31)
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.coordinator?.setCursorHidden(on)
                    self?.syncDisplayModes()
                }
            }
        }
        // Back in show mode before the outputs and the display modes come up, so the first sync applies (keeps) the
        // show modes instead of restoring the ledger. Readiness runs at that sync and is published, but never refuses.
        if let resumeShow {
            let since = Date(timeIntervalSince1970: resumeShow.since)
            logger.warning(resumeShow.restart == true ? "show mode kept across a restart" : "show mode resumed after an unclean stop", metadata: ["since": "\(since)"])
            showResumedAt.withLock { $0 = Date().timeIntervalSince1970 }
            readinessOnNextSync = true
            showMode.enter(since: since)
        }
        savedShowLock.withLock { $0 = project["showLock"]?.bool ?? false }
        applyTimecodeSettings(ShowCommands.timecodeSettings(from: project))
        store.onProjectChanged = { [weak self] document in self?.projectChanged(document) }
        let caps: JSONValue = [
            "schema": .number(Double(StateServer.schema)), "version": .string(FanousVersion.string), "chip": .string(SystemInfo.chipName),
            "maxLayers": 32, "fps": .number(fps),
        ]
        let stateServer = StateServer(store: store, auth: auth, caps: caps, logger: logger)
        render?.compositor.timecode = timecodeClock
        if let render {
            // 640 wide in the canvas aspect at 30 fps (DESIGN.md §11.3 default), on the compositor's own command buffer;
            // made again from the rendered canvas when it changes (B31)
            let makePreview: @Sendable () throws -> PreviewStreamer = { [weak self, parameters = dmx.snapshots, logger] in
                let canvas = self?.canvasSwitch?.rendered.first ?? startCanvas
                let height = max(2, 640 * canvas.height / max(1, canvas.width))
                return try PreviewStreamer(context: context, width: 640, height: height, fps: min(30, canvas.fps), canvasFPS: canvas.fps, parameters: parameters, logger: logger)
            }
            // one streamer per target that has subscribers (canvas, canvas:<id>, output:<id>, layer:<n>); the canvas one also serves CITP
            let preview = PreviewHub(canvas: try makePreview(), make: makePreview)
            preview.makeCanvas = { [weak self, parameters = dmx.snapshots, logger] id in
                guard let layout = self?.canvasSwitch?.rendered, let canvas = layout.canvases.first(where: { $0.id == id }) else { return nil }
                let height = max(2, 640 * canvas.height / max(1, canvas.width))
                return try PreviewStreamer(context: context, width: 640, height: height, fps: min(30, layout.fps), canvasFPS: layout.fps, parameters: parameters, logger: logger)
            }
            preview.canvasTexture = { [unowned compositor = render.compositor] id in compositor.tickCanvas(id) }
            preview.canvasOfLayer = { [weak self] target in
                guard let self, let n = Int(target.dropFirst(6)), n >= 1 else { return nil }
                let layers = self.effectiveCanvasUse().layers
                return n <= layers.count ? layers[n - 1] : 1
            }
            render.compositor.previewTap = { canvas, commandBuffer, target in preview.tap(canvas: canvas, commandBuffer: commandBuffer, target: target) }
            // no GPU work for a canvas nobody sees: no output window, preview, Syphon client or CITP stream
            render.compositor.skipsIdleWork = true
            render.compositor.previewWanted = { preview.wantsFrames }
            stateServer.preview = preview
            let compiler = try OutputCompiler(device: context.device)
            preview.configure = { [weak self, compositor = render.compositor] target, streamer in
                guard let self else { return false }
                // layer:<n> (1-based, within the project's layers): that layer alone, drawn after the canvas pass
                if target.hasPrefix("layer:") {
                    guard let index = PreviewHub.layerIndex(of: target, layerCount: self.store?.project["layerCount"]?.int ?? 0) else { return false }
                    return (try? streamer.showLayer(index, of: compositor)) != nil
                }
                let outputs = self.effectiveCanvasUse().outputs  // as rendered (slices waiting for a canvas show canvas 1)
                guard target.hasPrefix("output:"), let id = Int(target.dropFirst(7)), let output = outputs.first(where: { $0.id == id }) else { return false }
                return self.previewOutput(output, in: outputs, compiler: compiler, preview: streamer)
            }

            // CITP/MSEX (DESIGN.md §16.1): peer location, layer status, library, thumbnails, streaming frames
        let citp = CITPServer(
            name: SystemInfo.hostName, uuid: Self.installUUID(),
            providers: CITPServer.Providers(
                layers: { [weak self] in self?.citpLayers() ?? [] },
                library: { library.snapshot },
                thumbnail: { name in (try? Data(contentsOf: thumbnailer.directory.appending(path: name))).map(Array.init) },
                frame: { [weak self] in self?.stateServer?.preview?.canvas.latestJPEG.withLock { $0 } ?? nil }), logger: logger)
        do {
            try citp.start()
            preview.canvas.externalJPEGWanted = { citp.wantsFrames.load(ordering: .relaxed) }  // CITP always streams the canvas
            self.citp = citp
        } catch {
            logger.error("CITP start failed", metadata: ["error": "\(error)"])
        }

        // Displays and output windows (DESIGN.md §9.6); the render service starts after the coordinator exists.
            let coordinator = try MainActor.assumeIsolated { () throws -> OutputCoordinator in
                let coordinator = try OutputCoordinator(compositor: render.compositor, context: context, fps: fps, displays: DisplayManager.current(), logger: logger)
                displays.withLock { $0 = coordinator.connectedDisplays }
                coordinator.onStatus = { [weak self] statuses in
                    self?.outputStatus.withLock { $0 = statuses }
                    // after the rebind returned: a mode switch reconfigures the displays and rebinds again
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncDisplayModes() } }
                }
                let switcher = DisplayModeSwitcher(logger: logger, ledgerURL: AppPaths.displayModesFile)
                switcher.onResult = { [weak self] in self?.modeSwitched() }
                modeSwitcher = switcher
                observeUnlock()
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
            lastLayerCanvas = Self.layerCanvas(project: store.project, layers: render.layers.count)
            let projectCanvases = Set(ProjectDocument.canvases(from: store.project).map(\.id))
            canvasUse.withLock { $0 = CanvasUse(outputs: outputs, clockMaster: clockMaster, layers: lastLayerCanvas, canvases: projectCanvases) }
            let log = logger
            render.compositor.layerCanvas = effectiveCanvasUse().layers
            Task { @MainActor in
                do { try await render.start() } catch { log.error("render start failed", metadata: ["error": "\(error)"]) }
                self.applyCanvasUse()
            }
        }
        self.auth = auth
        self.store = store
        stateServer.onDMXActive = { [weak self] active in self?.setDMXStream(active: active) }
        self.stateServer = stateServer
        startFeeds()

        let startedAt = self.startedAt
        let webRoot = options.webRoot
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let ingestAPI = IngestAPI(library: library, queue: ingest, encoder: encoder, logger: logger)
        /// REST calls that change state need the programmer role: the session cookie, the shell token as a bearer, or an open role.
        @Sendable func allowed(_ role: Role, _ request: HTTPRequest) -> Bool {
            let bearer = request.header("Authorization").flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
            let sessionRole = auth.role(forToken: bearer) ?? auth.role(forCookie: RoleAuth.cookie(in: request))
            return auth.grant(requested: role, sessionRole: sessionRole) == role
        }
        @Sendable func programmerAllowed(_ request: HTTPRequest) -> Bool { allowed(.programmer, request) }
        let server = try HTTPSServer(port: options.port, identity: identity, webRoot: options.webRoot, logger: logger) { request in
            if request.path.hasPrefix("/api/ingest") || request.path.hasPrefix("/api/upload/") {
                if request.method != "GET", !programmerAllowed(request) { return .text(403, "programmer role required") }
                if request.method == "GET", !allowed(.operator, request) { return .text(403, "operator role required") }  // job lists carry file paths
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
                    uptimeSeconds: Int(Date().timeIntervalSince(startedAt)), chip: SystemInfo.chipName)
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
            case "/metrics":
                // DESIGN.md §13: the current 1-second summary as JSON for external monitoring
                let s = metrics.summary(seconds: 1, now: CACurrentMediaTime())
                var m: [String: JSONValue] = [
                    "frames": .number(Double(s.frames)), "missed": .number(Double(s.missed)), "late": .number(Double(s.late)), "textureMisses": .number(Double(s.textureMisses)),
                    "cpuMsP50": .number(s.cpuP50), "cpuMsP99": .number(s.cpuP99), "cpuMsMax": .number(s.cpuMax), "gpuMsP50": .number(s.gpuP50), "gpuMsP99": .number(s.gpuP99),
                    "gpuMsMax": .number(s.gpuMax), "dmxToPhotonMsP50": .number(s.dmxP50), "dmxToPhotonMsP99": .number(s.dmxP99), "dmxSamples": .number(Double(s.dmxSamples)),
                    "windowSeconds": .number(s.seconds), "clients": .number(Double(store.clientCount)), "lagging": .number(Double(store.laggingClients)),
                    "showMode": .bool(self.showMode.isOn), "uptimeSeconds": .number(Date().timeIntervalSince(startedAt).rounded()),
                    "totalFrames": .number(Double(metrics.totalFrames.load(ordering: .relaxed))), "totalMissed": .number(Double(metrics.totalMissed.load(ordering: .relaxed))),
                    "totalLate": .number(Double(metrics.totalLate.load(ordering: .relaxed))), "pid": .number(Double(getpid())),
                ]
                if let audio = self.render?.mixer?.statistics {
                    m["audio"] = ["callbacks": .number(Double(audio.callbacks)), "underruns": .number(Double(audio.underruns)), "corrections": .number(Double(audio.corrections)), "maxDriftMs": .number(audio.maxDriftMillis)]
                }
                if let preview = stateServer.preview {
                    m["preview"] = ["framesIn": .number(Double(preview.framesIn)), "framesOut": .number(Double(preview.framesOut)), "skipped": .number(Double(preview.skipped))]
                }
                return .json(200, Array(store.encode(.object(m)).utf8))
            case "/api/logs":
                guard programmerAllowed(request) else { return .text(403, "programmer role required") }
                // the last 64 KB of the engine log (System › Logs); `?download=1` sends the whole file
                let file = AppPaths.logs.appending(path: "fanousd.log")
                guard let handle = try? FileHandle(forReadingFrom: file) else { return .text(404, "no log file") }
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                let download = request.target.contains("download=1")
                let from = download ? 0 : max(0, Int(size) - 65_536)
                try? handle.seek(toOffset: UInt64(from))
                let data = (try? handle.readToEnd()) ?? Data()
                return HTTPResponse(
                    status: 200,
                    headers: [HTTPHeader("Content-Type", "text/plain; charset=utf-8")] + (download ? [HTTPHeader("Content-Disposition", "attachment; filename=\"fanousd.log\"")] : []),
                    body: Array(data))
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
                    headers: [HTTPHeader("Content-Type", "application/zip"), HTTPHeader("Content-Disposition", "attachment; filename=\"Fanous.gdtf\"")],
                    body: GDTFExporter.gdtf())
            case "/api/channel-map.md":
                return .text(200, ChannelMapDocument.markdown())
            case "/api/channel-map.json":
                return .json(200, Array(store.encode(ChannelMapDocument.json()).utf8))
            case "/api/library":
                // below operator: no absolute paths (B25); the UI keys files by `path`, which stays unique relative to the root
                let snapshot = allowed(.operator, request) ? library.snapshot : library.snapshot.redacted()
                return .json(200, Array((try? encoder.encode(snapshot)) ?? Data()))
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
        server.bonjour(name: SystemInfo.hostName)
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
        let factorY = Double(preview.height) / Double(max(1, region.h))
        for edge in [\OutputConfig.blend.left, \.blend.right] { scaled[keyPath: edge].overlap *= factor }
        for edge in [\OutputConfig.blend.top, \.blend.bottom] { scaled[keyPath: edge].overlap *= factorY }
        scaled.blend.liftFeather *= factor
        for i in scaled.slices.indices { scaled.slices[i].mask?.feather *= factor }
        let index = output.id  // fixture number and ID pattern follow the output's id
        do {
            preview.outputSet = OutputSet(plans: [try compiler.compile(scaled, index: index, drawable: (preview.width, preview.height))])
            return true
        } catch {
            logger.error("preview output compile failed", metadata: ["output": "\(output.id)", "error": "\(error)"])
            return false
        }
    }

    // MARK: Show control

    /// A stable per-install UUID for CITP (MSEX 1.2 server UUID), kept next to the shell token.
    static func installUUID() -> String {
        let file = AppPaths.applicationSupport.appending(path: "install-uuid")
        if let existing = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), existing.count == 36 { return existing }
        let uuid = UUID().uuidString
        try? Data(uuid.utf8).write(to: file, options: .atomic)
        return uuid
    }

    private func citpLayers() -> [CITPServer.LayerInfo] {
        guard let render, let dmx else { return [] }
        let snapshot = dmx.snapshots.read()
        return render.layers.map { layer in
            let s = layer.mediaStatus.withLock { $0 }
            let p = layer.index < snapshot.layers.count ? snapshot.layers[layer.index] : LayerParameters()
            let fps = max(1.0, s.fps)
            var flags: UInt32 = 0
            if s.kind == "movie" && p.intensity > 0 && p.playMode != .freeze { flags |= LayerStatus.playing }
            if p.playMode.isReverse { flags |= LayerStatus.playbackReverse }
            if p.playMode == .loopForward || p.playMode == .loopReverse { flags |= LayerStatus.playbackLooping }
            if p.playMode == .bounce { flags |= LayerStatus.playbackBouncing }
            if p.playMode == .freeze { flags |= LayerStatus.paused }
            return CITPServer.LayerInfo(
                index: layer.index + 1, folder: s.folder, file: s.file, name: s.name ?? "", positionMs: UInt32(clamping: Int(Double(layer.currentFrame) * 1000 / fps)),
                lengthMs: UInt32(clamping: Int(Double(s.frames) * 1000 / fps)), fps: UInt8(clamping: Int(s.fps.rounded())), flags: flags)
        }
    }

    private func citpLive() -> JSONValue {
        guard let s = citp?.status.withLock({ $0 }) else { return [:] }
        return ["port": .number(Double(s.port)), "clients": .array(s.clients.map { .string($0) }), "streams": .number(Double(s.streams)), "multicast": .array([.string(CITPMulticast.address), .string(CITPMulticast.addressSince2014)])]
    }

    private func timecodeLive() -> JSONValue {
        let s = timecodeClock.current()
        return [
            "state": .string(s.state.rawValue), "source": .string(s.source), "value": .string(s.state == .off ? "--:--:--:--" : s.timecode.description),
            "rate": .string(s.rate.label), "frames": .number(Double(s.frameCount)), "seen": .number(Double(timecodeClock.framesSeen.load(ordering: .relaxed))),
            "error": ltc?.lastError.map { .string($0) } ?? .null, "device": .string(ltc?.deviceName ?? mtc?.connected.joined(separator: ", ") ?? ""),
        ]
    }

    private func cueLive() -> JSONValue {
        guard let s = cues?.status.withLock({ $0 }) else { return [:] }
        return [
            "current": s.current.map { .number($0) } ?? .null, "currentName": s.currentName.map { .string($0) } ?? .null,
            "next": s.next.map { .number($0) } ?? .null, "nextName": s.nextName.map { .string($0) } ?? .null, "fading": .bool(s.fading), "count": .number(Double(s.count)),
        ]
    }

    private func showLive() -> JSONValue {
        let r = readiness.withLock { $0 }
        return [
            "mode": .bool(showMode.isOn),
            "resumedAt": showResumedAt.withLock { $0 }.map { .number($0) } ?? .null,
            "checkedAt": .number(r.checkedAt),
            "ready": .bool(!r.items.contains { $0.blocks }),
            "readiness": .array(
                r.items.map {
                    ["id": .string($0.id), "title": .string($0.title), "state": .string($0.state.rawValue), "detail": .string($0.detail), "fix": .string($0.fix), "acknowledged": .bool($0.acknowledged)]
                }),
        ]
    }

    private func systemLive(addresses: [String]) -> JSONValue {
        let power = Readiness.powerState()
        let memory = Readiness.memoryHeadroom()
        let thermal = ProcessInfo.processInfo.thermalState
        return [
            "thermal": .string(thermal == .nominal ? "nominal" : thermal == .fair ? "fair" : thermal == .serious ? "serious" : "critical"),
            "onAC": .bool(power.onAC), "power": .string(power.detail), "memoryFreeFraction": .number((memory.fraction * 1000).rounded() / 1000),
            "memoryGB": .number(Double(SystemInfo.physicalMemoryBytes / 1_073_741_824)), "os": .string(SystemInfo.osVersion), "host": .string(SystemInfo.hostName),
            "addresses": .array(addresses.map { .string($0) }), "port": .number(Double(options.port)),
            "tlsFingerprint": .string(tlsFingerprint), "bonjour": .string("\(SystemInfo.hostName)._fanous._tcp"),
        ]
    }
    private var tlsFingerprint = ""

    private func applyTimecodeSettings(_ settings: ShowCommands.TimecodeSettings) {
        lastTimecodeSettings = settings
        ltc?.stop()
        mtc?.stop()
        ltc = nil
        mtc = nil
        timecodeClock.stop()
        timecodeClock.freewheelSeconds = max(0.1, settings.freewheel)
        render?.compositor.timecodeOffsets = TimecodeOffsets(project: settings.offset, layers: Dictionary(uniqueKeysWithValues: settings.layerOffsets.compactMap { k, v in Int(k).map { ($0, v) } }))
        switch settings.enabled == false ? .off : settings.source {
        case .off: break
        case .ltc:
            let input = LTCInput(clock: timecodeClock, channel: settings.channel, logger: logger)
            ltc = input
            Task { _ = await input.start(device: settings.device) }
        case .mtc:
            let input = MTCInput(clock: timecodeClock, logger: logger)
            mtc = input
            _ = input.start(source: settings.device)
        }
    }

    private func readinessContext() -> ReadinessContext {
        var context = ReadinessContext()
        if let dmx {
            let snapshot = dmx.snapshot()
            let patched = Set(dmx.currentPatch.universes.map(\.description))
            context.universesSilent = snapshot.universes.filter { patched.contains($0.id) && !$0.active }.map(\.id)
        }
        let statuses = outputStatus.withLock { $0 }
        context.outputsLost = statuses.filter { $0.state == .lost }.map(\.id)
        context.outputsUnassigned = statuses.filter { $0.state == .unassigned }.map(\.id)
        context.outputsBound = statuses.filter { $0.state == .bound }.count
        context.modeIssues = modeChecks.withLock { $0 }.sorted { $0.key < $1.key }.compactMap { id, check in check.issue.map { "Output \(id): \($0)" } }
        context.layerErrors = (render?.layers ?? []).compactMap { layer in layer.mediaStatus.withLock { $0.error.map { "Layer \(layer.index + 1): \($0)" } } }
        context.libraryRoot = library?.snapshot.root ?? ""
        return context
    }

    /// Off the control queue: the probes shell out (mdutil, tmutil, pmset, defaults).
    private func runReadiness() {
        let context = readinessContext()
        feedQueue.async { [self] in
            let acknowledged = readiness.withLock { $0.acknowledged }
            let items = Readiness.check(context, acknowledged: acknowledged)
            readiness.withLock { $0.items = items; $0.checkedAt = Date().timeIntervalSince1970 }
            publishReadiness()
        }
    }

    private func publishReadiness() {
        store?.setLive(showLive(), at: JSONPointer(tokens: ["show"]))
    }

    /// `show.mode`: entering runs the checks synchronously and refuses with the blocking item ids.
    private func setShowMode(_ on: Bool) -> [String]? {
        if !on {
            showMode.leave()
            return nil
        }
        let acknowledged = readiness.withLock { $0.acknowledged }
        let items = Readiness.check(readinessContext(), acknowledged: acknowledged)
        readiness.withLock { $0.items = items; $0.checkedAt = Date().timeIntervalSince1970 }
        let blocking = items.filter(\.blocks).map(\.id)
        if !blocking.isEmpty { return blocking }
        showMode.enter()
        return nil
    }

    /// Show mode on: the bound outputs' desired modes (first output per display wins); off: the previous modes back.
    /// Runs after every rebind, on unlock and wake too, so a replugged display gets its mode again. The switcher works
    /// on its own queue and refreshes the notes when done (`modeSwitched`).
    @MainActor private func syncDisplayModes() {
        guard let coordinator, let modeSwitcher else { return }
        let displays = coordinator.connectedDisplays
        let resolved = DisplayModeMatching.resolve(coordinator.outputs)
        let conflicts = resolved.conflicts.mapValues(\.id)
        if conflicts != lastModeConflicts {
            lastModeConflicts = conflicts
            for (loser, winner) in resolved.conflicts.sorted(by: { $0.key < $1.key }) {
                logger.warning("display mode conflict: the first output with a mode wins", metadata: ["output": "\(loser)", "winner": "\(winner.name)"])
            }
        }
        if showMode.isOn {
            modeSwitcher.apply(displays.compactMap { d in resolved.wanted[d.uuid].map { (display: d, mode: $0) } }, connected: displays)
        } else {
            modeSwitcher.restore(connected: displays)
        }
        refreshModeChecks(displays: displays)
        if readinessOnNextSync, showMode.isOn {
            readinessOnNextSync = false
            runReadiness()
        }
    }

    /// The status-line notes and readiness issues of every bound output's display mode.
    @MainActor private func refreshModeChecks(displays: [DisplayInfo]) {
        guard let coordinator, let modeSwitcher else { return }
        let outputs = coordinator.outputs, show = showMode.isOn, failures = modeSwitcher.failures
        let resolved = DisplayModeMatching.resolve(outputs)
        let fps = render?.compositor.fps ?? 60
        var checks: [Int: DisplayModeMatching.Check] = [:]
        for output in outputs {
            guard let display = displays.first(where: { $0.uuid == output.display?.uuid }) else { continue }
            if let winner = resolved.conflicts[output.id] {
                checks[output.id] = DisplayModeMatching.conflict(with: winner)
                continue
            }
            checks[output.id] = DisplayModeMatching.check(
                desired: output.mode, current: display.mode, available: display.modes, showMode: show, fps: fps, failure: failures[display.uuid])
        }
        modeChecks.withLock { $0 = checks }
    }

    /// Switcher queue: an apply or restore finished. Fresh modes from CG (the reconfiguration rebind comes later),
    /// and in show mode the readiness item at once instead of at the next 30 s run.
    private func modeSwitched() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshModeChecks(displays: DisplayManager.current())
                if self.showMode.isOn { self.runReadiness() }
            }
        }
    }

    /// Locked screen: CG refuses display configuration, so modes wait for the unlock (or wake) and are synced then.
    @MainActor private func observeUnlock() {
        let sync: @Sendable (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncDisplayModes() } }
        }
        unlockObservers = [
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil, using: sync),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil, using: sync),
        ]
    }

    private func startReadinessTimer() {
        stopReadinessTimer()
        let timer = DispatchSource.makeTimerSource(queue: feedQueue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.runReadiness()
            self?.showMode.touch()  // a long show still resumes after a power loss (ShowModeState.maxAgeAfterReboot)
        }
        timer.resume()
        readinessTimer = timer
    }

    private func stopReadinessTimer() {
        readinessTimer?.cancel()
        readinessTimer = nil
    }

    /// After a canvas switch (B31): previews at the new aspect and rate, caps for new clients, display-mode checks.
    /// Layers and slices on a canvas that does not render: a switch deferred in show mode (undo, redo, load) or one that
    /// failed. Layers draw into canvas 1 meanwhile; a slice on a canvas the project has shows canvas 1, a slice on a
    /// canvas the project does not have stays black (the coordinator logs it).
    static func effectiveCanvasUse(layers: [Int], outputs: [OutputConfig], rendering: Set<Int>, project: Set<Int>) -> (layers: [Int], outputs: [OutputConfig]) {
        let mappedLayers = layers.map { rendering.contains($0) ? $0 : 1 }
        var mappedOutputs = outputs
        for o in mappedOutputs.indices {
            for s in mappedOutputs[o].slices.indices {
                let canvas = mappedOutputs[o].slices[s].canvas
                if !rendering.contains(canvas), project.contains(canvas) { mappedOutputs[o].slices[s].canvas = 1 }
            }
        }
        return (mappedLayers, mappedOutputs)
    }

    private func effectiveCanvasUse() -> (layers: [Int], outputs: [OutputConfig], clockMaster: Int?) {
        let use = canvasUse.withLock { $0 }
        let rendering = Set(canvasSwitch?.rendered.canvases.map(\.id) ?? [1])
        let mapped = Self.effectiveCanvasUse(layers: use.layers, outputs: use.outputs, rendering: rendering, project: use.canvases)
        return (mapped.layers, mapped.outputs, use.clockMaster)
    }

    /// The project's layer and slice assignment against the canvases that render now: after a project change and
    /// after every canvas switch. Output and layer previews follow.
    @MainActor private func applyCanvasUse(rebuildLayerPreviews: Bool = false) {
        let use = effectiveCanvasUse()
        if let render, use.layers != render.compositor.layerCanvas { render.compositor.layerCanvas = use.layers }
        coordinator?.apply(outputs: use.outputs, clockMaster: use.clockMaster)
        guard let preview = stateServer?.preview else { return }
        if rebuildLayerPreviews, preview.targets.contains(where: { $0.hasPrefix("layer:") }) {
            // layer:<n> previews take the aspect of their layer's canvas
            do { try preview.rebuild() } catch { logger.error("preview rebuild failed", metadata: ["error": "\(error)"]) }
        } else if preview.targets.contains(where: { $0.hasPrefix("output:") }), let device = render?.context.device, let compiler = try? OutputCompiler(device: device) {
            // output previews follow their output
            preview.refreshOutputs { target, streamer in
                guard target.hasPrefix("output:"), let id = Int(target.dropFirst(7)), let output = use.outputs.first(where: { $0.id == id }) else { return false }
                return previewOutput(output, in: use.outputs, compiler: compiler, preview: streamer)
            }
        }
    }

    @MainActor private func canvasSwitched(to layout: ProjectDocument.CanvasLayout) {
        let sizes = layout.canvases.map { "\($0.id): \($0.width)×\($0.height)" }.joined(separator: ", ")
        logger.info("canvases changed", metadata: ["canvases": "\(sizes)", "fps": "\(layout.fps)"])
        applyCanvasUse()  // layers and slices waiting for a canvas that now renders
        do { try stateServer?.preview?.rebuild() } catch { logger.error("preview rebuild failed", metadata: ["error": "\(error)"]) }
        stateServer?.setCaps(fps: layout.fps)
        syncDisplayModes()
    }

    /// A canvas switch failed: the old canvases still render, so they go back into the project (no history entry).
    @MainActor private func canvasSwitchFailed(keeping rendered: ProjectDocument.CanvasLayout, error: any Error) {
        logger.error("canvas change failed; the previous canvases keep running", metadata: ["error": "\(error)"])
        guard let store else { return }
        var project = store.project
        guard (try? ProjectDocument.setCanvasLayout(rendered, in: &project)) != nil else { return }
        // what was put on a canvas that could not be made goes back to canvas 1, as canvas.remove does
        try? ProjectDocument.moveToCanvas1(keeping: Set(rendered.canvases.map(\.id)), in: &project)
        for key in ["canvases", "layerCanvas", "outputs"] {
            if let value = project[key], value != store.project[key], let pointer = try? JSONPointer("/" + key) { store.correct(value, at: pointer) }
        }
    }

    /// Canvas id per layer index for the compositor (`/layerCanvas`, canvas 1 when unset).
    static func layerCanvas(project: JSONValue, layers: Int) -> [Int] {
        let assigned = ProjectDocument.layerCanvases(from: project)
        return (0..<layers).map { assigned[$0 + 1] ?? 1 }
    }

    /// Canvas at start (B31): a `--scene` file wins (development, bench), then the project's first canvas, then
    /// 1920×1080 at 60. A hand-edited project canvas that `canvas.set` would refuse falls back to the default.
    static func startCanvas(project: JSONValue?, scene: SceneConfig?) -> ProjectDocument.CanvasFormat {
        if let scene { return (scene.canvasWidth, scene.canvasHeight, scene.fps) }
        guard let canvas = project.map(ProjectDocument.canvases(from:))?.first else { return ProjectDocument.defaultCanvas }
        return (try? ProjectDocument.validated((canvas.width, canvas.height, canvas.fps))) ?? ProjectDocument.defaultCanvas
    }

    /// Control queue: re-applies the patch when it changed and schedules the autosave (2 s after the last change).
    /// The bundled agent runs without a scene file: canvas from the project's first canvas, media from the library.
    static func defaultScene(canvas: ProjectDocument.CanvasFormat, layerCount: Int, policy: SourcePolicy, library: URL) -> SceneConfig {
        var scene = SceneConfig()
        scene.canvasWidth = canvas.width
        scene.canvasHeight = canvas.height
        scene.fps = canvas.fps
        scene.layerCount = layerCount
        scene.policy = policy
        scene.library = library.path
        return scene
    }

    static func sacnUniverses(_ patch: Patch) -> [Int] { patch.universes.filter { $0.transport == .sacn }.map(\.number) }

    private func projectChanged(_ document: JSONValue) {
        if let dmx, let patch = ProjectDocument.effectivePatch(from: document), patch != dmx.currentPatch {
            dmx.setPatch(patch)
            sacn?.update(universes: Self.sacnUniverses(patch))
        }
        // the source policy applies to every patched fixture, also to the resolvers a new patch created
        if let dmx, let raw = document["policy"]?.string, let policy = SourcePolicy(rawValue: raw), policy != lastPolicy {
            lastPolicy = policy
            for entry in dmx.currentPatch.entries { dmx.setPolicy(policy, for: entry.fixture) }
        }
        if let root = document["library"]?["root"]?.string, root != library?.root.path, root != lastLibraryRootWarning {
            lastLibraryRootWarning = root
            logger.warning("library root changed in the project; it applies after an engine restart", metadata: ["root": "\(root)"])
        }
        let cueList = ShowCommands.cueList(from: document)
        if cueList != lastCues {
            lastCues = cueList
            cues?.replace(list: cueList)
        }
        let timecodeSettings = ShowCommands.timecodeSettings(from: document)
        if timecodeSettings != lastTimecodeSettings { applyTimecodeSettings(timecodeSettings) }
        // canvases, sizes or rate (canvas.add/remove/set, undo/redo, project load): applied unless show mode is on
        if let c = ProjectDocument.canvases(from: document).first, (try? ProjectDocument.validated((c.width, c.height, c.fps))) != nil {
            canvasSwitch?.request(ProjectDocument.layout(from: document))
        }
        // layer → canvas (layer.set) and slices: applied against the canvases that render (main actor)
        let layers = Self.layerCanvas(project: document, layers: render?.layers.count ?? 0)
        let outputs = ProjectDocument.outputs(from: document)
        let clockMaster = ProjectDocument.canvases(from: document).first?.clockMaster
        let projectCanvases = Set(ProjectDocument.canvases(from: document).map(\.id))
        let use = CanvasUse(outputs: outputs, clockMaster: clockMaster, layers: layers, canvases: projectCanvases)
        let previous = canvasUse.withLock { old in
            defer { old = use }
            return old
        }
        if layers != lastLayerCanvas || outputs != lastOutputs || clockMaster != lastClockMaster || projectCanvases != previous.canvases {
            let layersChanged = layers != lastLayerCanvas
            lastLayerCanvas = layers
            lastOutputs = outputs
            lastClockMaster = clockMaster
            // never from here: rebuilding previews reads the project (this queue); the main actor may
            Task { @MainActor in self.applyCanvasUse(rebuildLayerPreviews: layersChanged) }
        }
        autosave?.cancel()
        let logger = logger
        let showLock = document["showLock"]?.bool ?? false
        let work = DispatchWorkItem { [weak self] in
            do {
                try ProjectDocument.save(document, to: AppPaths.projectFile)
                self?.savedShowLock.withLock { $0 = showLock }
            } catch { logger.error("autosave failed", metadata: ["error": "\(error)"]) }
        }
        autosave = work
        // a crash must not unlock a locked show: a lock change is written now, on the same serial queue as the
        // debounced saves, so an older document cannot land after it
        if showLock != savedShowLock.withLock({ $0 }) {
            feedQueue.async(execute: work)
        } else {
            feedQueue.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    /// Live document at 10 Hz and the DMX monitor stream at 20 Hz, both off the render and DMX threads.
    private func startFeeds() {
        let live = DispatchSource.makeTimerSource(queue: feedQueue)
        live.schedule(deadline: .now() + 0.1, repeating: 0.1)
        live.setEventHandler { [weak self] in self?.publishLive() }
        live.resume()
        liveTimer = live
    }

    /// The DMX monitor stream (20 Hz) only runs while a client has a DMX subscription.
    private func setDMXStream(active: Bool) {
        feedQueue.async { [self] in
            if active, dmxTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: feedQueue)
                timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
                timer.setEventHandler { [weak self] in self?.streamDMX() }
                timer.resume()
                dmxTimer = timer
            } else if !active, let timer = dmxTimer {
                timer.cancel()
                dmxTimer = nil
            }
        }
    }

    /// CoreAudio/CoreMIDI/getifaddrs lookups are slow and rarely change: refreshed every 5 s on the feed queue.
    private struct HostFacts {
        var at: CFTimeInterval = 0
        var midiSources: [String] = []
        var audioInputs: [String] = []
        var addresses: [String] = []
    }
    private var hostFacts = HostFacts()
    private func currentHostFacts() -> HostFacts {
        let now = CACurrentMediaTime()
        if now - hostFacts.at >= 5 {
            hostFacts = HostFacts(at: now, midiSources: MTCInput.sources(), audioInputs: LTCInput.inputDevices(), addresses: SystemInfo.ipv4Addresses)
        }
        return hostFacts
    }

    private func publishLive() {
        guard let dmx, let store, let auth, let ingest, let library else { return }
        // nobody to tell; a client that connects gets the full live document in its welcome and a fresh one within 100 ms
        guard store.clientCount > 0 else { return }
        let facts = currentHostFacts()
        let summary = metrics.summary(seconds: 1, now: CACurrentMediaTime())
        func ms(_ v: Double) -> JSONValue { .number((v * 100).rounded() / 100) }
        let snapshot = library.snapshot
        let modeNotes = modeChecks.withLock { $0 }.compactMapValues(\.note)
        let live: JSONValue = [
            "canvas": canvasSwitch?.live ?? .null,
            "engine": [
                "version": .string(FanousVersion.string), "chip": .string(SystemInfo.chipName),
                "uptimeSeconds": .number(Date().timeIntervalSince(startedAt).rounded()), "rendering": .bool(render != nil),
            ],
            "metrics": [
                "frames": .number(Double(summary.frames)), "missed": .number(Double(summary.missed)), "late": .number(Double(summary.late)),
                "textureMisses": .number(Double(summary.textureMisses)), "idle": .number(Double(summary.idle)), "cpuP50": ms(summary.cpuP50), "cpuP99": ms(summary.cpuP99),
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
                        "modes": .array(d.modes.prefix(64).map { ["width": .number(Double($0.width)), "height": .number(Double($0.height)), "hz": .number($0.hz)] }),
                    ]
                }),
            "outputs": .array(
                outputStatus.withLock { $0 }.map { s in
                    [
                        "id": .number(Double(s.id)), "state": .string(s.state.rawValue), "display": s.display.map { .string($0) } ?? .null,
                        "width": .number(Double(s.width)), "height": .number(Double(s.height)), "hz": .number(s.hz), "master": .bool(s.isMaster),
                        "modeNote": modeNotes[s.id].map { .string($0) } ?? .null,
                    ]
                }),
            "security": ["webUIOpen": .bool(auth.isOpen(.programmer))],
            "timecode": timecodeLive(),
            "cue": cueLive(),
            "show": showLive(),
            "system": systemLive(addresses: facts.addresses),
            "osc": ["port": 8000, "recent": .array(oscLog.withLock { $0 }), "midiSources": .array(facts.midiSources.map { .string($0) }), "audioInputs": .array(facts.audioInputs.map { .string($0) })],
            "citp": citpLive(),
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
        feedQueue.sync {
            dmxTimer?.cancel()
            dmxTimer = nil
        }
        stopReadinessTimer()
        citp?.stop()
        // Engine › Restart Engine keeps show mode (and the switched display modes) for the next start; every other
        // stop leaves it. Either way no enter after this point.
        let keepShow = showMode.stop(keepingState: ShowModeState.takeRestartMarker(at: AppPaths.restartPendingFile))
        ltc?.stop()
        mtc?.stop()
        cues?.stop()
        if let coordinator, let displayManager {
            MainActor.assumeIsolated {
                displayManager.stop()
                // leaving above only queued it; supersedes a pending apply and waits for the one in flight. A restart
                // in show mode keeps the modes and the ledger: the next start resumes and finds them switched.
                if !keepShow { modeSwitcher?.restore(connected: coordinator.connectedDisplays) }
                modeSwitcher?.flush()
                for observer in unlockObservers {
                    DistributedNotificationCenter.default().removeObserver(observer)
                    NSWorkspace.shared.notificationCenter.removeObserver(observer)
                }
                coordinator.stop()
            }
        }
        if let autosave, !autosave.isCancelled {
            autosave.cancel()
            feedQueue.sync { autosave.perform() }  // after any save in flight
        }
        server?.stop()
        ingest?.stop()
        library?.stop()
        artnet?.stop()
        sacn?.stop()
        osc?.stop()
        dmx?.stop()
        logger.info("fanousd stopped")
    }
}

public enum WebRoot {
    /// --web-root flag > $FANOUS_WEB_ROOT > <bundle>/Contents/Resources/web > web/dist near a dev build.
    public static func locate() -> URL {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["FANOUS_WEB_ROOT"] { return URL(fileURLWithPath: env) }
        if let resources = Bundle.main.resourceURL?.appending(path: "web"), fm.fileExists(atPath: resources.path) {
            return resources
        }
        var directory = Bundle.main.executableURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: fm.currentDirectoryPath)
        // walking up also finds the main app's Contents/Resources/web from the engine helper (Contents/Helpers/…)
        for _ in 0..<6 {
            for candidate in [directory.appending(path: "web/dist"), directory.appending(path: "Resources/web")]
            where fm.fileExists(atPath: candidate.appending(path: "index.html").path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: "web/dist")
    }
}
