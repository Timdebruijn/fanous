// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import Foundation
import LanthornCore
import Logging

/// Phase 2 scene: one canvas, N movie layers, one display or headless.
public struct SceneConfig: Codable, Sendable {
    public var canvasWidth = 1920
    public var canvasHeight = 1080
    public var fps = 60.0
    public var layers: [String] = []  // movie paths, layer 1 first
    public var display: Int?  // NSScreen index; nil = headless
    public var ringCapacity = 4
    public var frameLatency = 1

    public init() {}

    public static func load(_ url: URL) throws -> SceneConfig {
        try JSONDecoder().decode(SceneConfig.self, from: Data(contentsOf: url))
    }
}

/// Owns sources, decoders, the compositor and the output for one scene.
@MainActor
public final class RenderService {
    public let scene: SceneConfig
    public let context: MetalContext
    public let compositor: Compositor
    public let metrics: MetricsRing
    public let parameters: TripleBuffer<ParameterSnapshotSlot>
    private let logger: Logger
    private var layers: [RenderLayer] = []
    private var window: OutputWindow?
    private var displayDriver: DisplayLinkDriver?
    private var headlessDriver: HeadlessDriver?

    public init(scene: SceneConfig, context: MetalContext, parameters: TripleBuffer<ParameterSnapshotSlot>, metrics: MetricsRing, logger: Logger) throws {
        self.scene = scene
        self.context = context
        self.parameters = parameters
        self.metrics = metrics
        self.logger = logger
        compositor = try Compositor(
            context: context, canvasWidth: scene.canvasWidth, canvasHeight: scene.canvasHeight, fps: scene.fps,
            maxLayers: max(1, scene.layers.count), metrics: metrics, parameters: parameters, logger: logger)
    }

    public var layerSources: [MovieSource] { layers.map(\.source) }

    public func start() async throws {
        let device = context.device
        let capacity = scene.ringCapacity
        let sources = try await withThrowingTaskGroup(of: (Int, MovieSource).self) { group in
            for (index, path) in scene.layers.enumerated() {
                group.addTask { (index, try await MovieSource.open(url: URL(fileURLWithPath: path), device: device, poolSize: capacity)) }
            }
            var result: [(Int, MovieSource)] = []
            for try await item in group { result.append(item) }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
        layers = sources.enumerated().map { index, source in
            let ring = FrameRing(capacity: capacity)
            let decoder = LayerDecoder(source: source, ring: ring, logger: logger)
            decoder.start(name: "org.lanthorn.decode.\(index + 1)")
            decoder.request(frame: 0, direction: 1)
            return RenderLayer(index: index, source: source, decoder: decoder, ring: ring)
        }
        compositor.setLayers(layers)
        for (index, source) in sources.enumerated() {
            logger.info("layer \(index + 1)", metadata: ["file": "\(source.url.lastPathComponent)", "codec": "\(source.info.codecName)", "size": "\(source.info.width)x\(source.info.height)@\(source.info.frameRate)"])
        }
        usleep(100_000)  // let the decoders fill their rings before the first tick
        if let display = scene.display {
            let screens = NSScreen.screens
            guard display < screens.count else { throw RenderError.pipeline("display \(display) not found (\(screens.count) screens)") }
            let window = OutputWindow(screen: screens[display], device: device)
            displayDriver = DisplayLinkDriver(layer: window.metalLayer, fps: scene.fps, compositor: compositor, frameLatency: scene.frameLatency)
            self.window = window
            logger.info("output on display \(display)", metadata: ["size": "\(window.metalLayer.drawableSize)", "frameLatency": "\(scene.frameLatency)"])
        } else {
            headlessDriver = HeadlessDriver(fps: scene.fps, compositor: compositor)
            logger.info("headless compositor", metadata: ["fps": "\(scene.fps)"])
        }
    }

    public func stop() {
        displayDriver?.stop()
        headlessDriver?.stop()
        displayDriver = nil
        headlessDriver = nil
        usleep(50_000)
        for layer in layers { layer.decoder.stop() }
        window?.close()
        window = nil
        layers = []
        compositor.setLayers([])
    }
}
