// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreMedia
import CoreVideo
import FanousCore
import Foundation
import Logging
import Metal
import ScreenCaptureKit
import Synchronization
import Testing

@testable import FanousEngine

/// Displays as folder 0 files 21–28 (B73 step 3a, DESIGN.md §8.2.1) without a stream or the screen permission (neither
/// exists on CI): the catalog from fake display lists, the project key, the feed, the forget and authorize rules, the
/// readiness item, `ScreenInput`'s texture path with a synthetic BGRA buffer, the loader with a fake factory, and the
/// grant poll with an injected preflight.
struct ScreenInputTests {
    static let logger = Logger(label: "screen-test")

    static func display(_ id: UInt32, _ uuid: String, _ name: String) -> DisplayInfo {
        DisplayInfo(id: id, uuid: uuid, name: name, pixelWidth: 1920, pixelHeight: 1080, scale: 1, hz: 60, isMain: false, isBuiltin: false, modes: [])
    }

    static func input(_ device: MTLDevice, now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) -> ScreenInput {
        ScreenInput(name: "synthetic", metal: device, logger: logger, noSignalAfter: .infinity, now: now)
    }

    // MARK: Catalog, project, feed

    /// The capture catalog's rules on displays: 21–28 by uuid, a rename keeps the number. A display an output is bound
    /// to is left out: bound from the start it gets no number, bound later it keeps its number as not running (not
    /// gone), so the number stays stable; unbound, it runs again on it.
    @Test func screensCatalogNumbersDisplaysLessTheOutputBoundOnes() throws {
        let a = Self.display(1, "uuid-a", "Built-in Retina Display"), b = Self.display(2, "uuid-b", "DELL U2720Q"), c = Self.display(3, "uuid-c", "LG")
        let catalog = LiveCatalog(.screens)
        catalog.update(running: LiveCatalog.screens([a, b], bound: ["uuid-b"]))
        #expect(catalog.entries.map(\.file) == [21] && catalog.entry(file: 21)?.source == "uuid-a" && catalog.entry(file: 21)?.label == "Built-in Retina Display")
        catalog.update(running: LiveCatalog.screens([a, b, c], bound: []))
        #expect(catalog.entries.map(\.source) == ["uuid-a", "uuid-b", "uuid-c"] && catalog.entries.map(\.file) == [21, 22, 23])
        catalog.update(running: LiveCatalog.screens([a, b, c], bound: ["uuid-b", "uuid-gone"]))
        #expect(catalog.entry(file: 22)?.running == false && catalog.entry(file: 22)?.gone == false)
        #expect(catalog.entry(file: 21)?.running == true && catalog.entry(file: 23)?.running == true)
        catalog.update(running: LiveCatalog.screens([a, b, c], bound: []))
        #expect(catalog.entry(file: 22)?.running == true)

        // `/screens` `{"21": {uuid, name}}`; after a restart every number is gone until seen, back by uuid under a new name
        let project: JSONValue = ["screens": ProjectDocument.liveValue(catalog.entries)]
        #expect(project["screens"]?["21"] == ["uuid": "uuid-a", "name": "Built-in Retina Display"])
        let next = LiveCatalog(.screens, numbers: ProjectDocument.liveNumbers(.screens, from: project))
        #expect(next.entries.count == 3 && next.entries.allSatisfy { $0.gone && !$0.running })
        next.update(running: LiveCatalog.screens([Self.display(9, "uuid-c", "LG UltraFine")], bound: []))
        #expect(next.entry(file: 23)?.running == true && next.entry(file: 23)?.gone == false && next.entry(file: 23)?.name == "LG UltraFine")
        #expect(next.entry(file: 21)?.gone == true)

        // past 28 a display waits for a number (21–23 stay held, not running)
        next.update(running: LiveCatalog.screens((0..<9).map { Self.display(UInt32(10 + $0), "d\($0)", "Display \($0)") }, bound: []))
        #expect(next.entries.count == 8 && next.unnumbered == ["Display 5", "Display 6", "Display 7", "Display 8"])

        // `live.capture.screens`, and the screen permission "pending" while `capture.authorize` waits for the grant
        let feed = Engine.captureLive([], screens: catalog.entries, camera: .authorized, screen: false, pending: true)
        #expect(
            feed == [
                "devices": [],
                "screens": [
                    ["file": 21, "name": "Built-in Retina Display", "running": true], ["file": 22, "name": "DELL U2720Q", "running": true],
                    ["file": 23, "name": "LG", "running": true],
                ],
                "permissions": ["camera": "granted", "screen": "pending"],
            ])
        #expect(Engine.captureLive([], screens: next.entries, camera: .authorized, screen: true, pending: true)["permissions"]?["screen"] == "granted")
        #expect(Engine.captureLive([], screens: next.entries, camera: .authorized, screen: false)["screens"]?[0] == ["file": 21, "name": "Built-in Retina Display", "running": false, "gone": true])
    }

    /// `/screens` is in a new project and the load migration adds it to an older one.
    @Test func projectHasTheScreensKey() throws {
        let initial = ProjectDocument.initial(patch: .standard(layers: 1, outputs: 0), layerCount: 1, libraryRoot: "/tmp/lib", policy: .dmx)
        #expect(initial["screens"] == [:])
        guard case .object(var map) = initial else {
            Issue.record("the initial project is an object")
            return
        }
        map["screens"] = nil
        let url = FileManager.default.temporaryDirectory.appending(path: "fanous-screens-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectDocument.save(.object(map), to: url)
        #expect(try #require(ProjectDocument.load(from: url))["screens"] == [:])
    }

    /// `capture.forget {file}` takes 21–28 too (never a running display); without a file it forgets every capture device
    /// and display not running, and Syphon's numbers stay.
    @Test func captureForgetCoversDisplays() throws {
        let auth = RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: StateStoreTests.logger)
        var project = ProjectDocument.initial(patch: .standard(layers: 2, outputs: 1), layerCount: 2, libraryRoot: "/tmp/lib", policy: .dmx)
        try project.set(ProjectDocument.liveValue([1, 2].map { LiveCatalogTests.numbered($0, "uid-\($0)", "Cam \($0)", model: "m") }), at: "/capture")
        try project.set(
            ProjectDocument.liveValue([21, 22, 23].map { LiveCatalog.Entry(kind: .screens, file: $0, source: "uuid-\($0)", name: "Display \($0)") }), at: "/screens")
        try project.set(ProjectDocument.liveValue([LiveCatalog.Entry(kind: .syphon, file: 150, source: "App", name: "")]), at: "/syphon")
        let store = StateStore(project: project, logger: StateStoreTests.logger)
        ProjectDocument.registerCommands(on: store, auth: auth, liveRunning: { [1, 21] })
        func files(_ kind: LiveCatalog.Kind) -> [Int] { ProjectDocument.liveNumbers(kind, from: store.project).map(\.file) }

        #expect(
            store.execute("capture.forget", args: ["file": 21], role: .programmer)
                == .failure(.invalidArgs("Display 21 is running; only one that is not running can be forgotten")))
        #expect(store.execute("capture.forget", args: ["file": 25], role: .programmer) == .failure(.invalidArgs("no display numbered 25")))
        _ = try store.execute("capture.forget", args: ["file": 22], role: .programmer).get()
        #expect(files(.screens) == [21, 23] && files(.capture) == [1, 2])
        _ = try store.execute("undo", role: .programmer).get()
        #expect(store.project["screens"]?["22"] == ["uuid": "uuid-22", "name": "Display 22"])
        _ = try store.execute("capture.forget", role: .programmer).get()
        #expect(files(.screens) == [21] && files(.capture) == [1] && files(.syphon) == [150])
    }

    /// Readiness item `capture` with displays: fails (acknowledgeable) without the screen grant, with the pane to open;
    /// granted, it warns (never blocks): macOS asks again about monthly.
    @Test func captureReadinessItemCoversDisplays() throws {
        func item(devices: Int = 0, camera: String = "granted", screens: Int, screen: String) throws -> ReadinessItem {
            var context = ReadinessContext()
            (context.captureDevices, context.cameraPermission, context.screens, context.screenPermission) = (devices, camera, screens, screen)
            return try #require(Readiness.check(context, acknowledged: []).first { $0.id == "capture" })
        }
        #expect(try item(screens: 0, screen: "denied").state == .ok)
        let denied = try item(screens: 1, screen: "denied")
        #expect(denied.state == .fail && denied.blocks && denied.detail == "screen: denied")
        #expect(denied.fix == "System Settings › Privacy & Security › Screen & System Audio Recording, then Engine › Restart")
        let both = try item(devices: 1, camera: "denied", screens: 2, screen: "denied")
        #expect(both.detail == "camera: denied, screen: denied" && both.fix == "System Settings › Privacy & Security › Camera / Screen & System Audio Recording, then Engine › Restart")
        let granted = try item(devices: 1, screens: 1, screen: "granted")
        #expect(granted.state == .warn && !granted.blocks && granted.detail == "camera: granted, screen: granted" && granted.fix.contains("monthly"))
    }

    // MARK: Input

    /// A display's BGRA frame through `ScreenInput` (the capture BGRA path: `.rgba` as `bgra8Unorm`, one plane, top-down)
    /// into the layer shader reads back exactly: white, black, red, grey, then the white/black pair (sampled linearly
    /// half a canvas pixel off centre, as for every sampled live frame).
    @Test func screenFrameReadsBack() throws {
        let context = try MetalContext()
        let input = Self.input(context.device)
        input.deliver(try CaptureInputTests.runsBuffer("BGRA"))
        let frame = try #require(input.latestFrame)
        #expect(frame.kind == .rgba && frame.texture0.pixelFormat == .bgra8Unorm && frame.texture1 == nil && !frame.bottomUp)
        let image = try LiveSourceTests.render(input, context: context)
        let y = GeneratorTests.height / 2
        func at(run i: Int) -> (r: Int, g: Int, b: Int) { GeneratorTests.pixel(image, LiveSourceTests.x(run: i), y) }
        LiveSourceTests.expect(at(run: 0), (255, 255, 255), "white", tolerance: 0)
        LiveSourceTests.expect(at(run: 1), (0, 0, 0), "black", tolerance: 0)
        LiveSourceTests.expect(at(run: 2), (255, 0, 0), "red", tolerance: 0)
        LiveSourceTests.expect(at(run: 3), (128, 128, 128), "grey", tolerance: 0)
        LiveSourceTests.expect(GeneratorTests.pixel(image, LiveSourceTests.x(pixel: 16), y), (252, 252, 252), "Y0", tolerance: 1)
        LiveSourceTests.expect(GeneratorTests.pixel(image, LiveSourceTests.x(pixel: 17), y), (3, 3, 3), "Y1", tolerance: 1)
    }

    /// No "no signal" for a display: a still picture sends no frames, and an hour later the input still runs with its
    /// last frame. `halt` (the display bound as an output) keeps the frame but is not shared again.
    @Test func aStillDisplayKeepsRunningAndAHaltKeepsTheFrame() throws {
        let context = try MetalContext()
        let clock = CaptureInputTests.Clock()
        let input = Self.input(context.device) { clock.nanos.load(ordering: .relaxed) }
        #expect(input.status == .starting)
        clock.advance(10)
        #expect(input.status == .starting)
        input.deliver(try CaptureInputTests.runsBuffer("BGRA"))
        let shown = try #require(input.latestFrame?.texture0)
        clock.advance(3600)
        guard case .running = input.status else {
            Issue.record("not running: \(input.status)")
            return
        }
        input.halt("not running")
        let shared = input.share()
        #expect(input.status == .failed("not running") && input.latestFrame?.texture0 === shown)
        #expect(!shared && !input.alive)
        // a frame the stream had queued before the halt does not replace the last one
        input.deliver(try CaptureInputTests.buffer(kCVPixelFormatType_32BGRA, 16, 8) { _ in Array(repeating: 7, count: 64) })
        #expect(input.latestFrame?.texture0 === shown && input.counters.frames == 1)
        input.stop()
        #expect(input.status == .stopped && input.latestFrame == nil)
    }

    /// Only a sample whose `SCStreamFrameInfo.status` is `.complete` carries a new picture; an idle one (and one without
    /// a status) keeps the last frame.
    @Test func onlyCompleteSamplesAreShown() throws {
        func sample(_ status: SCFrameStatus?) throws -> CMSampleBuffer {
            let buffer = try CaptureInputTests.runsBuffer("BGRA")
            var format: CMVideoFormatDescription?
            try #require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var made: CMSampleBuffer?
            try #require(
                CMSampleBufferCreateReadyWithImageBuffer(
                    allocator: nil, imageBuffer: buffer, formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &made) == noErr)
            let sample = try #require(made)
            if let status {
                let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true))
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                (dictionary as NSMutableDictionary)[SCStreamFrameInfo.status.rawValue] = status.rawValue
            }
            return sample
        }
        let shown = try [SCFrameStatus.complete, .idle, .blank, nil].map { ScreenInput.isComplete(try sample($0)) }
        #expect(shown == [true, false, false, false])
    }

    /// The stream's size: the display's pixels, scaled down into the canvas with the aspect kept, never up.
    @Test func streamSizeFitsTheCanvas() {
        #expect(ScreenInput.fit(width: 3024, height: 1964, into: (1920, 1080)) == (1663, 1080))
        #expect(ScreenInput.fit(width: 3840, height: 2160, into: (1920, 1080)) == (1920, 1080))
        #expect(ScreenInput.fit(width: 1280, height: 720, into: (1920, 1080)) == (1280, 720))
        #expect(ScreenInput.fit(width: 2560, height: 1080, into: (1920, 1080)) == (1920, 810))
    }

    /// The tick's read of a display frame allocates nothing (as the capture device's).
    @Test(.enabled(if: MallocCounter.availableOrRequired, "malloc_logger not exported by libsystem_malloc on this macOS"))
    func mallocCounterScreenFrameReadAllocatesNothing() throws {
        try #require(MallocCounter.available, "malloc_logger not exported by libsystem_malloc on this macOS")
        let context = try MetalContext()
        let input = Self.input(context.device)
        let buffers = try (0..<4).map { i in try CaptureInputTests.buffer(kCVPixelFormatType_32BGRA, 16, 8) { _ in Array(repeating: UInt8(i * 60), count: 64) } }
        let playback = LayerPlayback(key: MediaKey(folder: 0, file: 21), live: input)
        var mallocs = 0
        for window in 0..<3 {
            for buffer in buffers { input.deliver(buffer) }  // views made, ring filled: the window reads warm
            input.deliver(buffers[window])
            mallocs = MallocCounter.count {
                for _ in 0..<100 { _ = playback.frame(at: 0, direction: 1) }
            }
        }
        #if !DEBUG
            #expect(mallocs == 0, "100 screen frame reads: \(mallocs) allocations on the calling thread")
        #endif
        print("screen frame read × 100: \(mallocs) allocations")
    }

    /// `capture.authorize {kind: "screen"}`'s poll: true as soon as the preflight reads true, false after the attempts.
    @Test func grantPollStopsWhenGrantedOrAfterItsAttempts() async throws {
        let reads = Atomic<Int>(0), result = Mutex<Bool?>(nil)
        ScreenInput.pollGrant(preflight: { reads.add(1, ordering: .relaxed).newValue >= 3 }, interval: 0.01, attempts: 10) { granted in
            result.withLock { $0 = granted }
        }
        #expect(await waitUntil { result.withLock { $0 } != nil })
        #expect(result.withLock { $0 } == true && reads.load(ordering: .relaxed) == 3)

        let never = Atomic<Int>(0), refused = Mutex<Bool?>(nil)
        ScreenInput.pollGrant(preflight: { never.add(1, ordering: .relaxed); return false }, interval: 0.01, attempts: 5) { granted in
            refused.withLock { $0 = granted }
        }
        #expect(await waitUntil { refused.withLock { $0 } != nil })
        #expect(refused.withLock { $0 } == false && never.load(ordering: .relaxed) == 5)
    }

    /// Only the LaunchAgent (launchd's `XPC_SERVICE_NAME` = its label) restarts itself after the grant: `KeepAlive`
    /// brings it back. A terminal, `nohup` or orphaned engine (also launchd's child) and another job only log.
    @Test func onlyTheLaunchAgentRestartsItselfForTheGrant() {
        #expect(Engine.restartsItself(environment: ["XPC_SERVICE_NAME": "org.fanous.engine"]))
        #expect(!Engine.restartsItself(environment: [:]))
        #expect(!Engine.restartsItself(environment: ["XPC_SERVICE_NAME": "0"]))  // a terminal session
        #expect(!Engine.restartsItself(environment: ["XPC_SERVICE_NAME": "application.org.fanous.app.1234"]))
    }

    // MARK: Loader

    /// Folder 0 files 21–28 resolve through the screens catalog: "Display: <name>", two layers share one input (one
    /// factory call); a display bound as an output reads "not running", keeps the last frame and its stream is halted;
    /// unbound, one new session serves both layers. A scene entry `screen:` wins on its number; a number without a
    /// display says so; the factory's refusal (no screen grant) is the layer's text.
    @Test func loaderResolvesNumberedDisplaysToOneSharedInput() throws {
        let context = try MetalContext(), device = context.device
        let layers = (0..<4).map { RenderLayer(index: $0) }
        let loader = MediaLoader(
            layers: layers, media: [MediaEntry(folder: 0, file: 24, screen: "uuid-scene")], device: device, ringCapacity: 4, logger: Self.logger)
        let catalog = LiveCatalog(.screens)
        catalog.onChange = { [loader] in loader.screensChanged() }
        loader.screensCatalog = catalog
        let displays = [Self.display(1, "uuid-a", "Built-in Retina Display"), Self.display(2, "uuid-b", "DELL U2720Q")]
        catalog.update(running: LiveCatalog.screens(displays, bound: []))
        let opened = Mutex<[String]>([]), refuse = Atomic<Bool>(false)
        loader.screenFactory = { uuid in
            opened.withLock { $0.append(uuid) }
            if refuse.load(ordering: .relaxed) { throw CaptureError.screenPermission }
            return Self.input(device)
        }
        loader.start()
        defer { loader.stop() }
        func playback(_ i: Int) -> CaptureInput? { layers[i].pending.withLock { $0.playback?.live as? CaptureInput } }
        func status(_ i: Int) -> LayerMediaStatus { layers[i].mediaStatus.withLock { $0 } }
        func eventually(_ condition: () -> Bool) -> Bool { SyphonTests.wait(seconds: 5, until: condition) }
        func select(_ i: Int, _ file: Int) {
            layers[i].wanted.store(MediaKey(folder: 0, file: file).packed, ordering: .relaxed)
            loader.wake.signal()
        }

        select(0, 22)
        #expect(eventually { playback(0) != nil })
        select(1, 22)
        #expect(eventually { playback(1) != nil })
        let input = try #require(playback(0))
        #expect(playback(1) === input && input is ScreenInput && opened.withLock { $0 } == ["uuid-b"])
        #expect(status(0).name == "Display: DELL U2720Q" && status(0).kind == "live" && status(1).name == "Display: DELL U2720Q")
        input.deliver(try CaptureInputTests.runsBuffer("BGRA"))
        #expect(eventually { status(0).width == LiveSourceTests.width && status(0).capture?.frames == 1 })

        // bound as an output: not running, the last frame stays, the stream is halted; the number is kept
        catalog.update(running: LiveCatalog.screens(displays, bound: ["uuid-b"]))
        #expect(eventually { status(0).error == "not running" && status(1).error == "not running" })
        #expect(playback(0) === input && input.latestFrame != nil && !input.alive)
        #expect(catalog.entry(file: 22)?.running == false && catalog.entry(file: 22)?.gone == false)
        // unbound: one new session for both layers; the halted one stops when both have let go
        catalog.update(running: LiveCatalog.screens(displays, bound: []))
        #expect(eventually { playback(0) != nil && playback(0) !== input && playback(1) === playback(0) && status(0).error == nil })
        #expect(opened.withLock { $0 } == ["uuid-b", "uuid-b"])
        #expect(eventually { input.status == .stopped })

        // a scene entry wins on its number; a free number says so
        select(2, 24)
        select(3, 25)
        #expect(eventually { playback(2) != nil && status(3).error == "no display numbered 25 (folder 0, 21–28)" })
        #expect(status(2).name == "Display: synthetic" && opened.withLock { $0 }.last == "uuid-scene")
        // no screen grant: the factory's text, black
        refuse.store(true, ordering: .relaxed)
        select(3, 21)
        #expect(eventually { status(3).error == CaptureError.screenPermission.description })
        #expect(status(3).name == "Display: Built-in Retina Display" && status(3).kind == "live" && playback(3) == nil)
        #expect(CaptureError.screenPermission.description == "screen permission not granted: authorize on the System screen, then Engine › Restart")
    }
}
