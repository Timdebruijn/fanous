// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Logging
import Metal
@preconcurrency import ScreenCaptureKit

/// A whole display as a live layer source (folder 0 files 21–28, DESIGN.md §8.2.1): an `SCStream` of the display without
/// the engine's own windows, BGRA in sRGB at the display's pixel size fitted into the canvas, at the canvas rate. It is a
/// `CaptureInput` on another session: the same frame ring, texture views (`.rgba` as `bgra8Unorm`), counters, status and
/// sharing. A display has no "no signal": ScreenCaptureKit sends a frame when the picture changes, so a still slide
/// sends none (an idle sample keeps the last frame); a stream that stops with an error reads `.failed`.
public final class ScreenInput: CaptureInput, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Capture queue only.
    private var stream: SCStream?

    /// The loader's entry: refuses without the screen-recording grant (macOS applies a grant to a new process only, so
    /// nothing is asked here), finds the display by `uuid` and starts its stream on the capture queue (`.starting` until
    /// the first frame).
    public static func open(
        uuid: String, name: String, metal: MTLDevice, fps: Double, canvas: (width: Int, height: Int), granted: Bool, logger: Logger
    ) throws -> ScreenInput {
        guard granted else { throw CaptureError.screenPermission }
        guard let display = display(uuid: uuid) else { throw CaptureError.noDisplay(uuid) }
        let input = ScreenInput(name: name, metal: metal, logger: logger, queueLabel: "org.fanous.screen.\(uuid)", noSignalAfter: .infinity)
        let size = fit(width: display.width, height: display.height, into: canvas)
        input.queue.async { [input] in input.request(display.id, width: size.width, height: size.height, fps: fps) }
        return input
    }

    /// The online display with this CG UUID and its pixel size (`DisplayInfo.pixelWidth/Height`: the mode's pixels, not
    /// `SCDisplay`'s points). CoreGraphics only, so any thread.
    static func display(uuid: String) -> (id: CGDirectDisplayID, width: Int, height: Int)? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        for id in ids.prefix(Int(count)) {
            guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(), CFUUIDCreateString(nil, cf) as String == uuid else { continue }
            let mode = CGDisplayCopyDisplayMode(id)
            return (id, mode?.pixelWidth ?? Int(CGDisplayPixelsWide(id)), mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(id)))
        }
        return nil
    }

    /// `capture.authorize {kind: "screen"}` after `CGRequestScreenCaptureAccess()` (which returns at once; the grant is
    /// given in System Settings): `preflight` is read every `interval` seconds on `queue` until it is true (`done(true)`)
    /// or has read false `attempts` times (`done(false)`). The engine passes `CGPreflightScreenCaptureAccess`.
    static func pollGrant(
        preflight: @escaping @Sendable () -> Bool, interval: Double = 1, attempts: Int = 120, queue: DispatchQueue = .global(qos: .utility),
        done: @escaping @Sendable (Bool) -> Void
    ) {
        queue.asyncAfter(deadline: .now() + interval) {
            if preflight() { return done(true) }
            guard attempts > 1 else { return done(false) }
            pollGrant(preflight: preflight, interval: interval, attempts: attempts - 1, queue: queue, done: done)
        }
    }

    /// The display's pixel size, scaled down (aspect kept) when it is larger than the canvas; ScreenCaptureKit scales.
    static func fit(width: Int, height: Int, into canvas: (width: Int, height: Int)) -> (width: Int, height: Int) {
        guard width > 0, height > 0, width > canvas.width || height > canvas.height else { return (width, height) }
        let scale = min(Double(canvas.width) / Double(width), Double(canvas.height) / Double(height))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// Capture queue: the shareable content first (to find the display and the engine's own app), then the stream.
    private func request(_ displayID: CGDirectDisplayID, width: Int, height: Int, fps: Double) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [self] content, error in
            nonisolated(unsafe) let content = content
            queue.async { [self] in start(content, error, displayID, width: width, height: height, fps: fps) }
        }
    }

    private func start(_ content: SCShareableContent?, _ error: Error?, _ displayID: CGDirectDisplayID, width: Int, height: Int, fps: Double) {
        guard alive else { return }  // stopped while the content was read
        guard let content, let display = content.displays.first(where: { $0.displayID == displayID }) else {
            return fail(error.map { "screen capture unavailable: \($0.localizedDescription)" } ?? "the display is not offered for capture")
        }
        // an output on a captured display would feed back: the engine's windows are never in the picture
        let own = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB  // the default follows the display (P3 on most Macs)
        configuration.minimumFrameInterval = CMTime(seconds: 1 / fps, preferredTimescale: 600_000)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        // the ring may hold 3 taken frames plus the newest, all four of a depth-4 queue's surfaces; SCK wants a surface
        // back within minimumFrameInterval × (queueDepth − 1), so two more keep the stream from waiting on the ring
        configuration.queueDepth = 6
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) } catch {
            return fail("screen capture could not start: \(error.localizedDescription)")
        }
        self.stream = stream
        slot.withLock { $0.subtype = "BGRA" }
        let excluded = own.count
        stream.startCapture { [self] error in
            queue.async { [self] in
                // stopped, halted or replaced while the start was pending: `endSession` found nothing running to stop
                guard alive, self.stream === stream else { return stream.stopCapture { _ in } }
                if let error { return fail("screen capture could not start: \(error.localizedDescription)") }
                logger.info("capture \(name): BGRA \(width)x\(height) @ \(fps)", metadata: ["display": "\(displayID)", "excludedApps": "\(excluded)"])
            }
        }
    }

    private func fail(_ reason: String) {
        logger.warning("capture \(name) failed", metadata: ["error": "\(reason)"])
        slot.withLock { if $0.failure == nil { $0.failure = reason } }
    }

    override func endSession() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, Self.isComplete(sampleBuffer), let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        deliver(buffer)
    }

    /// A sample with a new picture; an idle display's samples (`.idle`) and the others keep the last frame.
    static func isComplete(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int
        else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        fail("screen capture stopped: \(error.localizedDescription)")
    }
}
