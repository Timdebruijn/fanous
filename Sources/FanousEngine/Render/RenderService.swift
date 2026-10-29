// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import Foundation
import FanousCore
import Logging

/// A scene until projects exist (Phase 5): one canvas, N layer slots, the
/// media those slots can address, one display or headless.
public struct SceneConfig: Codable, Sendable {
    public var canvasWidth = 1920
    public var canvasHeight = 1080
    public var fps = 60.0
    public var layerCount = 1
    public var media: [MediaEntry] = []
    public var display: Int?  // NSScreen index; nil = headless
    /// Frames decoded ahead per layer; 8 is needed for 4K (benchmarks 2026-10-23), 6 suffices for 1080p.
    public var ringCapacity = 8
    public var frameLatency = 1
    /// CAMetalDisplayLink instead of the drawable loop (stalls on macOS 27.0.1, see ADR-0006 amendment).
    public var useDisplayLink = false
    /// Publish the canvas as a Syphon server (DESIGN.md §9.8); the frame is only copied while a client is attached.
    public var syphonOutput = true

    /// A scene's `"syphon": "App/Server name"`, split on the first `/`. `"App/"` takes the first server of that app
    /// (for apps with a single server); an empty app name is refused, since Syphon would then match any server,
    /// this engine's own canvas included.
    static func syphonSpec(_ spec: String) -> (app: String, server: String)? {
        let parts = spec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
    /// Audio playback through the default output device (DESIGN.md §10).
    public var audio = true
    /// Source policy for every layer and the master until projects carry it (DESIGN.md §7.2): dmx, internal, ltp, htp.
    public var policy: SourcePolicy = .dmx
    /// Library root (DESIGN.md §8.1); nil = the machine default `~/Movies/Fanous Library`. Explicit `media` entries win.
    public var library: String?
    /// True when an `OutputCoordinator` owns displays and drivers (projects with outputs); the service then starts none.
    public var managedOutputs = false

    public init() {}

    public static func load(_ url: URL) throws -> SceneConfig {
        try JSONDecoder().decode(SceneConfig.self, from: Data(contentsOf: url))
    }

    /// Every key is optional in the file; missing ones keep the defaults above.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canvasWidth = try c.decodeIfPresent(Int.self, forKey: .canvasWidth) ?? canvasWidth
        canvasHeight = try c.decodeIfPresent(Int.self, forKey: .canvasHeight) ?? canvasHeight
        fps = try c.decodeIfPresent(Double.self, forKey: .fps) ?? fps
        layerCount = try c.decodeIfPresent(Int.self, forKey: .layerCount) ?? layerCount
        media = try c.decodeIfPresent([MediaEntry].self, forKey: .media) ?? media
        display = try c.decodeIfPresent(Int.self, forKey: .display)
        ringCapacity = try c.decodeIfPresent(Int.self, forKey: .ringCapacity) ?? ringCapacity
        frameLatency = try c.decodeIfPresent(Int.self, forKey: .frameLatency) ?? frameLatency
        useDisplayLink = try c.decodeIfPresent(Bool.self, forKey: .useDisplayLink) ?? useDisplayLink
        syphonOutput = try c.decodeIfPresent(Bool.self, forKey: .syphonOutput) ?? syphonOutput
        audio = try c.decodeIfPresent(Bool.self, forKey: .audio) ?? audio
        policy = try c.decodeIfPresent(SourcePolicy.self, forKey: .policy) ?? policy
        library = try c.decodeIfPresent(String.self, forKey: .library)
    }
}

