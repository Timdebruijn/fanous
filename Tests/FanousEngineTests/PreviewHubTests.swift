// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Metal
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

    /// layer:<n> shows that layer alone: layer 1 (red, full canvas) under layer 2 (green, half size in the middle).
    @Test func layerTargetShowsOnlyThatLayerAndBadTargetsAreRefused() throws {
        let context = try MetalContext()
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 2) }
        let compositor = try Compositor(
            context: context, canvasWidth: 320, canvasHeight: 180, fps: 60, maxLayers: 2, metrics: MetricsRing(capacity: 64), parameters: parameters, logger: Self.logger)
        let layers = [RenderLayer(index: 0), RenderLayer(index: 1)]
        layers[0].current = try Self.solid(context, [255, 0, 0, 255], file: 1)
        layers[1].current = try Self.solid(context, [0, 255, 0, 255], file: 2)
        for (i, layer) in layers.enumerated() { layer.wanted.store(MediaKey(folder: 1, file: i + 1).packed, ordering: .relaxed) }
        compositor.setLayers(layers)
        parameters.write { slot in
            slot.sequence = 1
            for i in 0..<2 {
                slot.layers[i].intensity = 1
                slot.layers[i].folder = 1
                slot.layers[i].file = UInt8(i + 1)
                slot.layers[i].fitMode = .stretch
            }
            slot.layers[1].scaleX = 0.5
            slot.layers[1].scaleY = 0.5
        }

        let make: @Sendable () throws -> PreviewStreamer = {
            try PreviewStreamer(context: context, width: 160, height: 90, fps: 30, canvasFPS: 60, parameters: parameters, logger: Self.logger)
        }
        let hub = PreviewHub(canvas: try make(), make: make)
        let made = Mutex<[String: PreviewStreamer]>([:])
        hub.configure = { target, streamer in
            guard let index = PreviewHub.layerIndex(of: target, layerCount: 2), (try? streamer.showLayer(index, of: compositor)) != nil else { return false }
            made.withLock { $0[target] = streamer }
            return true
        }
        compositor.previewTap = { [hub] canvas, buffer, target in hub.tap(canvas: canvas, commandBuffer: buffer, target: target) }
        let rig = try Rig()
        for bad in ["layer:0", "layer:3", "layer:x", "layer:", "layer:-1"] {
            #expect(!hub.attach(target: bad, connection: rig.connection(), stream: 1, jpeg: true) { _ in }, "\(bad) is refused")
        }
        #expect(hub.attach(target: "layer:1", connection: rig.connection(), stream: 1, jpeg: false) { _ in })
        #expect(hub.attach(target: "layer:2", connection: rig.connection(), stream: 2, jpeg: false) { _ in })
        for i in 0..<4 { compositor.tick(target: 100 + Double(i) / 60, drawable: nil) }
        #expect(hub.framesIn == 2 * 2, "canvas streamer has no subscriber; both layer streamers tap every second tick")

        let streamers = try ["layer:1", "layer:2"].map { target in
            try #require(made.withLock { $0[target] }?.layerTexture)
        }
        let (corner, centre) = ((10, 10), (80, 45))
        #expect(try Self.pixel(streamers[0], x: corner.0, y: corner.1, context: context) == [255, 0, 0, 255], "layer 1: red everywhere")
        #expect(try Self.pixel(streamers[0], x: centre.0, y: centre.1, context: context) == [255, 0, 0, 255], "layer 2 is absent from layer 1's preview")
        #expect(try Self.pixel(streamers[1], x: centre.0, y: centre.1, context: context) == [0, 255, 0, 255], "layer 2 in the middle")
        #expect(try Self.pixel(streamers[1], x: corner.0, y: corner.1, context: context) == [0, 0, 0, 255], "layer 1 is absent: black around layer 2")
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
