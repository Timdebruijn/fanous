// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import CoreVideo
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

    public var description: String {
        switch self {
        case .permissionNotAsked: "camera permission not asked: authorize on the System screen"
        case .permissionPending: "waiting for camera permission"
        case .permissionDenied: "camera permission denied: allow Fanous Engine under Privacy & Security › Camera"
        case .noDevice(let uid): "no capture device \(uid)"
        case .session(let reason): "capture could not start: \(reason)"
        }
    }
}

/// One AVFoundation capture device (camera, capture card, Continuity Camera) as a live layer source (DESIGN.md §8.2.1).
/// Frames arrive on the device's own serial queue; the textures are views on each frame's IOSurface, made once per
/// pool buffer. The compositor's `latestFrame` read marks the frame taken: the last three taken frames stay retained
/// (command buffers in flight) beside the newest, everything else goes back to AVFoundation's pool.
public final class CaptureInput: NSObject, LiveTextureSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case starting
        case running(fps: Double)
        case noSignal
        case stopped
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
        var interval = 0.0  // smoothed seconds between frames
        var interrupted = false
        var stopped = false
    }

    public let name: String
    /// The device's native subtype (`2vuy`, `yuvs`, `420v`, `jpeg`, …), empty for a synthetic input.
    public private(set) var subtype = ""
    public private(set) var width = 0
    public private(set) var height = 0
    /// No frame for this long reads `.noSignal` (the last frame stays on the layer).
    let noSignalAfter: Double
    private let now: @Sendable () -> UInt64
    private let views: TextureViews
    private let logger: Logger
    let slot = Mutex(Slot())
    private let frameCount = Atomic<Int>(0)
    private let lateCount = Atomic<Int>(0)
    private let outOfBufferCount = Atomic<Int>(0)
    private var session: AVCaptureSession?
    private var observers: [any NSObjectProtocol] = []
    private let queue: DispatchQueue

    /// Frames delivered, frames AVFoundation dropped (any reason), and of those the ones dropped for want of a pool buffer.
    public var frames: Int { frameCount.load(ordering: .relaxed) }
    public var droppedFrames: Int { lateCount.load(ordering: .relaxed) + outOfBuffers }
    public var outOfBuffers: Int { outOfBufferCount.load(ordering: .relaxed) }

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
        queue = DispatchQueue(label: queueLabel)
        super.init()
        let start = now()
        slot.withLock { $0.startNanos = start }
    }

    /// Opens `device` at its current input size, the highest frame rate at or below `fps`, and starts it.
    public convenience init(device: AVCaptureDevice, metal: MTLDevice, fps: Double, logger: Logger) throws {
        self.init(name: device.localizedName, metal: metal, logger: logger, queueLabel: "org.fanous.capture.\(device.uniqueID)")
        try open(device, fps: fps)
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
        uid: String, metal: MTLDevice, fps: Double, allowed: Bool, logger: Logger, onAnswer: @escaping @Sendable () -> Void
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
        return try CaptureInput(device: device, metal: metal, fps: fps, logger: logger)
    }

    // MARK: Session

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

    /// The format of the active format's size with the highest frame rate at or below `fps`, nil when none (a card
    /// follows its input, so the size is the input's).
    static func bestFormat(_ device: AVCaptureDevice, fps: Double) -> (format: AVCaptureDevice.Format, range: AVFrameRateRange)? {
        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        var best: (format: AVCaptureDevice.Format, range: AVFrameRateRange)?
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width == size.width, dims.height == size.height else { continue }
            for range in format.videoSupportedFrameRateRanges where range.maxFrameRate <= fps + 0.01 {
                if range.maxFrameRate > best?.range.maxFrameRate ?? 0 { best = (format, range) }
            }
        }
        return best
    }

    private func open(_ device: AVCaptureDevice, fps: Double) throws {
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
        var rate = 0.0
        if let (format, range) = Self.bestFormat(device, fps: fps), (try? device.lockForConfiguration()) != nil {
            device.activeFormat = format
            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.unlockForConfiguration()
            rate = range.maxFrameRate
        } else {
            rate = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
        let native = device.activeFormat.formatDescription.mediaSubType.rawValue
        var pixelFormat = Self.outputPixelFormat(native: native)
        // asking for a format the output does not list raises an Objective-C exception
        if !output.availableVideoPixelFormatTypes.contains(pixelFormat) { pixelFormat = kCVPixelFormatType_32BGRA }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        output.setSampleBufferDelegate(self, queue: queue)
        session.commitConfiguration()
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        subtype = fourCCString(native)
        width = Int(dims.width)
        height = Int(dims.height)
        logger.info("capture \(name): \(subtype) \(width)x\(height) @ \(rate)", metadata: ["output": "\(fourCCString(pixelFormat))"])

        let lost: @Sendable (Notification) -> Void = { [weak self] _ in self?.slot.withLock { $0.interrupted = true } }
        observers = [
            NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil, using: lost),
            NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil, using: lost),
            NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil, using: lost),
        ]
        self.session = session
        session.startRunning()  // blocks until running: the loader thread, never the compositor
    }

    // MARK: Frames

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        deliver(buffer)
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String
        if reason == (kCMSampleBufferDroppedFrameReason_OutOfBuffers as String) {
            outOfBufferCount.wrappingAdd(1, ordering: .relaxed)
        } else {
            lateCount.wrappingAdd(1, ordering: .relaxed)
        }
    }

    /// Capture queue (or a test): makes or finds the buffer's texture views and makes it the newest frame. An untaken
    /// previous frame is released here, outside the lock.
    func deliver(_ buffer: CVPixelBuffer) {
        guard let frame = views.frame(for: buffer) else { return }
        let t = now()
        _ = slot.withLock { s -> Held? in
            guard !s.stopped else { return nil }
            if s.lastFrameNanos != 0 {
                let dt = Double(t &- s.lastFrameNanos) / 1e9
                s.interval = s.interval == 0 ? dt : s.interval * 0.9 + dt * 0.1
            }
            s.lastFrameNanos = t
            s.interrupted = false
            let old = s.latestTaken ? nil : s.latest
            s.latest = Held(buffer: buffer, frame: frame)
            s.latestTaken = false
            return old
        }
        frameCount.wrappingAdd(1, ordering: .relaxed)
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
            if s.interrupted { return .noSignal }
            if Double(t &- max(s.startNanos, s.lastFrameNanos)) / 1e9 >= noSignalAfter { return .noSignal }
            if s.latest == nil { return .starting }
            return .running(fps: s.interval > 0 ? 1 / s.interval : 0)
        }
    }

    public func stop() {
        session?.stopRunning()
        _ = slot.withLock { s -> Slot in
            let old = s
            s.latest = nil
            s.taken = [nil, nil, nil]
            s.stopped = true
            return old
        }
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