/// Owns the layer slots, the media loader, the compositor and the output for one scene.
@MainActor
public final class RenderService {
    public let scene: SceneConfig
    public let context: MetalContext
    public let compositor: Compositor
    public let metrics: MetricsRing
    public let parameters: TripleBuffer<ParameterSnapshotSlot>
    public let layers: [RenderLayer]
    public let loader: MediaLoader
    public private(set) var syphon: SyphonOutput?
    /// Other apps' Syphon servers as folder 0 files 150–169 (B61); lives as long as the engine.
    public let syphonCatalog: SyphonCatalog
    nonisolated(unsafe) public private(set) var mixer: AudioMixer?  // assigned once at start, read by the metrics endpoint
    private let logger: Logger
    /// Keeps the audio device open while true (the engine passes show mode); read once by `start()`.
    nonisolated(unsafe) public var audioKeepRunning: (@Sendable () -> Bool)?
    private var window: OutputWindow?
    private var displayDriver: DisplayLinkDriver?
    private var loopDriver: DrawableLoopDriver?
    private var headlessDriver: HeadlessDriver?

    /// `syphonNumbers`: the project's Syphon numbering (B69), held for the servers before the first announce.
    public init(
        scene: SceneConfig, context: MetalContext, parameters: TripleBuffer<ParameterSnapshotSlot>, metrics: MetricsRing, logger: Logger,
        syphonNumbers: [SyphonCatalog.Server] = []
    ) throws {
        self.scene = scene
        self.context = context
        self.parameters = parameters
        self.metrics = metrics
        self.logger = logger
        let count = max(1, scene.layerCount)
        compositor = try Compositor(
            context: context, canvasWidth: scene.canvasWidth, canvasHeight: scene.canvasHeight, fps: scene.fps,
            maxLayers: count, metrics: metrics, parameters: parameters, logger: logger)
        layers = (0..<count).map { RenderLayer(index: $0) }
        loader = MediaLoader(layers: layers, media: scene.media, device: context.device, ringCapacity: scene.ringCapacity, logger: logger)
        compositor.setLayers(layers)
        compositor.loaderWake = loader.wake
        let device = context.device
        // generators are made at the canvas size of the moment (it changes with canvas.set, B31)
        loader.generatorFactory = { [compositor] file in
            let size = compositor.canvasSizeSnapshot
            return GeneratorSource(context: context, file: file, width: size.width, height: size.height)
        }
        loader.liveFactory = { spec, uuid in
            let input = SyphonInput(device: device)
            do {
                if let uuid {
                    try input.connect(uuid: uuid)
                } else {
                    guard let (app, server) = SceneConfig.syphonSpec(spec) else { return nil }
                    try input.connect(appName: app, serverName: server)
                }
            } catch { return nil }
            return input
        }
        if scene.syphonOutput {
            let output = try SyphonOutput(name: "Fanous – Canvas", device: device)
            syphon = output
            compositor.canvasPublishedWanted = { output.hasClients }
            compositor.canvasPublished = { texture, commandBuffer in
                if output.hasClients { output.publish(texture: texture, commandBuffer: commandBuffer) }
            }
        }
        syphonCatalog = SyphonCatalog(excluding: syphon?.uuid, numbers: syphonNumbers)
        loader.syphonCatalog = syphonCatalog
        syphonCatalog.onChange = { [weak loader] in loader?.syphonServersChanged() }  // the loader holds the catalog
        syphonCatalog.start(device: device)
    }

