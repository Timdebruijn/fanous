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

    /// The hub's `make`: a streamer of the asked size at 30 of 60 fps.
    static func make(_ context: MetalContext, _ parameters: TripleBuffer<ParameterSnapshotSlot>) -> @Sendable (Int, Int) throws -> PreviewStreamer {
        { width, height in try PreviewStreamer(context: context, width: width, height: height, fps: 30, canvasFPS: 60, parameters: parameters, logger: logger) }
    }

    struct Rig {
        let context: MetalContext
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) }
        let server: StateServer
        let hub: PreviewHub
        let compositor: Compositor
        /// Picture sizes by target (the engine's `previewShape`); any other target is 160×90 and `configure` decides,
        /// except "canvas:<id>" (no such canvas).
        let shapes = OSAllocatedUnfairLock<[String: (width: Int, height: Int)]>(initialState: [:])

        init() throws {
            context = try MetalContext()
            let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: PreviewHubTests.logger)
            let project = ProjectDocument.initial(patch: .standard(layers: 1, outputs: 1), layerCount: 1, libraryRoot: "/tmp/lib", policy: .dmx)
            server = StateServer(store: StateStore(project: project, logger: PreviewHubTests.logger), auth: auth, caps: ["schema": 1], logger: PreviewHubTests.logger)
            let context = context, parameters = parameters, shapes = shapes
            hub = try PreviewHub(make: PreviewHubTests.make(context, parameters)) { target in
                shapes.withLock { $0[target] } ?? (target.hasPrefix("canvas:") ? nil : (160, 90))
            }
            let compiler = try OutputCompiler(device: context.device)
            hub.configure = { target, streamer in
                guard target == "output:1", let set = try? OutputSet(plans: [compiler.compile(OutputConfig(id: 1), index: 1, drawable: (streamer.width, streamer.height))]) else { return false }
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
            hub.attach(target: target, connection: connection, stream: stream, jpeg: jpeg) { _, _ in }
        }

        /// Subscribes with a wanted width; the streamer it got (nil: refused).
        func streamer(_ target: String, width: Int?, _ connection: StateServer.Connection, stream: UInt32 = 1) -> PreviewStreamer? {
            served(target, width: width, connection, stream: stream)?.streamer
        }

        /// Subscribes to H.264 with a wanted width; the streamer it got and whether it is served as JPEG (nil: refused).
        func served(_ target: String, width: Int?, _ connection: StateServer.Connection, stream: UInt32 = 1) -> (streamer: PreviewStreamer, jpeg: Bool)? {
            var got: (PreviewStreamer, Bool)?
            _ = hub.attach(target: target, width: width, connection: connection, stream: stream, jpeg: false) { got = ($0, $1) }
            return got
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
        rig.shapes.withLock { $0["canvas:2"] = (320, 320) }
        rig.hub.canvasTexture = { [compositor = rig.compositor] id in compositor.tickCanvas(id) }
        let (a, b) = (rig.connection(), rig.connection())
        #expect(rig.attach("canvas:1", a))
        #expect(rig.hub.targets == ["canvas"], "canvas:1 is the canvas streamer")
        let square = try #require(rig.streamer("canvas:2", width: nil, b, stream: 2))
        #expect((square.width, square.height, square.canvasID) == (480, 480, 2), "the default class in canvas 2's shape, at most 640×360's pixels")
        #expect(!rig.attach("canvas:3", rig.connection()))
        #expect(!rig.attach("canvas:x", rig.connection()))
        rig.tick(30)
        let second = rig.hub.framesIn - rig.hub.canvas.framesIn.load(ordering: .relaxed)
        #expect(second == 15, "the canvas 2 streamer taps its canvas (got \(second))")
        try rig.hub.rebuild()
        #expect(Set(rig.hub.targets) == ["canvas", "canvas:2"])
        #expect(rig.streamer("canvas:2", width: nil, b, stream: 4) !== square, "made again")

        // canvas 2 removed: its streamer goes (its viewer gets badTarget) instead of showing a frozen picture
        rig.shapes.withLock { $0["canvas:2"] = nil }
        try rig.hub.rebuild()
        #expect(rig.hub.targets == ["canvas"])
    }

    /// B62: the UI subscribes to a new canvas as soon as the live document lists it, which can be while the canvas switch
    /// is still rebuilding the previews. That streamer was made for the new canvases: the rebuild must not drop it (and
    /// tell its viewer the canvas is gone) because it was not there when the rebuild started.
    @Test func aCanvasSubscribedDuringARebuildIsKept() throws {
        let rig = try Rig()
        let viewer = rig.connection()
        final class Weak: @unchecked Sendable { weak var hub: PreviewHub? }
        let ref = Weak()
        let rendered = Mutex<Set<Int>>([2])
        let rebuilding = Mutex(false)
        let subscribed = Mutex<Bool?>(nil)
        let hub = try PreviewHub(make: Self.make(rig.context, rig.parameters)) { target in
            guard target.hasPrefix("canvas:") else { return (160, 90) }
            let id = Int(target.dropFirst(7)) ?? 0
            guard rendered.withLock({ $0.contains(id) }) else { return nil }
            if id == 2, rebuilding.withLock({ $0 }), subscribed.withLock({ $0 }) == nil {
                // canvas 3 starts rendering and its viewer subscribes while the rebuild makes canvas 2 again
                rendered.withLock { _ = $0.insert(3) }
                subscribed.withLock { $0 = false }
                let attached = ref.hub?.attach(target: "canvas:3", connection: viewer, stream: 3, jpeg: true) { _, _ in } ?? false
                subscribed.withLock { $0 = attached }
            }
            return (160, 160)
        }
        ref.hub = hub
        #expect(hub.attach(target: "canvas:2", connection: rig.connection(), stream: 2, jpeg: true) { _, _ in })
        rebuilding.withLock { $0 = true }
        try hub.rebuild()
        #expect(subscribed.withLock { $0 } == true)
        #expect(Set(hub.targets) == ["canvas", "canvas:2", "canvas:3"])
    }

    /// A layer.set with a layer:<n> subscriber: the preview rebuild reads the project, so it must not run on the
    /// store's queue (it did, and deadlocked). Wired like the engine: Control hops to the main actor.
    @Test(.timeLimit(.minutes(1))) func layerSetWithALayerSubscriberDoesNotHang() async throws {
        let rig = try LayerRig()
        let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: Self.logger)
        let store = StateStore(project: ProjectDocument.initial(patch: .standard(layers: 2, outputs: 1), layerCount: 2, libraryRoot: "/x", policy: .dmx), logger: Self.logger)
        ProjectDocument.registerCommands(on: store, auth: auth)
        let compositor = rig.compositor, made = rig.made
        rig.hub.configure = { target, streamer in
            guard let index = PreviewHub.layerIndex(of: target, layerCount: store.project["layerCount"]?.int ?? 0), (try? streamer.showLayer(index, of: compositor)) != nil else { return false }
            made.withLock { $0[target] = streamer }
            return true
        }
        final class Rebuilt: Sendable { let count = Atomic<Int>(0) }  // Swift 6.3 (CI) refuses a local Mutex sent into a Task
        let rebuilt = Rebuilt()
        store.onProjectChanged = { [hub = rig.hub] _ in
            Task { @MainActor in
                try? hub.rebuild()
                rebuilt.count.add(1, ordering: .relaxed)
            }
        }
        #expect(rig.attach("layer:2"))
        _ = try store.execute("canvas.add", args: ["width": 640, "height": 640], role: .programmer).get()
        _ = try store.execute("layer.set", args: ["layer": 2, "canvas": 2], role: .programmer).get()
        for _ in 0..<200 where rebuilt.count.load(ordering: .relaxed) < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rebuilt.count.load(ordering: .relaxed) == 2)
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
        /// Picture sizes by target; a target without its own is canvas 1's ("canvas").
        let shapes = OSAllocatedUnfairLock<[String: (width: Int, height: Int)]>(initialState: ["canvas": (320, 180)])
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
            let shapes = shapes, made = made
            hub = try PreviewHub(make: PreviewHubTests.make(context, parameters)) { target in shapes.withLock { $0[target] ?? $0["canvas"] } }
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
            hub.attach(target: target, connection: connections.connection(), stream: stream, jpeg: false) { _, _ in }
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

    /// Multiple canvases: a layer on canvas 2 is previewed at canvas 2's aspect (the engine's `previewShape` gives the
    /// hub its canvas's size), drawn as on that canvas; layer 1 stays on canvas 1.
    @Test func aLayerPreviewTakesItsCanvasAspect() throws {
        let rig = try LayerRig()
        try rig.compositor.reconfigure(.init(fps: 60, canvases: [.init(id: 1, width: 320, height: 180), .init(id: 2, width: 240, height: 240)]))
        rig.compositor.layerCanvas = [1, 2]
        rig.shapes.withLock { $0["layer:2"] = (240, 240) }
        #expect(rig.attach("layer:1"))
        #expect(rig.attach("layer:2", stream: 2))
        rig.tick(4)
        let square = try #require(rig.made.withLock { $0["layer:2"] })
        #expect((square.width, square.height) == (480, 480) && square.framesIn.load(ordering: .relaxed) == 2)
        #expect(try rig.pixel("layer:2", 0.5, 0.5) == Self.green)
        #expect(try rig.pixel("layer:2", 0.1, 0.1) == Self.black, "half size on its square canvas")
        #expect(try rig.pixel("layer:1", 0.5, 0.5) == Self.red)
        #expect(rig.made.withLock { $0["layer:1"] }?.height == 360, "layer 1 at canvas 1's aspect")
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

        rig.shapes.withLock { $0["canvas"] = (320, 240) }
        try rig.hub.rebuild()
        let fresh = try #require(rig.made.withLock { $0["layer:2"] })
        #expect(fresh !== old && fresh.layer == 1 && fresh.height == 414)
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
        let shape = Mutex((160, 90))
        let hub = try PreviewHub(make: Self.make(context, parameters)) { _ in shape.withLock { $0 } }
        hub.configure = { target, _ in target == "output:1" }
        let rig = try Rig()
        let (a, b) = (rig.connection(), rig.connection())
        #expect(hub.attach(target: "canvas", connection: a, stream: 1, jpeg: false) { _, _ in })
        #expect(hub.attach(target: "output:1", connection: b, stream: 2, jpeg: true) { _, _ in })
        let oldCanvas = hub.canvas
        shape.withLock { $0 = (160, 120) }
        try hub.rebuild()
        #expect(hub.canvas !== oldCanvas && hub.canvas.height == 414)
        #expect(hub.canvas.subscriberList.map(\.stream) == [1])
        #expect(hub.targets.sorted() == ["canvas", "output:1"])
        hub.unsubscribe(connection: b, stream: 2)
        #expect(hub.targets == ["canvas"], "the moved output subscriber is the one that counts")
    }

    /// B32: one streamer per (target, size class); at 4 encoders a new size of a target that has one attaches to its
    /// nearest size; a size goes with its last subscriber. B70: a new target past the limit gets no encoder.
    @Test func sizeClassesHaveTheirOwnStreamerUpToFourEncoders() throws {
        let rig = try Rig()
        rig.shapes.withLock { $0["canvas:2"] = (160, 160) }
        let (a, b, c) = (rig.connection(), rig.connection(), rig.connection())
        #expect(rig.streamer("canvas", width: nil, a) === rig.hub.canvas, "no width: the canvas streamer (640)")
        let small = try #require(rig.streamer("canvas", width: 300, a, stream: 2))
        #expect((small.width, small.height) == (320, 180))
        #expect(rig.streamer("canvas", width: 1600, b)?.width == 1280, "clamped to the largest class")
        #expect(rig.streamer("output:1", width: 700, b, stream: 2)?.width == 960)
        #expect(rig.hub.encoders == 4)
        #expect(rig.hub.keys == [.init(target: "canvas", width: 320), .init(target: "canvas", width: 1280), .init(target: "output:1", width: 960)])

        // at the limit: the nearest size the target has (the larger on a tie), no new encoder
        #expect(rig.streamer("output:1", width: 200, c)?.width == 960)
        #expect(rig.streamer("canvas", width: 900, c, stream: 2)?.width == 1280, "960 wanted: 640 and 1280 are as near")
        #expect(rig.streamer("canvas", width: 200, c, stream: 3) === small && rig.streamer("canvas", width: 400, c, stream: 5) === rig.hub.canvas)
        #expect(rig.hub.encoders == 4)
        // B70: a new target with no encoding size and no canvas stream of its own canvas: JPEG on its own streamer
        let refused = try #require(rig.served("canvas:2", width: 320, c, stream: 4))
        #expect(refused.streamer.width == 240 && refused.jpeg)
        #expect(rig.hub.encoders == 4)

        rig.hub.remove(connection: c)
        rig.hub.unsubscribe(connection: a, stream: 2)
        #expect(rig.hub.keys == [.init(target: "canvas", width: 1280), .init(target: "output:1", width: 960)], "320 and canvas:2 lost their last subscriber")
    }

    /// B32: an output preview has the output's shape, and a changed shape (region) is a reason to rebuild.
    @Test func anOutputPreviewHasTheOutputsShape() throws {
        let rig = try Rig()
        rig.shapes.withLock { $0["output:1"] = (1440, 1080) }
        let a = rig.connection()
        let fourThree = try #require(rig.streamer("output:1", width: nil, a))
        #expect((fourThree.width, fourThree.height) == (554, 414))
        #expect(!rig.hub.shapeChanged)
        rig.shapes.withLock { $0["output:1"] = (1920, 1080) }
        #expect(rig.hub.shapeChanged)
        try rig.hub.rebuild()
        #expect(!rig.hub.shapeChanged)
        let wide = try #require(rig.streamer("output:1", width: nil, a, stream: 2))
        #expect((wide.width, wide.height) == (640, 360) && wide.subscriberList.map(\.stream) == [1, 2], "the subscriber moved over")
    }

    /// B32: the streamer is made outside the hub's lock; when its target changes shape meanwhile (a region edit whose
    /// rebuild would keep a streamer it did not see), it is made again before it is published.
    @Test func aShapeChangeWhileAttachingMakesTheStreamerAgain() throws {
        let rig = try Rig()
        rig.shapes.withLock { $0["output:1"] = (1920, 1080) }
        let configured = OSAllocatedUnfairLock(initialState: 0)
        rig.hub.configure = { [shapes = rig.shapes] target, _ in
            configured.withLock { $0 += 1 }
            if configured.withLock({ $0 }) == 1 { shapes.withLock { $0[target] = (1440, 1080) } }  // the region changes now
            return true
        }
        let streamer = try #require(rig.streamer("output:1", width: nil, rig.connection()))
        #expect((streamer.width, streamer.height) == (554, 414) && configured.withLock { $0 } == 2)
        #expect(!rig.hub.shapeChanged)
    }

    /// B70: a rig with three outputs (output:3 on canvas 2), canvas 1, 2 and 3, and one connection per viewer.
    struct LimitRig {
        let rig: Rig
        init() throws {
            rig = try Rig()
            rig.shapes.withLock { $0["canvas:2"] = (160, 90); $0["canvas:3"] = (160, 90) }
            rig.hub.configure = { target, _ in target.hasPrefix("output:") }
            rig.hub.canvasOf = { $0 == "output:3" ? 2 : 1 }
        }

        /// Waits up to 3 s for `done` (the re-balance runs on a global queue).
        func wait(_ done: () -> Bool) {
            for _ in 0..<300 where !done() { usleep(10_000) }
        }
    }

    /// B70: the encoder limit holds across targets. Past 4 encoders a new (target, size) gets its target's nearest encoding
    /// size, else its canvas's nearest encoding size, else JPEG on its own streamer (no VideoToolbox session).
    @Test func theEncoderLimitHoldsAcrossTargets() throws {
        let r = try LimitRig(), rig = r.rig
        var viewers: [PreviewStreamer] = []
        func serve(_ target: String, _ width: Int?) throws -> (streamer: PreviewStreamer, jpeg: Bool) {
            let got = try #require(rig.served(target, width: width, rig.connection()))
            viewers.append(got.streamer)
            #expect(rig.hub.encoders <= PreviewSize.maxEncoders, "\(target) \(width ?? 0): \(rig.hub.encoders) encoders")
            return got
        }
        #expect(try serve("canvas", nil).streamer === rig.hub.canvas)
        let output1 = try serve("output:1", 640).streamer
        _ = try serve("output:2", 640)
        let canvas2 = try serve("canvas:2", 640).streamer
        #expect(rig.hub.encoders == 4)
        // a fifth: the same target's nearest size
        let same = try serve("output:1", 320)
        #expect(same.streamer === output1 && !same.jpeg)
        // a target without one: its canvas's stream, canvas 1 …
        let onCanvas1 = try serve("output:4", 960)
        #expect(onCanvas1.streamer === rig.hub.canvas && !onCanvas1.jpeg)
        // … or canvas 2
        let onCanvas2 = try serve("output:3", 1280)
        #expect(onCanvas2.streamer === canvas2 && !onCanvas2.jpeg)
        // nothing fits: JPEG on its own streamer
        let refused = try serve("canvas:3", 640)
        #expect(refused.jpeg && refused.streamer.canvasID == 3)
        #expect(rig.hub.keys.count == 4, "output:1, output:2, canvas:2 and canvas:3 (JPEG); no streamer for the fallbacks")
        // the sessions that exist (made off the preview queue, B66) are within the limit too
        let streamers = Dictionary(viewers.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { a, _ in a }).values
        #expect(streamers.count == 5)
        r.wait { streamers.filter(\.hasEncoder).count >= 4 }
        let sessions = streamers.filter(\.hasEncoder).count
        #expect(sessions == 4 && !refused.streamer.hasEncoder, "\(sessions) VideoToolbox sessions")
    }

    /// B70 review: at the limit with no H.264 viewer on the canvas streamer, a canvas viewer is on its own stream (the
    /// canvas one is always counted), not on a fallback that a release would move (and freeze until a key frame).
    @Test func aCanvasViewerAtTheLimitIsNeverAFallback() throws {
        let r = try LimitRig(), rig = r.rig
        let (b, c, d) = (rig.connection(), rig.connection(), rig.connection())
        _ = try #require(rig.streamer("output:1", width: 640, b))
        _ = try #require(rig.streamer("output:2", width: 640, c))
        _ = try #require(rig.streamer("canvas:2", width: 640, d))
        #expect(rig.hub.encoders == 4 && !rig.hub.canvas.hasSubscribers)
        let a = rig.connection()
        let got = try #require(rig.served("canvas", width: nil, a))
        #expect(got.streamer === rig.hub.canvas && !got.jpeg)
        #expect(rig.hub.fallbackCount == 0)
        rig.hub.remove(connection: c)
        #expect(rig.hub.canvas.subscriberList.map(\.stream) == [1] && rig.hub.fallbackCount == 0)
    }

    /// B70: when an encoder is released, the oldest subscriber on a fallback gets its own (target, size), up to the limit;
    /// one refused to JPEG gets H.264 the same way.
    @Test func aReleasedEncoderGoesToTheOldestFallback() throws {
        let r = try LimitRig(), rig = r.rig
        let (a, b, c, d) = (rig.connection(), rig.connection(), rig.connection(), rig.connection())
        let (e, f, g) = (rig.connection(), rig.connection(), rig.connection())
        #expect(rig.streamer("canvas", width: nil, a) === rig.hub.canvas)
        let output1 = try #require(rig.streamer("output:1", width: 640, b))
        _ = try #require(rig.streamer("output:2", width: 640, c))
        _ = try #require(rig.streamer("canvas:2", width: 640, d))
        #expect(rig.streamer("output:1", width: 320, e) === output1, "fallback: output:1 at 640")
        #expect(rig.streamer("output:4", width: 960, f) === rig.hub.canvas, "fallback: canvas 1")
        let refused = try #require(rig.served("canvas:3", width: 640, g))
        #expect(refused.jpeg)

        // output:2 goes: e (the oldest fallback) gets output:1 at 320; f stays on canvas 1 (the limit again)
        rig.hub.remove(connection: c)
        let own = PreviewHub.Key(target: "output:1", width: 320)
        r.wait { rig.hub.keys.contains(own) }
        #expect(rig.hub.keys.contains(own))
        #expect(!output1.subscriberList.contains { $0.connection === e }, "e left its fallback")
        #expect(rig.hub.encoders == 4)
        #expect(rig.hub.canvas.subscriberList.contains { $0.connection === f })
        let x = rig.connection()
        let moved = try #require(rig.streamer("output:1", width: 320, x))
        #expect(moved.subscriberList.contains { $0.connection === e && !$0.jpeg }, "e is on its own size, H.264")

        // output:1 at 640 goes: f gets output:4 at 960
        rig.hub.remove(connection: b)
        r.wait { rig.hub.keys.contains(.init(target: "output:4", width: 960)) }
        #expect(rig.hub.keys.contains(.init(target: "output:4", width: 960)))
        #expect(!rig.hub.canvas.subscriberList.contains { $0.connection === f })
        #expect(rig.hub.encoders == 4)

        // output:1 at 320 goes with its last viewer: g, refused to JPEG, gets H.264 on its own streamer
        rig.hub.remove(connection: e)
        #expect(refused.streamer.subscriberList.contains { $0.connection === g && $0.jpeg }, "x still keeps output:1 at 320")
        rig.hub.remove(connection: x)
        r.wait { refused.streamer.subscriberList.contains { $0.connection === g && !$0.jpeg } }
        #expect(refused.streamer.subscriberList.map(\.jpeg) == [false])
        #expect(rig.hub.encoders == 4)
    }

    /// B88: canvas 2 removed while output:3's viewer watches canvas 2's stream as its fallback: the viewer keeps an
    /// output:3 preview (its own encoder when canvas 2's is free, else another fallback), not "no longer exists".
    @Test func aViewerWhoseFallbackCanvasIsRemovedKeepsItsOwnTarget() throws {
        for waiting in [false, true] {
            let r = try LimitRig(), rig = r.rig
            let (a, b, c, d) = (rig.connection(), rig.connection(), rig.connection(), rig.connection())
            let (e, f) = (rig.connection(), rig.connection())
            #expect(rig.streamer("canvas", width: nil, a) === rig.hub.canvas)
            let output1 = try #require(rig.streamer("output:1", width: 640, b))
            _ = try #require(rig.streamer("output:2", width: 640, c))
            let canvas2 = try #require(rig.streamer("canvas:2", width: 640, d))
            // with `waiting`, an older fallback viewer takes the encoder canvas 2 frees first
            if waiting { #expect(rig.streamer("output:1", width: 320, f) === output1) }
            #expect(rig.streamer("output:3", width: 1280, e) === canvas2, "fallback: canvas 2")
            #expect(rig.hub.encoders == 4)

            // canvas 2 goes; its slices move to canvas 1
            rig.shapes.withLock { $0["canvas:2"] = nil }
            rig.hub.canvasOf = { _ in 1 }
            try rig.hub.rebuild()
            #expect(rig.hub.encoders <= PreviewSize.maxEncoders, "\(rig.hub.encoders) encoders")
            let x = rig.connection()
            let got = try #require(rig.served("output:3", width: 1280, x))
            if waiting {
                #expect(rig.hub.keys.contains(.init(target: "output:1", width: 320)), "f got its own size")
                #expect(got.streamer === rig.hub.canvas, "e is on canvas 1's stream now")
                #expect(rig.hub.fallbackCount == 2, "e and x")
            } else {
                #expect(rig.hub.keys.contains(.init(target: "output:3", width: 1280)), "e got its own encoder")
                #expect(rig.hub.fallbackCount == 0)
            }
            #expect(got.streamer.subscriberList.contains { $0.connection === e && !$0.jpeg }, "e streams H.264")
            #expect(!rig.hub.targets.contains("canvas:2"))
            let before = got.streamer.framesIn.load(ordering: .relaxed)
            rig.tick(30)
            #expect(got.streamer.framesIn.load(ordering: .relaxed) > before, "e gets frames")
            #expect(rig.hub.encoders <= PreviewSize.maxEncoders, "\(rig.hub.encoders) encoders")
        }
    }

    /// B88 review: an orphan that `choose` would refuse to JPEG is told its target is gone (as before B88), not moved to
    /// JPEG on the stream id it got H.264 on, where the browser drops JPEG frames and freezes (B86).
    @Test func anOrphanRefusedToJPEGIsToldGone() throws {
        let r = try LimitRig(), rig = r.rig
        let (a, b, c, d) = (rig.connection(), rig.connection(), rig.connection(), rig.connection())
        let (e, f) = (rig.connection(), rig.connection())
        #expect(rig.streamer("canvas", width: nil, a) === rig.hub.canvas)
        let output1 = try #require(rig.streamer("output:1", width: 640, b))
        _ = try #require(rig.streamer("output:2", width: 640, c))
        let canvas2 = try #require(rig.streamer("canvas:2", width: 640, d))
        #expect(rig.streamer("output:1", width: 320, f) === output1, "older fallback: takes the freed encoder")
        #expect(rig.streamer("output:3", width: 1280, e) === canvas2, "fallback: canvas 2")

        // canvas 2 goes, output:3 still on it (no canvas fallback left): the limit and no encoding stream of its own
        rig.shapes.withLock { $0["canvas:2"] = nil }
        try rig.hub.rebuild()
        #expect(rig.hub.keys.contains(.init(target: "output:1", width: 320)), "f got its own size")
        #expect(!rig.hub.keys.contains { $0.target == "output:3" }, "no JPEG streamer for e")
        #expect(!rig.hub.canvas.subscriberList.contains { $0.connection === e })
        #expect(rig.hub.fallbackCount == 0, "e left the fallbacks")
        #expect(rig.hub.encoders == 4)
    }

    /// B88: a rebuild that removes a target with an encoder gives it to a viewer waiting on a fallback.
    @Test func aRebuildThatFreesAnEncoderRebalances() throws {
        let r = try LimitRig(), rig = r.rig
        let (a, b, c, d, f) = (rig.connection(), rig.connection(), rig.connection(), rig.connection(), rig.connection())
        #expect(rig.streamer("canvas", width: nil, a) === rig.hub.canvas)
        let output1 = try #require(rig.streamer("output:1", width: 640, b))
        _ = try #require(rig.streamer("output:2", width: 640, c))
        _ = try #require(rig.streamer("canvas:2", width: 640, d))
        #expect(rig.streamer("output:1", width: 320, f) === output1, "fallback: output:1 at 640")
        #expect(rig.hub.encoders == 4 && rig.hub.fallbackCount == 1)

        rig.shapes.withLock { $0["canvas:2"] = nil }
        try rig.hub.rebuild()
        #expect(rig.hub.keys.contains(.init(target: "output:1", width: 320)), "f got its own size")
        let remade = try #require(rig.streamer("output:1", width: 640, rig.connection()))  // the rebuild made it again
        #expect(!remade.subscriberList.contains { $0.connection === f } && rig.hub.fallbackCount == 0, "f left its fallback")
        #expect(rig.hub.encoders == 4)
    }
}
