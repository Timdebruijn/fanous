// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Metal
import os
import Synchronization
import Testing

@testable import FanousEngine

/// Preview targets are per subscriber: a client asking for an output does not move the canvas preview of another, and a
/// consumer that only wants JPEG (5 fps) throttles the GPU copy as well.
@Suite(.serialized) struct PreviewHubTests {
    static let logger = Logger(label: "preview-hub-test")

    struct Rig {
        let context: MetalContext
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) }
        let server: StateServer
        let hub: PreviewHub
        let compositor: Compositor

        init() throws {
            context = try MetalContext()
            let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: PreviewHubTests.logger)
            let project = ProjectDocument.initial(patch: .standard(layers: 1, outputs: 1), layerCount: 1, libraryRoot: "/tmp/lib", policy: .dmx)
            server = StateServer(store: StateStore(project: project, logger: PreviewHubTests.logger), auth: auth, caps: ["schema": 1], logger: PreviewHubTests.logger)
            let context = context, parameters = parameters
            let make: @Sendable () throws -> PreviewStreamer = {
                try PreviewStreamer(context: context, width: 160, height: 90, fps: 30, canvasFPS: 60, parameters: parameters, logger: PreviewHubTests.logger)
            }
            hub = PreviewHub(canvas: try make(), make: make)
            let compiler = try OutputCompiler(device: context.device)
            hub.configure = { target, streamer in
                guard target == "output:1", let set = try? OutputSet(plans: [compiler.compile(OutputConfig(id: 1), index: 1, drawable: (160, 90))]) else { return false }
                streamer.outputSet = set
                return true
            }
            compositor = try Compositor(
                context: context, canvasWidth: 160, canvasHeight: 90, fps: 60, maxLayers: 1, metrics: MetricsRing(capacity: 64), parameters: parameters,
                logger: PreviewHubTests.logger)
            compositor.previewTap = { [hub] canvas, buffer, target in hub.tap(canvas: canvas, commandBuffer: buffer, target: target) }
        }

        func connection() -> StateServer.Connection { StateServer.Connection(server: server, cookieRole: nil) }

        func attach(_ target: String, _ connection: StateServer.Connection, stream: UInt32 = 1, jpeg: Bool = false) -> Bool {
            hub.attach(target: target, connection: connection, stream: stream, jpeg: jpeg) { _ in }
        }

        func tick(_ n: Int) {
            for i in 0..<n { compositor.tick(target: 100 + Double(i) / 60, drawable: nil) }
        }
    }

    @Test func eachTargetHasItsOwnStreamerAndOneClientsChoiceDoesNotMoveAnother() throws {
        let rig = try Rig()
        let (a, b, c) = (rig.connection(), rig.connection(), rig.connection())
        #expect(rig.attach("canvas", a))
        #expect(rig.attach("output:1", b))
        #expect(rig.attach("output:1", c, stream: 2))
        #expect(!rig.attach("output:9", rig.connection()), "unknown output is refused")
        #expect(!rig.attach("nonsense", rig.connection()))
        #expect(Set(rig.hub.targets) == ["canvas", "output:1"])
        #expect(rig.hub.canvas.outputSet == nil, "the canvas preview still shows the canvas")

        rig.hub.unsubscribe(connection: b, stream: 1)
        #expect(rig.hub.targets.contains("output:1"), "c still watches the output")
        rig.hub.remove(connection: c)
        #expect(rig.hub.targets == ["canvas"], "released with its last subscriber")
        #expect(rig.hub.canvas.hasSubscribers, "a is untouched")
    }

    @Test func noSubscriberMeansNoFramesAndAnOutputStreamerDrawsOnlyWhileWatched() throws {
        let rig = try Rig()
        #expect(!rig.hub.wantsFrames)
        rig.tick(30)
        #expect(rig.hub.framesIn == 0)
        let a = rig.connection(), b = rig.connection()
        #expect(rig.attach("canvas", a))
        #expect(rig.hub.wantsFrames)
        rig.tick(30)
        #expect(rig.hub.framesIn == 15, "H.264 canvas preview: every second tick of 60 fps")
        #expect(rig.attach("output:1", b, stream: 3))
        rig.tick(30)
        #expect(rig.hub.framesIn == 15 + 30, "canvas and output streamer both tap")
        rig.hub.remove(connection: b)
        #expect(rig.hub.targets == ["canvas"], "the output streamer is gone again")
        let canvasFrames = rig.hub.canvas.framesIn.load(ordering: .relaxed)
        rig.tick(30)
        #expect(rig.hub.framesIn == canvasFrames + 15, "only the canvas streamer taps now")
    }

    @Test func jpegOnlyConsumersThrottleTheGPUTapToFivePerSecond() throws {
        let rig = try Rig()
        let a = rig.connection()
        #expect(rig.attach("canvas", a, jpeg: true))
        rig.tick(120)
        #expect(rig.hub.framesIn == 10, "5 fps over 2 s, not 30 fps with a throttled encoder (got \(rig.hub.framesIn))")
        // CITP-only wanting is JPEG too
        rig.hub.remove(connection: a)
        rig.hub.canvas.externalJPEGWanted = { true }
        let before = rig.hub.framesIn
        rig.tick(60)
        #expect(rig.hub.framesIn - before == 5)
        // a H.264 subscriber brings the tap back to 30 fps
        #expect(rig.attach("canvas", rig.connection(), stream: 7))
        let beforeH264 = rig.hub.framesIn
        rig.tick(60)
        #expect(rig.hub.framesIn - beforeH264 == 30)
    }

    /// Multiple canvases: "canvas:1" is the canvas streamer, "canvas:<id>" gets its own streamer at that canvas's size
    /// and taps that canvas; an unknown canvas is refused; a rebuild remakes it too.
    @Test func canvasTargetsPreviewTheirCanvas() throws {
        let rig = try Rig()
        try rig.compositor.reconfigure(.init(fps: 60, canvases: [.init(id: 1, width: 160, height: 90), .init(id: 2, width: 320, height: 320)]))
        let context = rig.context, parameters = rig.parameters
        let made = Mutex(0)
        rig.hub.makeCanvas = { id in
            guard id == 2 else { return nil }
            made.withLock { $0 += 1 }
            return try PreviewStreamer(context: context, width: 160, height: 160, fps: 30, canvasFPS: 60, parameters: parameters, logger: Self.logger)
        }
        rig.hub.canvasTexture = { [compositor = rig.compositor] id in compositor.tickCanvas(id) }
        let (a, b) = (rig.connection(), rig.connection())
        #expect(rig.attach("canvas:1", a))
        #expect(rig.hub.targets == ["canvas"], "canvas:1 is the canvas streamer")
        #expect(rig.attach("canvas:2", b, stream: 2))
        #expect(!rig.attach("canvas:3", rig.connection()))
        #expect(!rig.attach("canvas:x", rig.connection()))
        rig.tick(30)
        let second = rig.hub.framesIn - rig.hub.canvas.framesIn.load(ordering: .relaxed)
        #expect(second == 15, "the canvas 2 streamer taps its canvas (got \(second))")
        try rig.hub.rebuild()
        #expect(made.withLock { $0 } == 2 && Set(rig.hub.targets) == ["canvas", "canvas:2"])

        // canvas 2 removed: its streamer goes (its viewer gets badTarget) instead of showing a frozen picture
        rig.hub.makeCanvas = { _ in nil }
        try rig.hub.rebuild()
        #expect(rig.hub.targets == ["canvas"])
    }

    /// A layer.set with a layer:<n> subscriber: the preview rebuild reads the project, so it must not run on the
    /// store's queue (it did, and deadlocked). Wired like the engine: Control hops to the main actor.
    @Test(.timeLimit(.minutes(1))) func layerSetWithALayerSubscriberDoesNotHang() async throws {
        let rig = try LayerRig()
        let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: Self.logger)
        let store = StateStore(project: ProjectDocument.initial(patch: .standard(layers: 2, outputs: 1), layerCount: 2, libraryRoot: "/x", policy: .dmx), logger: Self.logger)
        ProjectDocument.registerCommands(on: store, auth: auth)
        let compositor = rig.compositor, made = rig.made
        rig.hub.canvasOfLayer = { target in ProjectDocument.layerCanvases(from: store.project)[Int(target.dropFirst(6)) ?? 0] ?? 1 }
        rig.hub.configure = { target, streamer in
            guard let index = PreviewHub.layerIndex(of: target, layerCount: store.project["layerCount"]?.int ?? 0), (try? streamer.showLayer(index, of: compositor)) != nil else { return false }
            made.withLock { $0[target] = streamer }
            return true
        }
        let rebuilt = Mutex(0)
        store.onProjectChanged = { [hub = rig.hub] _ in
            Task { @MainActor in
                try? hub.rebuild()
                rebuilt.withLock { $0 += 1 }
            }
        }
        #expect(rig.attach("layer:2"))
        _ = try store.execute("canvas.add", args: ["width": 640, "height": 640], role: .programmer).get()
        _ = try store.execute("layer.set", args: ["layer": 2, "canvas": 2], role: .programmer).get()
        for _ in 0..<200 where rebuilt.withLock({ $0 }) < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rebuilt.withLock { $0 } == 2)
        #expect(rig.hub.targets.contains("layer:2"))
    }

    /// A solid-colour still for a layer (RGBA 8-bit).
    static func solid(_ context: MetalContext, _ rgba: [UInt8], file: Int) throws -> LayerPlayback {
        let texture = try #require(context.device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 16, height: 9, mipmapped: false)))
        texture.replace(region: MTLRegionMake2D(0, 0, 16, 9), mipmapLevel: 0, withBytes: Array(Array(repeating: rgba, count: 16 * 9).joined()), bytesPerRow: 64)
        let frame = DecodedFrame(poolIndex: 0)
        frame.frameIndex = 0
        frame.kind = .rgba
        frame.texture0 = texture
        return LayerPlayback(key: MediaKey(folder: 1, file: file), still: frame)
    }

    /// RGBA (0…255) of one pixel of a canvas-format texture; blocks on the GPU.
    static func pixel(_ texture: MTLTexture, x: Int, y: Int, context: MetalContext) throws -> [Int] {
        let buffer = try #require(context.device.makeBuffer(length: 8, options: .storageModeShared))
        let commandBuffer = try #require(context.queue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0), sourceSize: MTLSize(width: 1, height: 1, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: 8, destinationBytesPerImage: 8)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        return (0..<4).map { Int((Float(halves[$0]) * 255).rounded()) }
    }

    /// Layer 1 red over the whole canvas, layer 2 green at half size in the middle; a hub whose `configure` takes
    /// layer:<n> like the engine's. Idle work is skipped as in the engine, so unchanged ticks reuse the canvas.
    final class LayerRig {
        let context: MetalContext
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 2) }
        let compositor: Compositor
        let hub: PreviewHub
        // copyable locks: the hub's closures share them
        let made = OSAllocatedUnfairLock<[String: PreviewStreamer]>(initialState: [:])
        let previewSize = OSAllocatedUnfairLock(initialState: (160, 90))
        let connections: Rig
        private var sequence: UInt64 = 0
        private var ticks = 0

        init() throws {
            let context = try MetalContext()
            self.context = context
            let compositor = try Compositor(
                context: context, canvasWidth: 320, canvasHeight: 180, fps: 60, maxLayers: 2, metrics: MetricsRing(capacity: 64), parameters: parameters,
                logger: PreviewHubTests.logger)
            self.compositor = compositor
            let layers = [RenderLayer(index: 0), RenderLayer(index: 1)]
            layers[0].current = try PreviewHubTests.solid(context, [255, 0, 0, 255], file: 1)
            layers[1].current = try PreviewHubTests.solid(context, [0, 255, 0, 255], file: 2)
            for (i, layer) in layers.enumerated() { layer.wanted.store(MediaKey(folder: 1, file: i + 1).packed, ordering: .relaxed) }
            compositor.setLayers(layers)
            let parameters = parameters, previewSize = previewSize, made = made
            let make: @Sendable () throws -> PreviewStreamer = {
                let (w, h) = previewSize.withLock { $0 }
                return try PreviewStreamer(context: context, width: w, height: h, fps: 30, canvasFPS: 60, parameters: parameters, logger: PreviewHubTests.logger)
            }
            hub = PreviewHub(canvas: try make(), make: make)
            hub.configure = { target, streamer in
                guard let index = PreviewHub.layerIndex(of: target, layerCount: 2), (try? streamer.showLayer(index, of: compositor)) != nil else { return false }
                made.withLock { $0[target] = streamer }
                return true
            }
            compositor.previewTap = { [hub] canvas, buffer, target in hub.tap(canvas: canvas, commandBuffer: buffer, target: target) }
            compositor.skipsIdleWork = true
            compositor.previewWanted = { [hub] in hub.wantsFrames }
            connections = try Rig()
            set()
        }

        /// Writes the whole picture again (a triple-buffer slot holds an older state), then `change`.
        func set(_ change: (ParameterSnapshotSlot) -> Void = { _ in }) {
            sequence += 1
            let sequence = sequence
            parameters.write { slot in
                slot.sequence = sequence
                for i in 0..<2 {
                    slot.layers[i] = LayerParameters()
                    slot.layers[i].intensity = 1
                    slot.layers[i].folder = 1
                    slot.layers[i].file = UInt8(i + 1)
                    slot.layers[i].fitMode = .stretch
                }
                slot.layers[1].scaleX = 0.5
                slot.layers[1].scaleY = 0.5
                change(slot)
            }
        }

        func attach(_ target: String, stream: UInt32 = 1) -> Bool {
            hub.attach(target: target, connection: connections.connection(), stream: stream, jpeg: false) { _ in }
        }

        func tick(_ n: Int) {
            for _ in 0..<n {
                compositor.tick(target: 100 + Double(ticks) / 60, drawable: nil)
                ticks += 1
            }
        }

        /// RGBA of `target`'s layer picture at a fraction of its size.
        func pixel(_ target: String, _ fx: Double, _ fy: Double) throws -> [Int] {
            let texture = try #require(made.withLock { $0[target] }?.layerTexture)
            return try PreviewHubTests.pixel(texture, x: Int(Double(texture.width) * fx), y: Int(Double(texture.height) * fy), context: context)
        }
    }

    static let red = [255, 0, 0, 255], green = [0, 255, 0, 255], black = [0, 0, 0, 255]

    /// layer:<n> shows that layer alone, also on ticks that reuse the canvas; bad targets are refused.
    @Test func layerTargetShowsOnlyThatLayerAndBadTargetsAreRefused() throws {
        let rig = try LayerRig()
        for bad in ["layer:0", "layer:3", "layer:x", "layer:", "layer:-1"] {
            #expect(!rig.attach(bad), "\(bad) is refused")
        }
        #expect(rig.attach("layer:1"))
        #expect(rig.attach("layer:2", stream: 2))
        rig.tick(8)
        #expect(rig.hub.framesIn == 2 * 4, "canvas streamer has no subscriber; both layer streamers tap every second tick")
        #expect(rig.compositor.reusedCanvases.load(ordering: .relaxed) > 0, "the layer draws ran on reuse ticks too")
        #expect(try rig.pixel("layer:1", 0.05, 0.05) == Self.red, "layer 1: red everywhere")
        #expect(try rig.pixel("layer:1", 0.5, 0.5) == Self.red, "layer 2 is absent from layer 1's preview")
        #expect(try rig.pixel("layer:2", 0.5, 0.5) == Self.green, "layer 2 in the middle")
        #expect(try rig.pixel("layer:2", 0.05, 0.05) == Self.black, "layer 1 is absent: black around layer 2")
    }

    /// The preview draws Normal: a Multiply layer is black on the canvas over red × green, but shows its own picture.
    /// Intensity 0 is black, as on the canvas.
    @Test func layerPreviewForcesNormalBlendAndIntensityZeroIsBlack() throws {
        let rig = try LayerRig()
        rig.set { slot in slot.layers[1].blendMode = .multiply }
        #expect(rig.attach("layer:1"))
        #expect(rig.attach("layer:2", stream: 2))
        rig.tick(4)
        let canvas = rig.compositor.readback()
        let centre = (canvas.height / 2 * canvas.width + canvas.width / 2) * 4
        #expect(Array(canvas.rgba[centre..<centre + 3]) == [0, 0, 0], "on the canvas green multiplied over red is black")
        #expect(try rig.pixel("layer:2", 0.5, 0.5) == Self.green, "the layer preview shows the multiply layer as Normal")
        #expect(try rig.pixel("layer:1", 0.05, 0.05) == Self.red)

        rig.set { slot in slot.layers[0].intensity = 0 }
        rig.tick(4)
        #expect(try rig.pixel("layer:1", 0.05, 0.05) == Self.black, "intensity 0: black")
        #expect(try rig.pixel("layer:2", 0.5, 0.5) == Self.green)
    }

    /// Multiple canvases: a layer on canvas 2 is previewed at canvas 2's aspect (the hub makes it with `makeCanvas`),
    /// drawn as on that canvas; layer 1 stays on canvas 1.
    @Test func aLayerPreviewTakesItsCanvasAspect() throws {
        let rig = try LayerRig()
        try rig.compositor.reconfigure(.init(fps: 60, canvases: [.init(id: 1, width: 320, height: 180), .init(id: 2, width: 240, height: 240)]))
        rig.compositor.layerCanvas = [1, 2]
        let context = rig.context, parameters = rig.parameters
        rig.hub.canvasOfLayer = { target in target == "layer:2" ? 2 : 1 }
        rig.hub.makeCanvas = { id in
            id == 2 ? try PreviewStreamer(context: context, width: 120, height: 120, fps: 30, canvasFPS: 60, parameters: parameters, logger: Self.logger) : nil
        }
        #expect(rig.attach("layer:1"))
        #expect(rig.attach("layer:2", stream: 2))
        rig.tick(4)
        let square = try #require(rig.made.withLock { $0["layer:2"] })
        #expect((square.width, square.height) == (120, 120) && square.framesIn.load(ordering: .relaxed) == 2)
        #expect(try rig.pixel("layer:2", 0.5, 0.5) == Self.green)
        #expect(try rig.pixel("layer:2", 0.1, 0.1) == Self.black, "half size on its square canvas")
        #expect(try rig.pixel("layer:1", 0.5, 0.5) == Self.red)
        #expect(rig.made.withLock { $0["layer:1"] }?.height == 90, "layer 1 at canvas 1's aspect")
    }

    /// B31 with a layer target: after a canvas change of aspect the old streamer draws nothing (not stretched), and
    /// `rebuild` makes it again at the new size with its subscriber.
    @Test func rebuildRemakesALayerStreamerAtTheNewSize() throws {
        let rig = try LayerRig()
        #expect(rig.attach("layer:2"))
        rig.tick(4)
        let old = try #require(rig.made.withLock { $0["layer:2"] })
        try rig.compositor.reconfigure(width: 320, height: 240, fps: 60)
        let framesBefore = rig.hub.framesIn
        rig.tick(4)
        #expect(rig.hub.framesIn == framesBefore, "4:3 canvas, 16:9 layer streamer: no frames until the rebuild")
        #expect(old.skipped.load(ordering: .relaxed) == 2)

        rig.previewSize.withLock { $0 = (160, 120) }
        try rig.hub.rebuild()
        let fresh = try #require(rig.made.withLock { $0["layer:2"] })
        #expect(fresh !== old && fresh.layer == 1 && fresh.height == 120)
        #expect(fresh.subscriberList.map(\.stream) == [1], "the subscriber moved over")
        rig.tick(4)
        #expect(fresh.framesIn.load(ordering: .relaxed) == 2)
        #expect(try rig.pixel("layer:2", 0.5, 0.5) == Self.green)
        #expect(try rig.pixel("layer:2", 0.05, 0.05) == Self.black)
    }

    /// B31: after a canvas change every streamer is made again (new size) and keeps its subscribers.
    @Test func rebuildRemakesStreamersAndMovesSubscribers() throws {
        let context = try MetalContext()
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) }
        let height = Mutex(90)
        let hub = PreviewHub(canvas: try PreviewStreamer(context: context, width: 160, height: 90, fps: 30, canvasFPS: 60, parameters: parameters, logger: Self.logger)) {
            try PreviewStreamer(context: context, width: 160, height: height.withLock { $0 }, fps: 30, canvasFPS: 60, parameters: parameters, logger: Self.logger)
        }
        hub.configure = { target, _ in target == "output:1" }
        let rig = try Rig()
        let (a, b) = (rig.connection(), rig.connection())
        #expect(hub.attach(target: "canvas", connection: a, stream: 1, jpeg: false) { _ in })
        #expect(hub.attach(target: "output:1", connection: b, stream: 2, jpeg: true) { _ in })
        let oldCanvas = hub.canvas
        height.withLock { $0 = 120 }
        try hub.rebuild()
        #expect(hub.canvas !== oldCanvas && hub.canvas.height == 120)
        #expect(hub.canvas.subscriberList.map(\.stream) == [1])
        #expect(hub.targets.sorted() == ["canvas", "output:1"])
        hub.unsubscribe(connection: b, stream: 2)
        #expect(hub.targets == ["canvas"], "the moved output subscriber is the one that counts")
    }
}