    public func start() async throws {
        if scene.audio {
            // the mixer only builds its channels here; the output device opens when the first movie with sound does
            let mixer = AudioMixer(channels: layers.count * 2)
            mixer.keepRunning = audioKeepRunning
            let logger = logger
            mixer.onError = { logger.warning("audio output unavailable; playing silent", metadata: ["error": "\($0)"]) }
            self.mixer = mixer
            loader.mixer = mixer
        }
        loader.start()
        if scene.managedOutputs {
            logger.info("outputs managed by the coordinator", metadata: ["layers": "\(layers.count)"])
        } else if let display = scene.display {
            let screens = NSScreen.screens
            guard display < screens.count else { throw RenderError.pipeline("display \(display) not found (\(screens.count) screens)") }
            let window = OutputWindow(screen: screens[display], device: context.device)
            // Let the window server attach the layer to its display before the driver binds to it.
            try await Task.sleep(for: .milliseconds(250))
            if scene.useDisplayLink {
                displayDriver = DisplayLinkDriver(layer: window.metalLayer, fps: scene.fps, compositor: compositor, frameLatency: scene.frameLatency)
            } else {
                loopDriver = DrawableLoopDriver(layer: window.metalLayer, fps: scene.fps, compositor: compositor)
            }
            self.window = window
            logger.info("output on display \(display)", metadata: ["size": "\(window.metalLayer.drawableSize)", "driver": "\(scene.useDisplayLink ? "CAMetalDisplayLink" : "drawable loop")", "frameLatency": "\(scene.frameLatency)"])
        } else {
            headlessDriver = HeadlessDriver(fps: scene.fps, compositor: compositor)
            logger.info("headless compositor", metadata: ["fps": "\(scene.fps)", "layers": "\(layers.count)"])
        }
    }

    /// Diagnostics: display-link updates seen, compositor ticks, encoder failures, ticks that waited on a full ring (B105).
    public var counters: (updates: Int, ticks: Int, encoderFailures: Int, completed: Int, gpuErrors: Int, outputFailures: Int, lastError: String, completionWaits: Int) {
        (displayDriver?.updates.load(ordering: .relaxed) ?? -1, compositor.ticks.load(ordering: .relaxed), compositor.encoderFailures.load(ordering: .relaxed),
         compositor.completed.load(ordering: .relaxed), compositor.gpuErrors.load(ordering: .relaxed), compositor.outputEncoderFailures.load(ordering: .relaxed), compositor.lastGPUError,
         compositor.completionWaits.load(ordering: .relaxed))
    }

    /// Joins the ticking thread first and waits for the render queue's completed handlers before the Syphon server
    /// stops: it must not stop under a `publish` or a publish's completed handler in flight (B113). With
    /// `managedOutputs` the coordinator owns the drivers and must be stopped before this.
    public func stop() {
        let joined = [displayDriver?.stop(), loopDriver?.stop(), headlessDriver?.stop()].allSatisfy { $0 ?? true }
        if !joined {
            logger.warning("the compositor thread did not stop within 1 s; the rest of the stop runs under a tick that may be in flight, and the Syphon server is left running")
        }
        displayDriver = nil
        loopDriver = nil
        headlessDriver = nil
        loader.stop()
        for layer in layers {
            layer.current?.stop()
            layer.outgoing?.stop()
            layer.staged?.stop()
            layer.current = nil
            layer.outgoing = nil
            layer.staged = nil
        }
        window?.close()
        window = nil
        compositor.setLayers([])
        syphonCatalog.stop()
        // Clearing the hook races a tick's publish, and the server's stop() releases, unlocked, the renderer that publish
        // draws with and the connection manager and surface that each publish's completed handler uses on Metal's
        // completion thread. So both are done only after the join and the drain; otherwise the server goes with the process.
        if let syphon, joined {
            if gpuDrained() {
                compositor.canvasPublished = nil
                compositor.canvasPublishedWanted = nil
                syphon.stop()
                self.syphon = nil
            } else {
                logger.warning("the render queue's completed handlers did not run within 1 s; the Syphon server is left running")
            }
        }
        mixer?.stop()
        mixer = nil
    }

    /// Commits an empty command buffer on the render queue and waits (≤ 1 s) for its completed handler, which runs after
    /// those of the buffers committed before it on that queue (B113; `RenderServiceStopTests` holds one to check).
    private func gpuDrained() -> Bool {
        guard let buffer = context.queue.makeCommandBuffer() else { return false }
        let done = DispatchSemaphore(value: 0)
        buffer.addCompletedHandler { _ in done.signal() }
        buffer.commit()
        return done.wait(timeout: .now() + 1) == .success
    }
}
