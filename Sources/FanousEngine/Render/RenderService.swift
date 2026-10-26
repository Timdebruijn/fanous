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
    nonisolated(unsafe) public private(set) var mixer: AudioMixer?  // assigned once at start, read by the metrics endpoint
    private let logger: Logger
    /// Keeps the audio device open while true (the engine passes show mode); read once by `start()`.
    nonisolated(unsafe) public var audioKeepRunning: (@Sendable () -> Bool)?
    private var window: OutputWindow?
    private var displayDriver: DisplayLinkDriver?
    private var loopDriver: DrawableLoopDriver?
    private var headlessDriver: HeadlessDriver?

    public init(scene: SceneConfig, context: MetalContext, parameters: TripleBuffer<ParameterSnapshotSlot>, metrics: MetricsRing, logger: Logger) throws {
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
        loader.liveFactory = { spec in
            let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let input = SyphonInput(device: device)
            do { try input.connect(appName: parts[0], serverName: parts[1]) } catch { return nil }
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

    /// Diagnostics: display-link updates seen, compositor ticks, encoder failures.
    public var counters: (updates: Int, ticks: Int, encoderFailures: Int, completed: Int, gpuErrors: Int, outputFailures: Int, lastError: String) {
        (displayDriver?.updates.load(ordering: .relaxed) ?? -1, compositor.ticks.load(ordering: .relaxed), compositor.encoderFailures.load(ordering: .relaxed),
         compositor.completed.load(ordering: .relaxed), compositor.gpuErrors.load(ordering: .relaxed), compositor.outputEncoderFailures.load(ordering: .relaxed), compositor.lastGPUError)
    }

    public func stop() {
        displayDriver?.stop()
        loopDriver?.stop()
        headlessDriver?.stop()
        displayDriver = nil
        loopDriver = nil
        headlessDriver = nil
        usleep(50_000)
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
        compositor.canvasPublished = nil
        compositor.canvasPublishedWanted = nil
        syphon?.stop()
        syphon = nil
        mixer?.stop()
        mixer = nil
    }
}
