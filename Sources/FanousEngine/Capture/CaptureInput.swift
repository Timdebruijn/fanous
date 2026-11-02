// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import CoreVideo
import FanousCore
import Foundation
import IOSurface
import Logging
import Metal
import Synchronization

/// Why a capture device could not be opened; the text is the layer's status line (DESIGN.md §8.2.1).
public enum CaptureError: Error, CustomStringConvertible {
    case permissionNotAsked
    case permissionPending
    case permissionDenied
    case noDevice(String)
    case session(String)
    case screenPermission
    case noDisplay(String)

    public var description: String {
        switch self {
        case .permissionNotAsked: "camera permission not asked: authorize on the System screen"
        case .permissionPending: "waiting for camera permission"
        case .permissionDenied: "camera permission denied: allow Fanous under Privacy & Security › Camera"
        case .noDevice(let uid): "no capture device \(uid)"
        case .session(let reason): "capture could not start: \(reason)"
        case .screenPermission: "screen permission not granted: authorize on the System screen, then Engine › Restart"
        case .noDisplay(let uuid): "no display \(uuid)"
        }
    }
}

/// One AVFoundation capture device (camera, capture card, Continuity Camera) as a live layer source (DESIGN.md §8.2.1).
/// The session is configured, started and stopped on the device's own serial queue, where its frames also arrive; the
/// textures are views on each frame's IOSurface, made once per pool buffer. The compositor's `latestFrame` read marks
/// the frame taken: the last three taken frames stay retained (command buffers in flight) beside the newest,
/// everything else goes back to AVFoundation's pool. `ScreenInput` (a display) is this class on an `SCStream`.
public class CaptureInput: NSObject, LiveTextureSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case starting
        case running(fps: Double)
        case noSignal
        case stopped
        /// The session could not be configured or started (the device is in use, gone, or refused the input).
        case failed(String)
    }

    /// Frames delivered; dropped by AVFoundation (any reason) and of those for want of a pool buffer; delivered but
    /// unusable (no IOSurface, no texture view).
    public struct Counters: Sendable, Equatable {
        public var frames = 0
        public var dropped = 0
        public var outOfBuffers = 0
        public var unusable = 0
    }

    /// A frame as delivered: the pixel buffer keeps the IOSurface (and AVFoundation's pool slot) while it is held.
    struct Held {
        var buffer: CVPixelBuffer
        var frame: LiveFrame
    }

    struct Slot: @unchecked Sendable {  // CVPixelBuffer and MTLTexture are not Sendable; only references move here
        var latest: Held?
        var latestTaken = false
        var taken: [Held?] = [nil, nil, nil]
        var next = 0
        var startNanos: UInt64 = 0
        var lastFrameNanos: UInt64 = 0
        var lastCountersLog: UInt64 = 0
        var interval = 0.0  // smoothed seconds between frames
        var interrupted = false
        var stopped = false
        var failure: String?
        var counters = Counters()
        var unusableLogged = false
        /// Layers showing this input (`share()`); the last `stop()` stops it.
        var users = 1
        var alive: Bool { !stopped && failure == nil }
        /// The running format's subtype, and the size of the newest frame (it follows a card's input).
        var subtype = ""
        var width = 0
        var height = 0
    }

    public let name: String
    /// No frame for this long reads `.noSignal` (the last frame stays on the layer).
    let noSignalAfter: Double
    static let countersLogEvery: UInt64 = 60_000_000_000
    private let now: @Sendable () -> UInt64
    private let views: TextureViews
    let logger: Logger
    let slot = Mutex(Slot())
    let queue: DispatchQueue
    /// Capture queue only.
    private var session: AVCaptureSession?
    private var observers: [any NSObjectProtocol] = []

    public var counters: Counters { slot.withLock { $0.counters } }
    /// The running format's native subtype (`2vuy`, `yuvs`, `420v`, `jpeg`, …; empty until it runs or for a synthetic
    /// input) and the newest frame's size.
    public var format: (subtype: String, width: Int, height: Int) { slot.withLock { ($0.subtype, $0.width, $0.height) } }

    /// A source without a session, fed through `deliver` (tests).
    init(
        name: String, metal: MTLDevice, logger: Logger, queueLabel: String = "org.fanous.capture.synthetic", noSignalAfter: Double = 2,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.name = name
        self.noSignalAfter = noSignalAfter
        self.now = now
        self.logger = logger
        views = TextureViews(device: metal)
        queue = DispatchQueue(label: queueLabel, qos: .userInteractive)  // ADR-0002: frame producers feed the tick
        super.init()
        let start = now()
        slot.withLock {
            $0.startNanos = start
            $0.lastCountersLog = start
        }
    }

    /// Opens `device` at the canvas rate `fps` (or the closest it offers) and, for a camera, the largest size that fits
    /// `canvas` (a card keeps its input's size; nil: every device keeps its active format's size): the session is
    /// configured and started on the capture queue, so this returns at once and the input reads `.starting` meanwhile.
    public convenience init(device: AVCaptureDevice, metal: MTLDevice, fps: Double, canvas: (width: Int, height: Int)? = nil, logger: Logger) {
        self.init(name: device.localizedName, metal: metal, logger: logger, queueLabel: "org.fanous.capture.\(device.uniqueID)")
        nonisolated(unsafe) let device = device  // used on the capture queue only from here on
        queue.async { [self] in
            guard !slot.withLock({ $0.stopped }) else { return }
            do {
                try start(device, fps: fps, canvas: canvas)
            } catch {
                logger.warning("capture \(name) could not start", metadata: ["error": "\(error)"])
                slot.withLock { $0.failure = "\(error)" }
            }
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Permission

    public static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    /// Asks for the camera only when `allowed` (outside show mode) and not yet determined; otherwise reports the current
    /// state (`.notDetermined` when not allowed to ask). `completion` may run on any thread.
    public static func requestAccess(allowed: Bool, completion: @escaping @Sendable (AVAuthorizationStatus) -> Void) {
        let status = authorization
        guard status == .notDetermined, allowed else { return completion(status) }
        AVCaptureDevice.requestAccess(for: .video) { completion($0 ? .authorized : .denied) }
    }

    /// The loader's entry: checks the permission (asking once when `allowed`; `onAnswer` runs after the user answers),
    /// finds the device by `uid` and opens it.
    public static func open(
        uid: String, metal: MTLDevice, fps: Double, canvas: (width: Int, height: Int), allowed: Bool, logger: Logger,
        onAnswer: @escaping @Sendable () -> Void
    ) throws -> CaptureInput {
        switch authorization {
        case .authorized: break
        case .notDetermined:
            guard allowed else { throw CaptureError.permissionNotAsked }
            requestAccess(allowed: true) { _ in onAnswer() }
            throw CaptureError.permissionPending
        default: throw CaptureError.permissionDenied
        }
        guard let device = AVCaptureDevice(uniqueID: uid) else { throw CaptureError.noDevice(uid) }
        return CaptureInput(device: device, metal: metal, fps: fps, canvas: canvas, logger: logger)
    }

    // MARK: Format

    /// The 4:2:x subtypes the output keeps as they are.
    static let keptSubtypes: Set<FourCharCode> = [
        kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]

    /// What the output is asked for, by the device's native subtype: the 8-bit layouts the shader reads stay as they
    /// are, anything else (MJPEG webcams, `v210` for now) is decoded to BGRA by AVFoundation.
    static func outputPixelFormat(native: FourCharCode) -> OSType {
        switch native {
        case kCVPixelFormatType_422YpCbCr8: kCVPixelFormatType_422YpCbCr8
        case kCVPixelFormatType_422YpCbCr8_yuvs: kCVPixelFormatType_422YpCbCr8_yuvs
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        default: kCVPixelFormatType_32BGRA
        }
    }

    /// One frame-rate range of one format of the active format's size.
    struct RateOption {
        var subtype: FourCharCode
        var minRate: Double
        var maxRate: Double
    }

    /// The option to run and the rate to run it at. A range that holds the canvas rate (1000/1001 apart counts as the
    /// same rate, as for display modes) wins, the one whose top is closest above it first, at the canvas rate clamped
    /// to the range. Without one, the fastest range below the canvas rate at its top rate. Ties: a subtype the output
    /// keeps (`2vuy`, `yuvs`, `420v`) over one it decodes (MJPEG). Nil when every range is above the canvas rate.
    static func pick(_ options: [RateOption], fps: Double) -> (index: Int, rate: Double)? {
        func holds(_ o: RateOption) -> Bool { Self.holds(min: o.minRate, max: o.maxRate, fps) }
        func better(_ a: RateOption, _ b: RateOption) -> Bool {
            let (ha, hb) = (holds(a), holds(b))
            if ha != hb { return ha }
            if a.maxRate != b.maxRate { return ha ? a.maxRate < b.maxRate : a.maxRate > b.maxRate }
            return keptSubtypes.contains(a.subtype) && !keptSubtypes.contains(b.subtype)
        }
        var best: Int?
        for (i, o) in options.enumerated() where holds(o) || o.maxRate < fps {
            if best.map({ better(o, options[$0]) }) ?? true { best = i }
        }
        guard let best else { return nil }
        let o = options[best]
        return (best, holds(o) ? min(max(fps, o.minRate), o.maxRate) : o.maxRate)
    }

    /// A range holds `fps` when it is inside it, 1000/1001 apart counting as the same rate (as for display modes).
    static func holds(min: Double, max: Double, _ fps: Double) -> Bool {
        (min <= fps || DisplayModeMatching.sameRate(min, fps)) && (fps <= max || DisplayModeMatching.sameRate(fps, max))
    }

    /// One frame-rate range of one format, with the format's size.
    struct SizeOption {
        var width: Int
        var height: Int
        var minRate: Double
        var maxRate: Double
    }

    /// Cameras: the size is chosen (B126). Everything else (`.external`: UVC cards and webcams) follows its input.
    static let cameraTypes: Set<AVCaptureDevice.DeviceType> = [.builtInWideAngleCamera, .continuityCamera]

    /// The size a camera runs at (B126): the largest that fits `canvas` and has a range holding `fps`, else the largest
    /// that fits with a range below `fps` (what `pick` runs); nil when no size fits or can run (the active format's size
    /// then stays, as for a card). A camera's session preset leaves some devices small (the iPhone at 640x480) while the
    /// canvas asks for more.
    static func pickSize(_ options: [SizeOption], fps: Double, canvas: (width: Int, height: Int)) -> (width: Int, height: Int)? {
        let fitting = options.filter { $0.width <= canvas.width && $0.height <= canvas.height }
        let holding = fitting.filter { holds(min: $0.minRate, max: $0.maxRate, fps) }
        let runnable = holding.isEmpty ? fitting.filter { $0.maxRate < fps } : holding
        return runnable.max { $0.width * $0.height < $1.width * $1.height }.map { ($0.width, $0.height) }
    }

    /// The device's format and range to run at `fps`, and the rate: of the chosen size for a camera with a `canvas`
    /// (`pickSize`), else of the active format's size (a card follows its input, so the size is the input's); nil when
    /// nothing fits (the active format is then left alone).
    static func bestFormat(_ device: AVCaptureDevice, fps: Double, canvas: (width: Int, height: Int)? = nil) -> (format: AVCaptureDevice.Format, range: AVFrameRateRange, rate: Double)? {
        let all = device.formats.flatMap { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return format.videoSupportedFrameRateRanges.map { (format, $0, Int(dims.width), Int(dims.height)) }
        }
        let active = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        var size = (width: Int(active.width), height: Int(active.height))
        if let canvas, cameraTypes.contains(device.deviceType),
            let chosen = pickSize(all.map { SizeOption(width: $0.2, height: $0.3, minRate: $0.1.minFrameRate, maxRate: $0.1.maxFrameRate) }, fps: fps, canvas: canvas)
        {
            size = chosen
        }
        let candidates = all.filter { $0.2 == size.width && $0.3 == size.height }
        let options = candidates.map { RateOption(subtype: $0.0.formatDescription.mediaSubType.rawValue, minRate: $0.1.minFrameRate, maxRate: $0.1.maxFrameRate) }
        return pick(options, fps: fps).map { (candidates[$0.index].0, candidates[$0.index].1, $0.rate) }
    }

    /// The frame duration for `rate` within `range`: the range's own end when the rate is (1000/1001-)outside it.
    static func frameDuration(_ rate: Double, in range: AVFrameRateRange) -> CMTime {
        if rate >= range.maxFrameRate { return range.minFrameDuration }
        if rate <= range.minFrameRate { return range.maxFrameDuration }
        return CMTime(seconds: 1 / rate, preferredTimescale: 600_000)  // 59.94 → 1001/60000
    }

    // MARK: Session

    /// Capture queue. Holds the device's configuration lock across `startRunning`, so the session cannot put its preset's
    /// format back over the chosen one; logs what actually runs.
    private func start(_ device: AVCaptureDevice, fps: Double, canvas: (width: Int, height: Int)?) throws {
        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch { throw CaptureError.session("\(error.localizedDescription)") }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.session("the device is in use or offers no video")
        }
        session.addInput(input)
        session.addOutput(output)
        let chosen = Self.bestFormat(device, fps: fps, canvas: canvas)
        let locked = (try? device.lockForConfiguration()) != nil
        defer { if locked { device.unlockForConfiguration() } }
        if let chosen, locked {
            device.activeFormat = chosen.format
            let duration = Self.frameDuration(chosen.rate, in: chosen.range)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration  // a fixed rate: no slowing down in low light
        }
        let native = device.activeFormat.formatDescription.mediaSubType.rawValue
        var pixelFormat = Self.outputPixelFormat(native: native)
        // asking for a format the output does not list raises an Objective-C exception
        if !output.availableVideoPixelFormatTypes.contains(pixelFormat) { pixelFormat = kCVPixelFormatType_32BGRA }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()

        let lost: @Sendable (Notification) -> Void = { [weak self] _ in self?.slot.withLock { $0.interrupted = true } }
        observers = [
            NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil, using: lost),
            NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil, using: lost),
            NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil, using: lost),
        ]
        self.session = session
        session.startRunning()

        // what runs, read after the start (the preset may have had its say)
        let running = device.activeFormat
        let subtype = fourCCString(running.formatDescription.mediaSubType.rawValue)
        let dims = CMVideoFormatDescriptionGetDimensions(running.formatDescription)
        let minDuration = device.activeVideoMinFrameDuration.seconds, maxDuration = device.activeVideoMaxFrameDuration.seconds
        slot.withLock {
            $0.subtype = subtype
            if $0.width == 0 { ($0.width, $0.height) = (Int(dims.width), Int(dims.height)) }
        }
        logger.info(
            "capture \(name): \(subtype) \(dims.width)x\(dims.height) @ \(minDuration > 0 ? 1 / minDuration : 0)",
            metadata: [
                "output": "\(fourCCString(pixelFormat))", "minRate": "\(maxDuration > 0 ? 1 / maxDuration : 0)", "preset": "\(session.sessionPreset.rawValue)",
                "canvasRate": "\(fps)", "locked": "\(locked)",
            ])
        if let chosen, running != chosen.format {
            logger.warning("capture \(name): the session changed the chosen format", metadata: ["wanted": "\(chosen.format)", "running": "\(running)"])
        }
    }

    // MARK: Frames

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        deliver(buffer)
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String
        let outOfBuffers = reason == (kCMSampleBufferDroppedFrameReason_OutOfBuffers as String)
        slot.withLock {
            $0.counters.dropped += 1
            if outOfBuffers { $0.counters.outOfBuffers += 1 }
        }
    }

    /// Capture queue (or a test): makes or finds the buffer's texture views and makes it the newest frame. An untaken
    /// previous frame is released here, outside the lock. Every 60 s the counters are logged.
    func deliver(_ buffer: CVPixelBuffer) {
        guard let frame = views.frame(for: buffer) else { return unusable(buffer) }
        let t = now()
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let (_, logCounters) = slot.withLock { s -> (Held?, Counters?) in
            guard s.alive else { return (nil, nil) }  // stopped, failed or halted: a frame still queued is dropped
            if s.lastFrameNanos != 0 {
                let dt = Double(t &- s.lastFrameNanos) / 1e9
                s.interval = s.interval == 0 ? dt : s.interval * 0.9 + dt * 0.1
            }
            s.lastFrameNanos = t
            s.interrupted = false
            s.counters.frames += 1
            (s.width, s.height) = (width, height)
            let old = s.latestTaken ? nil : s.latest
            s.latest = Held(buffer: buffer, frame: frame)
            s.latestTaken = false
            guard t &- s.lastCountersLog >= Self.countersLogEvery else { return (old, nil) }
            s.lastCountersLog = t
            return (old, s.counters)
        }
        if let logCounters { log(logCounters, "running") }
    }

    /// A frame that cannot be shown: counted, the reason logged once.
    private func unusable(_ buffer: CVPixelBuffer) {
        let first = slot.withLock { s -> Bool in
            s.counters.unusable += 1
            defer { s.unusableLogged = true }
            return !s.unusableLogged
        }
        guard first else { return }
        let reason = CVPixelBufferGetIOSurface(buffer) == nil ? "not IOSurface-backed" : "no texture view for its format"
        logger.warning(
            "capture \(name): a frame could not be shown (\(reason)); counted as unusable",
            metadata: ["format": "\(fourCCString(CVPixelBufferGetPixelFormatType(buffer)))", "size": "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))"])
    }

    private func log(_ c: Counters, _ when: String) {
        logger.info(
            "capture \(name) \(when)",
            metadata: ["frames": "\(c.frames)", "dropped": "\(c.dropped)", "outOfBuffers": "\(c.outOfBuffers)", "unusable": "\(c.unusable)"])
    }

    /// The newest frame, marked taken: it joins the ring of the last three taken frames (once), so its buffer stays
    /// alive while the GPU may read it. Allocates nothing; the frame falling out of the ring is released after the lock.
    public var latestFrame: LiveFrame? {
        let (frame, evicted) = slot.withLock { s -> (LiveFrame?, Held?) in
            guard let latest = s.latest else { return (nil, nil) }
            guard !s.latestTaken else { return (latest.frame, nil) }
            s.latestTaken = true
            let evicted = s.taken[s.next]
            s.taken[s.next] = latest
            s.next = (s.next + 1) % s.taken.count
            return (latest.frame, evicted)
        }
        _ = evicted
        return frame
    }

    public var status: Status {
        let t = now()
        return slot.withLock { s in
            if s.stopped { return .stopped }
            if let failure = s.failure { return .failed(failure) }
            if s.interrupted { return .noSignal }
            if Double(t &- max(s.startNanos, s.lastFrameNanos)) / 1e9 >= noSignalAfter { return .noSignal }
            if s.latest == nil { return .starting }
            return .running(fps: s.interval > 0 ? 1 / s.interval : 0)
        }
    }

    /// One more layer shows this input (two layers on one device share one session); false once it has stopped or
    /// failed (the layer then opens a new session).
    public func share() -> Bool {
        slot.withLock { s in
            guard s.alive else { return false }
            s.users += 1
            return true
        }
    }

    /// Neither stopped nor failed: `share()` would take it.
    public var alive: Bool { slot.withLock { $0.alive } }

    /// One layer lets go; the last one releases the frames at once, and the session stops on the capture queue (after a
    /// start still in progress).
    public func stop() {
        let (_, counters) = slot.withLock { s -> (Slot?, Counters?) in
            s.users -= 1
            guard s.users == 0 else { return (nil, nil) }
            let old = s
            s.latest = nil
            s.taken = [nil, nil, nil]
            s.stopped = true
            return (old, s.counters)
        }
        guard let counters else { return }
        queue.async { [self] in
            endSession()
            log(counters, "stopped")
        }
    }

    /// Capture queue: stops what delivers the frames (`ScreenInput` stops its stream).
    func endSession() {
        session?.stopRunning()
        session = nil
    }

    /// Stops the session but keeps the frames, for every layer on it: the last frame stays on the layers, and the input
    /// reads `.failed(reason)`, so it is not shared again and the next open makes a new one. A display bound as an output
    /// meanwhile (it would show only the engine's excluded windows) is halted so.
    func halt(_ reason: String) {
        let halted = slot.withLock { s -> Bool in
            guard s.alive else { return false }
            s.failure = reason
            return true
        }
        if halted { queue.async { [self] in endSession() } }
    }
}

