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
