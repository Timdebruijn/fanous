// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import CoreVideo
import FanousCore
import Foundation
import Logging
import Metal
import Synchronization
import Testing

@testable import FanousEngine

/// `CaptureInput` without a camera (DESIGN.md §8.2.1): synthetic IOSurface-backed pixel buffers in the four formats the
/// output asks for, through the texture views and the layer shader (the `LiveSourceTests` readback rig); retention of
/// taken frames; the no-signal status. A real device is checked only where one is present and authorized.
struct CaptureInputTests {
    static let logger = Logger(label: "capture-test")

    /// An IOSurface-backed buffer; `rows(plane)` gives one row of bytes, repeated over the plane's height.
    static func buffer(_ format: OSType, _ width: Int, _ height: Int, _ rows: (Int) -> [UInt8]) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        try #require(CVPixelBufferCreate(nil, width, height, format, attributes, &made) == kCVReturnSuccess)
        let buffer = try #require(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let planar = CVPixelBufferIsPlanar(buffer)
        for plane in 0..<(planar ? CVPixelBufferGetPlaneCount(buffer) : 1) {
            let base = try #require(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, plane) : CVPixelBufferGetBaseAddress(buffer))
            let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) : CVPixelBufferGetBytesPerRow(buffer)
            let row = rows(plane)
            for y in 0..<(planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : height) {
                row.withUnsafeBytes { (base + y * stride).copyMemory(from: $0.baseAddress!, byteCount: row.count) }
            }
        }
        return buffer
    }

    /// `LiveSourceTests.runs` (white, black, Rec.709 red, grey, then Y0 white / Y1 black) in `format`.
    static func runsBuffer(_ format: String) throws -> CVPixelBuffer {
        let runs = LiveSourceTests.runs, width = LiveSourceTests.width, height = LiveSourceTests.height
        switch format {
        case "2vuy": return try buffer(kCVPixelFormatType_422YpCbCr8, width, height) { _ in runs.flatMap { r in [r.cb, r.y0, r.cr, r.y1, r.cb, r.y0, r.cr, r.y1] } }
        case "yuvs": return try buffer(kCVPixelFormatType_422YpCbCr8_yuvs, width, height) { _ in runs.flatMap { r in [r.y0, r.cb, r.y1, r.cr, r.y0, r.cb, r.y1, r.cr] } }
        case "420v":
            return try buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width, height) { plane in
                plane == 0 ? runs.flatMap { r in [r.y0, r.y1, r.y0, r.y1] } : runs.flatMap { r in [r.cb, r.cr, r.cb, r.cr] }
            }
        default:  // BGRA: the same colours as RGB
            let white: [UInt8] = [255, 255, 255, 255], black: [UInt8] = [0, 0, 0, 255]
            let pixels: [[UInt8]] = [white, black, [0, 0, 255, 255], [128, 128, 128, 255]].flatMap { Array(repeating: $0, count: 4) } + [white, black, white, black]
            return try buffer(kCVPixelFormatType_32BGRA, width, height) { _ in pixels.flatMap { $0 } }
        }
    }

    static func input(_ device: MTLDevice, noSignalAfter: Double = 2, now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) -> CaptureInput {
        CaptureInput(name: "synthetic", metal: device, logger: logger, noSignalAfter: noSignalAfter, now: now)
    }

    /// Every format the output can be asked for reads the step-1a numbers: the packed ones pick each luma with the
    /// nearest sampler (255/0 on the white/black pair), the sampled planes interpolate half a canvas pixel off centre
    /// (252/3, see `LiveSourceTests`).
    @Test(arguments: ["2vuy", "yuvs", "420v", "BGRA"])
    func captureFormatsReadVideoRange(format: String) throws {
        let context = try MetalContext()
        let input = Self.input(context.device)
        input.deliver(try Self.runsBuffer(format))
        let frame = try #require(input.latestFrame)
        let kinds: [String: SourcePixelKind] = ["2vuy": .v216, "yuvs": .yuy2, "420v": .planarYCbCr, "BGRA": .rgba]
        #expect(frame.kind == kinds[format] && (frame.texture1 != nil) == (format == "420v") && !frame.bottomUp)
        let image = try LiveSourceTests.render(input, context: context)
        let y = GeneratorTests.height / 2
        func at(run i: Int) -> (r: Int, g: Int, b: Int) { GeneratorTests.pixel(image, LiveSourceTests.x(run: i), y) }
        LiveSourceTests.expect(at(run: 0), (255, 255, 255), "\(format) white", tolerance: 1)
        LiveSourceTests.expect(at(run: 1), (0, 0, 0), "\(format) black", tolerance: 0)
        LiveSourceTests.expect(at(run: 2), (255, 0, 0), "\(format) red", tolerance: 1)
        LiveSourceTests.expect(at(run: 3), (128, 128, 128), "\(format) grey", tolerance: 1)
        let packed = format == "2vuy" || format == "yuvs"
        let (y0, y1) = packed ? (255, 0) : (252, 3)
        LiveSourceTests.expect(GeneratorTests.pixel(image, LiveSourceTests.x(pixel: 16), y), (y0, y0, y0), "\(format) Y0", tolerance: packed ? 0 : 1)
        LiveSourceTests.expect(GeneratorTests.pixel(image, LiveSourceTests.x(pixel: 17), y), (y1, y1, y1), "\(format) Y1", tolerance: packed ? 0 : 1)
    }

    /// Packed 4:2:2 from a capture buffer is as wide as the buffer, not its half-width texture: 64×32, red left and white
    /// right, fits the 16:9 canvas as 2:1 with the split in the middle (as `LiveSourceTests.packedFrameKeepsItsFullWidthAspect`).
    @Test(arguments: ["2vuy", "yuvs"])
    func packedCaptureKeepsItsFullWidthAspect(format: String) throws {
        let context = try MetalContext()
        let (red, white): ([UInt8], [UInt8]) = format == "2vuy" ? ([102, 63, 240, 63], [128, 235, 128, 235]) : ([63, 102, 63, 240], [235, 128, 235, 128])
        let row = Array(repeating: red, count: 16).flatMap { $0 } + Array(repeating: white, count: 16).flatMap { $0 }
        let input = Self.input(context.device)
        input.deliver(try Self.buffer(format == "2vuy" ? kCVPixelFormatType_422YpCbCr8 : kCVPixelFormatType_422YpCbCr8_yuvs, 64, 32) { _ in row })
        let image = try LiveSourceTests.render(input, fitMode: .fit, context: context)
        let middle = GeneratorTests.height / 2
        LiveSourceTests.expect(GeneratorTests.pixel(image, 470, middle), (255, 0, 0), "\(format) left of the split")
        LiveSourceTests.expect(GeneratorTests.pixel(image, 490, middle), (255, 255, 255), "\(format) right of the split")
        LiveSourceTests.expect(GeneratorTests.pixel(image, 240, 35), (255, 0, 0), "\(format) top row of the picture")
        LiveSourceTests.expect(GeneratorTests.pixel(image, 240, 20), (0, 0, 0), "\(format) bar above", tolerance: 0)
    }

    @Test func outputFormatFollowsTheNativeSubtype() {
        #expect(CaptureInput.outputPixelFormat(native: kCVPixelFormatType_422YpCbCr8) == kCVPixelFormatType_422YpCbCr8)
        #expect(CaptureInput.outputPixelFormat(native: kCVPixelFormatType_422YpCbCr8_yuvs) == kCVPixelFormatType_422YpCbCr8_yuvs)
        #expect(CaptureInput.outputPixelFormat(native: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CaptureInput.outputPixelFormat(native: kCMVideoCodecType_JPEG) == kCVPixelFormatType_32BGRA)
        #expect(CaptureInput.outputPixelFormat(native: kCVPixelFormatType_422YpCbCr10) == kCVPixelFormatType_32BGRA)  // v210 later
    }

    /// The range that holds the canvas rate (1000/1001 counts as the same), the one whose top is closest above it, at
    /// the canvas rate; else the fastest below; a kept subtype over MJPEG at equal rates.
    @Test func frameRatePickHoldsTheCanvasRate() throws {
        typealias O = CaptureInput.RateOption
        let yuvs = kCVPixelFormatType_422YpCbCr8_yuvs, vuy = kCVPixelFormatType_422YpCbCr8, jpeg = kCMVideoCodecType_JPEG
        func pick(_ o: [O], _ fps: Double) -> (Int, Double)? { CaptureInput.pick(o, fps: fps).map { ($0.index, $0.rate) } }
        // 59.94 canvas: a 60.000-only range is the same rate (runs at its own 60), [1–60] runs at 59.94
        #expect(pick([O(subtype: yuvs, minRate: 60, maxRate: 60)], 59.94).map { $0.0 == 0 && $0.1 == 60 } == true)
        #expect(pick([O(subtype: yuvs, minRate: 1, maxRate: 60)], 59.94).map { $0.0 == 0 && $0.1 == 59.94 } == true)
        // 60 canvas, a 59.94-only card: held
        #expect(pick([O(subtype: vuy, minRate: 59.94, maxRate: 59.94)], 60).map { $0.0 == 0 && $0.1 == 59.94 } == true)
        // 50 canvas: [1–60] holds 50, [1–30] does not; [25–50] is closer above than [1–60]
        #expect(pick([O(subtype: yuvs, minRate: 1, maxRate: 60), O(subtype: yuvs, minRate: 1, maxRate: 30)], 50).map { $0.0 == 0 && $0.1 == 50 } == true)
        #expect(pick([O(subtype: yuvs, minRate: 1, maxRate: 60), O(subtype: yuvs, minRate: 25, maxRate: 50)], 50).map { $0.0 == 1 && $0.1 == 50 } == true)
        // nothing holds 60: the fastest below at its top; ranges only above the canvas rate are not taken
        #expect(pick([O(subtype: yuvs, minRate: 1, maxRate: 15), O(subtype: yuvs, minRate: 1, maxRate: 30)], 60).map { $0.0 == 1 && $0.1 == 30 } == true)
        #expect(pick([O(subtype: yuvs, minRate: 30, maxRate: 30)], 24) == nil)
        // equal rates: the 4:2:2 format over MJPEG, whichever comes first
        #expect(pick([O(subtype: jpeg, minRate: 1, maxRate: 30), O(subtype: vuy, minRate: 1, maxRate: 30)], 30).map { $0.0 == 1 } == true)
        #expect(pick([O(subtype: vuy, minRate: 1, maxRate: 30), O(subtype: jpeg, minRate: 1, maxRate: 30)], 30).map { $0.0 == 0 } == true)
    }

    /// A frame without an IOSurface cannot be shown: counted as unusable (the layer would otherwise read "no signal" with
    /// the device delivering); a frame after `stop()` is not counted.
    /// B126: a camera takes the largest size that fits the canvas and holds the canvas rate; without a holding range the
    /// largest that fits; nothing fitting keeps the active size (nil).
    @Test func cameraSizePickFitsTheCanvas() {
        typealias S = CaptureInput.SizeOption
        let iphone = [S(width: 640, height: 480, minRate: 1, maxRate: 60), S(width: 1280, height: 720, minRate: 1, maxRate: 60), S(width: 1920, height: 1080, minRate: 1, maxRate: 60)]
        #expect(CaptureInput.pickSize(iphone, fps: 60, canvas: (1920, 1080)).map { $0 == (1920, 1080) } == true)
        #expect(CaptureInput.pickSize(iphone, fps: 60, canvas: (1280, 720)).map { $0 == (1280, 720) } == true)
        #expect(CaptureInput.pickSize(iphone, fps: 60, canvas: (1000, 1000)).map { $0 == (640, 480) } == true)
        // FaceTime camera at a 60 fps canvas: no size holds 60, the largest fitting one (then `pick` runs it at 30)
        let facetime = [S(width: 1280, height: 720, minRate: 1, maxRate: 30), S(width: 1920, height: 1080, minRate: 1, maxRate: 30)]
        #expect(CaptureInput.pickSize(facetime, fps: 60, canvas: (1920, 1080)).map { $0 == (1920, 1080) } == true)
        // a size holding the rate beats a larger one that does not
        let mixed = [S(width: 1920, height: 1080, minRate: 1, maxRate: 30), S(width: 1280, height: 720, minRate: 1, maxRate: 60)]
        #expect(CaptureInput.pickSize(mixed, fps: 60, canvas: (1920, 1080)).map { $0 == (1280, 720) } == true)
        #expect(CaptureInput.pickSize(mixed, fps: 59.94, canvas: (1920, 1080)).map { $0 == (1280, 720) } == true)
        #expect(CaptureInput.pickSize(mixed, fps: 60, canvas: (320, 240)) == nil)
    }

    @Test func unusableFramesAreCounted() throws {
        let context = try MetalContext()
        let input = Self.input(context.device)
        var plain: CVPixelBuffer?
        try #require(CVPixelBufferCreate(nil, 16, 8, kCVPixelFormatType_32BGRA, nil, &plain) == kCVReturnSuccess)
        input.deliver(try #require(plain))
        input.deliver(try #require(plain))
        input.deliver(try Self.runsBuffer("BGRA"))
        #expect(input.counters == CaptureInput.Counters(frames: 1, dropped: 0, outOfBuffers: 0, unusable: 2))
        input.stop()
        input.deliver(try Self.runsBuffer("BGRA"))
        #expect(input.counters.frames == 1 && input.latestFrame == nil)
    }

    /// Ten frames, three of them taken (plus one repeat read of a taken frame, which does not take a second ring slot):
    /// the three taken and the newest stay alive, the rest went back; a fourth take pushes the oldest out.
    @Test func keepsTheLastThreeTakenFramesAndTheLatest() throws {
        let context = try MetalContext()
        let input = Self.input(context.device)
        var weakRefs: [Weak] = []
        for i in 0..<10 {
            let buffer = try Self.buffer(kCVPixelFormatType_32BGRA, 16, 8) { _ in Array(repeating: UInt8(i), count: 64) }
            input.deliver(buffer)
            weakRefs.append(Weak(buffer))
            if i == 0 || i == 2 || i == 6 { _ = input.latestFrame }
            if i == 6 { _ = input.latestFrame }  // repeat read of frame 6
        }
        #expect(weakRefs.indices.filter { weakRefs[$0].object != nil } == [0, 2, 6, 9])
        _ = input.latestFrame  // takes 9: frame 0 falls out of the ring
        #expect(weakRefs.indices.filter { weakRefs[$0].object != nil } == [2, 6, 9])
        input.stop()
        #expect(weakRefs.allSatisfy { $0.object == nil } && input.latestFrame == nil && input.status == .stopped)
    }

    final class Weak {
        weak var object: AnyObject?
        init(_ object: AnyObject) { self.object = object }
    }

    final class Clock: Sendable {
        let nanos = Atomic<UInt64>(1_000_000_000)
        func advance(_ seconds: Double) { nanos.wrappingAdd(UInt64(seconds * 1e9), ordering: .relaxed) }
    }

    /// No frame for `noSignalAfter` reads `.noSignal`, and the last frame stays; the next frame is running again.
    @Test func noFramesReadsNoSignalAndKeepsTheLastFrame() throws {
        let context = try MetalContext()
        let clock = Clock()
        let input = Self.input(context.device, noSignalAfter: 2) { clock.nanos.load(ordering: .relaxed) }
        #expect(input.status == .starting)
        let buffer = try Self.runsBuffer("BGRA")
        for _ in 0..<10 {
            input.deliver(buffer)
            clock.advance(1.0 / 60)
        }
        guard case .running(let fps) = input.status else { Issue.record("not running: \(input.status)"); return }
        #expect(abs(fps - 60) < 0.5)
        let shown = try #require(input.latestFrame?.texture0)
        clock.advance(2.5)
        #expect(input.status == .noSignal)
        #expect(input.latestFrame?.texture0 === shown)
        input.deliver(buffer)
        #expect(input.status != .noSignal)
        // a device that never delivers reads no signal too, after the same wait
        let silent = Self.input(context.device, noSignalAfter: 2) { clock.nanos.load(ordering: .relaxed) }
        clock.advance(2.5)
        #expect(silent.status == .noSignal && silent.latestFrame == nil)
    }

    /// The tick's read of a capture frame (`LayerPlayback.frame` → `latestFrame`: lock, ring move) allocates nothing.
    @Test(.enabled(if: MallocCounter.availableOrRequired, "malloc_logger not exported by libsystem_malloc on this macOS"))
    func mallocCounterCaptureFrameReadAllocatesNothing() throws {
        try #require(MallocCounter.available, "malloc_logger not exported by libsystem_malloc on this macOS")
        let context = try MetalContext()
        let input = Self.input(context.device)
        let buffers = try ["2vuy", "yuvs", "420v", "BGRA"].map { try Self.runsBuffer($0) }
        let playback = LayerPlayback(key: MediaKey(folder: 0, file: 1), live: input)
        var mallocs = 0
        for window in 0..<3 {
            for buffer in buffers { input.deliver(buffer) }  // views made, ring filled: the window reads warm
            input.deliver(buffers[window])
            mallocs = MallocCounter.count {
                for _ in 0..<100 { _ = playback.frame(at: 0, direction: 1) }
            }
        }
        #if !DEBUG
            #expect(mallocs == 0, "100 capture frame reads: \(mallocs) allocations on the calling thread")
        #endif
        print("capture frame read × 100: \(mallocs) allocations")
    }

    /// Only where a camera is present and this process may use it (never on CI; the dev Mac's test runner is usually
    /// not authorized): the session opens and a frame arrives within 3 s.
    @Test func realDeviceDeliversAFrame() async throws {
        guard let device = AVCaptureDevice.default(for: .video) else {
            print("realDeviceDeliversAFrame skipped: no video capture device")
            return
        }
        guard CaptureInput.authorization == .authorized else {
            print("realDeviceDeliversAFrame skipped: camera permission is \(CaptureInput.authorization.rawValue), not authorized")
            return
        }
        let context = try MetalContext()
        let input = CaptureInput(device: device, metal: context.device, fps: 60, logger: Self.logger)  // starts on its queue
        defer { input.stop() }
        #expect(await waitUntil(.seconds(3)) { input.latestFrame != nil }, "no frame from \(device.localizedName) in 3 s: \(input.status)")
        print("capture \(device.localizedName): \(input.format), \(input.counters)")
    }

    /// The reviewer's variant of the read test: 1080p `2vuy` buffers from a `CVPixelBufferPool`, delivered by another
    /// thread, nothing kept by the test. Each of 100 takes evicts the oldest taken buffer, whose last release (back to
    /// the pool) happens on the reading thread: still no allocation there.
    @Test(.enabled(if: MallocCounter.availableOrRequired, "malloc_logger not exported by libsystem_malloc on this macOS"))
    func mallocCounterCaptureTakeEvictingPoolBuffersAllocatesNothing() throws {
        try #require(MallocCounter.available, "malloc_logger not exported by libsystem_malloc on this macOS")
        let context = try MetalContext()
        let input = Self.input(context.device)
        let playback = LayerPlayback(key: MediaKey(folder: 0, file: 1), live: input)
        var made: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8, kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        try #require(CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &made) == kCVReturnSuccess)
        nonisolated(unsafe) let pool = try #require(made)
        // the feeder thread plays the capture queue; semaphores hand over without allocating on the reading thread
        let go = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let running = Atomic<Bool>(true)
        Thread.detachNewThread {
            while true {
                go.wait()
                guard running.load(ordering: .relaxed) else { break }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                if let buffer { input.deliver(buffer) }
                done.signal()
            }
            done.signal()
        }
        defer {
            running.store(false, ordering: .relaxed)
            go.signal()
            done.wait()
        }
        func deliverAndTake() {
            go.signal()
            done.wait()
            _ = playback.frame(at: 0, direction: 1)
        }
        for _ in 0..<20 { deliverAndTake() }  // the pool and the view cache warm up, the ring is full
        var mallocs = 0
        for _ in 0..<3 {
            mallocs = MallocCounter.count {
                for _ in 0..<100 { deliverAndTake() }
            }
        }
        #expect(input.counters.frames == 320)
        #if !DEBUG
            #expect(mallocs == 0, "100 takes evicting pool buffers: \(mallocs) allocations on the reading thread")
        #endif
        print("capture take evicting a pool buffer × 100: \(mallocs) allocations")
    }

    /// A scene entry `{folder: 0, file, capture: uid}` opens through `captureFactory`: the layer reads "Camera: <name>",
    /// "no signal" while frames stop (same playback), the factory's error as its status, and a layer refused for the
    /// permission opens once the answer comes (`capturePermissionChanged`).
    @Test func loaderOpensSceneCaptureEntries() throws {
        let context = try MetalContext(), device = context.device
        let layers = [RenderLayer(index: 0), RenderLayer(index: 1)]
        let loader = MediaLoader(
            layers: layers, media: [MediaEntry(folder: 0, file: 5, capture: "cam-1"), MediaEntry(folder: 0, file: 6, capture: "cam-2")], device: device,
            ringCapacity: 4, logger: Self.logger)
        let clock = Clock()
        let granted = Atomic<Bool>(false)
        loader.captureFactory = { uid in
            if uid == "cam-2" && !granted.load(ordering: .relaxed) { throw CaptureError.permissionNotAsked }
            return Self.input(device, noSignalAfter: 2) { clock.nanos.load(ordering: .relaxed) }
        }
        loader.start()
        defer { loader.stop() }
        func playback(_ i: Int) -> CaptureInput? { layers[i].pending.withLock { $0.playback?.live as? CaptureInput } }
        func status(_ i: Int) -> LayerMediaStatus { layers[i].mediaStatus.withLock { $0 } }
        func eventually(_ condition: () -> Bool) -> Bool { SyphonTests.wait(seconds: 5, until: condition) }
        layers[0].wanted.store(MediaKey(folder: 0, file: 5).packed, ordering: .relaxed)
        layers[1].wanted.store(MediaKey(folder: 0, file: 6).packed, ordering: .relaxed)
        loader.wake.signal()
        #expect(eventually { playback(0) != nil && status(0).name == "Camera: synthetic" })
        #expect(status(0).kind == "live" && status(0).error == nil)
        #expect(eventually { status(1).error == CaptureError.permissionNotAsked.description })
        #expect(status(1).kind == "live" && playback(1) == nil)

        let input = try #require(playback(0))
        input.deliver(try Self.runsBuffer("BGRA"))
        clock.advance(2.5)
        #expect(eventually { status(0).error == "no signal" })
        #expect(playback(0) === input && input.latestFrame != nil)
        input.deliver(try Self.runsBuffer("BGRA"))
        #expect(eventually { status(0).error == nil })
        // size and counters follow the input (a card changing format), polled by the loader
        input.deliver(try Self.buffer(kCVPixelFormatType_32BGRA, 64, 32) { _ in Array(repeating: 9, count: 256) })
        #expect(eventually { status(0).width == 64 && status(0).height == 32 && status(0).capture?.frames == 3 })

        granted.store(true, ordering: .relaxed)
        loader.capturePermissionChanged()
        #expect(eventually { playback(1) != nil && status(1).error == nil && status(1).name == "Camera: synthetic" })
        #expect(playback(0) === input)  // an open layer is left alone
    }

    /// Folder 0 files 1–20 resolve through the capture catalog (B73 step 2b): two layers on file 3 share one input (one
    /// factory call); a device that goes reads "not running" and keeps the layers' input, one that comes back opens a
    /// new session for both, and the old one stops when its last layer lets go. A device in use elsewhere is not opened.
    @Test func loaderResolvesNumberedCaptureDevicesToOneSharedInput() throws {
        let context = try MetalContext(), device = context.device
        let layers = (0..<4).map { RenderLayer(index: $0) }
        let loader = MediaLoader(layers: layers, media: [], device: device, ringCapacity: 4, logger: Self.logger)
        let catalog = LiveCatalog(.capture, numbers: [LiveCatalogTests.numbered(5, "away", "Away Cam", model: "")])
        catalog.onChange = { [loader] in loader.captureDevicesChanged() }
        loader.captureCatalog = catalog
        let cams = ["cam-a", "cam-b", "cam-c"].map { LiveCatalogTests.device($0, "Cam \($0.suffix(1).uppercased())", model: "m") }
        catalog.update(running: cams)
        #expect(catalog.entry(file: 3)?.source == "cam-c")
        let opened = Mutex<[String]>([])
        loader.captureFactory = { uid in
            opened.withLock { $0.append(uid) }
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

        select(0, 3)
        #expect(eventually { playback(0) != nil })
        select(1, 3)
        #expect(eventually { playback(1) != nil })
        let input = try #require(playback(0))
        #expect(playback(1) === input && opened.withLock { $0 } == ["cam-c"])
        #expect(status(0).name == "Camera: Cam C" && status(0).kind == "live" && status(1).name == "Camera: Cam C")
        select(2, 5)
        select(3, 9)
        #expect(eventually { status(2).error == "not running" && status(3).error == "no capture device numbered 9 (folder 0, 1–20)" })
        #expect(status(2).name == "Camera: Away Cam" && playback(2) == nil)

        // unplugged: both layers read "not running" and keep the input (the last frame)
        catalog.update(running: Array(cams.prefix(2)))
        #expect(eventually { status(0).error == "not running" && status(1).error == "not running" })
        #expect(playback(0) === input && input.status != .stopped)
        // back: one new session for both layers; the old input stops when both have let go
        catalog.update(running: cams)
        #expect(eventually { playback(0) != nil && playback(0) !== input && playback(1) === playback(0) })
        #expect(opened.withLock { $0 } == ["cam-c", "cam-c"])
        #expect(input.status == .stopped)

        // in use by another app: an open layer stays; a layer selecting it now is not opened until the other app lets go
        catalog.update(running: [cams[0], LiveCatalogTests.device("cam-b", "Cam B", model: "m", inUse: true), cams[2]])
        select(2, 2)
        #expect(eventually { status(2).error == "in use by another app" && status(2).name == "Camera: Cam B" })
        #expect(playback(2) == nil)
        catalog.update(running: cams)
        #expect(eventually { playback(2) != nil && status(2).error == nil })
        #expect(opened.withLock { $0 } == ["cam-c", "cam-c", "cam-b"])

        // our own session is shared before the in-use check: another app opening the device after us refuses nobody
        catalog.update(running: [cams[0], LiveCatalogTests.device("cam-b", "Cam B", model: "m", inUse: true), cams[2]])
        select(3, 2)
        #expect(eventually { playback(3) != nil })
        #expect(playback(3) === playback(2) && status(3).error != "in use by another app")
        #expect(opened.withLock { $0 } == ["cam-c", "cam-c", "cam-b"])

        // unplug and replug in one update, on another port (a new uid, the model and name fallback keeps number 3): both
        // layers leave the old session for one new one, and the old one stops
        let before = try #require(playback(0))
        catalog.update(running: [cams[0], cams[1], LiveCatalogTests.device("cam-c2", "Cam C", model: "m")])
        #expect(catalog.entry(file: 3)?.source == "cam-c2")
        #expect(eventually { playback(0) != nil && playback(0) !== before && playback(1) === playback(0) })
        #expect(opened.withLock { $0 } == ["cam-c", "cam-c", "cam-b", "cam-c2"])
        #expect(before.status == .stopped)

        // a failed session is not shared, and the next catalog change opens it again
        let failed = try #require(playback(0))
        failed.slot.withLock { $0.failure = "device in use" }
        #expect(!failed.share())
        catalog.update(running: [LiveCatalogTests.device("cam-a", "Cam A", model: "m", inUse: true), cams[1], LiveCatalogTests.device("cam-c2", "Cam C", model: "m")])
        #expect(eventually { playback(0) != nil && playback(0) !== failed && playback(1) === playback(0) })
        #expect(opened.withLock { $0 } == ["cam-c", "cam-c", "cam-b", "cam-c2", "cam-c2"])
    }
}