/// Texture views on a capture buffer's IOSurface, cached by surface (AVFoundation recycles a small pool). Capture queue
/// only. The textures retain their surface, so a cached key cannot be reused by another surface while it is cached.
final class TextureViews {
    private let device: MTLDevice
    private var cache: [ObjectIdentifier: LiveFrame] = [:]
    static let capacity = 8

    init(device: MTLDevice) {
        self.device = device
        cache.reserveCapacity(Self.capacity)
    }

    func frame(for buffer: CVPixelBuffer) -> LiveFrame? {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return nil }
        let key = ObjectIdentifier(surface)
        if let frame = cache[key] { return frame }
        guard let frame = Self.makeFrame(buffer, surface: surface, device: device) else { return nil }
        if cache.count >= Self.capacity { cache.removeAll(keepingCapacity: true) }  // a format change: the old pool is gone
        cache[key] = frame
        return frame
    }

    /// The views for one buffer by its pixel format: packed 4:2:2 as `rgba8Unorm` at half width (`2vuy` → `.v216`,
    /// `yuvs` → `.yuy2`), `420v` as `r8Unorm` + `rg8Unorm` planes, BGRA as `bgra8Unorm`. Nil for anything else.
    static func makeFrame(_ buffer: CVPixelBuffer, surface: IOSurfaceRef, device: MTLDevice) -> LiveFrame? {
        func view(_ format: MTLPixelFormat, _ width: Int, _ height: Int, plane: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: plane)
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_422YpCbCr8:
            return view(.rgba8Unorm, (width + 1) / 2, height, plane: 0).map { LiveFrame(texture0: $0, kind: .v216) }
        case kCVPixelFormatType_422YpCbCr8_yuvs:
            return view(.rgba8Unorm, (width + 1) / 2, height, plane: 0).map { LiveFrame(texture0: $0, kind: .yuy2) }
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let y = view(.r8Unorm, width, height, plane: 0),
                let cbcr = view(.rg8Unorm, CVPixelBufferGetWidthOfPlane(buffer, 1), CVPixelBufferGetHeightOfPlane(buffer, 1), plane: 1)
            else { return nil }
            return LiveFrame(texture0: y, texture1: cbcr, kind: .planarYCbCr)
        case kCVPixelFormatType_32BGRA:
            return view(.bgra8Unorm, width, height, plane: 0).map { LiveFrame(texture0: $0) }
        default:
            return nil
        }
    }
}
