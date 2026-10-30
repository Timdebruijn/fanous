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
        let context = try MetalContext(), metal = context.device
        let input = try await offPool {
            try CaptureInput(device: try #require(AVCaptureDevice.default(for: .video)), metal: metal, fps: 60, logger: Self.logger)
        }
        defer { input.stop() }
        #expect(await waitUntil(.seconds(3)) { input.latestFrame != nil }, "no frame from \(device.localizedName) in 3 s")
        print("capture \(device.localizedName): \(input.subtype) \(input.width)x\(input.height), \(input.frames) frames, \(input.droppedFrames) dropped")
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

        granted.store(true, ordering: .relaxed)
        loader.capturePermissionChanged()
        #expect(eventually { playback(1) != nil && status(1).error == nil && status(1).name == "Camera: synthetic" })
        #expect(playback(0) === input)  // an open layer is left alone
    }
}
