// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import QuartzCore
import Synchronization

/// Runs the compositor from a CAMetalDisplayLink on a dedicated high-QoS thread (ADR-0006).
public final class DisplayLinkDriver: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    public let updates = Atomic<Int>(0)
    private let link: CAMetalDisplayLink
    private let compositor: Compositor
    private let thread: Thread
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    public init(layer: CAMetalLayer, fps: Double, compositor: Compositor, frameLatency: Int = 1) {
        self.compositor = compositor
        link = CAMetalDisplayLink(metalLayer: layer)
        link.preferredFrameLatency = Float(frameLatency)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
        let link = self.link
        let box = RunLoopBox()
        let onMain = ProcessInfo.processInfo.environment["LANTHORN_LINK_MAIN"] == "1"  // diagnostic switch
        thread = Thread {
            box.runLoop = CFRunLoopGetCurrent()
            if !onMain { link.add(to: RunLoop.current, forMode: .default) }
            box.ready.signal()
            if onMain { return }
            CFRunLoopRun()
        }
        super.init()
        link.delegate = self
        if onMain { link.add(to: RunLoop.main, forMode: .common) }
        thread.name = "org.lanthorn.compositor"
        thread.qualityOfService = .userInteractive
        thread.start()
        box.ready.wait()
        runLoop = box.runLoop
    }

    final class RunLoopBox: @unchecked Sendable {
        var runLoop: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
    }

    public func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        updates.wrappingAdd(1, ordering: .relaxed)
        autoreleasepool { compositor.tick(target: update.targetPresentationTimestamp, drawable: update.drawable) }
    }

    public func stop() {
        link.invalidate()
        thread.cancel()
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}

/// No display: a mach_wait_until clock at the canvas rate (previews, benchmark).
public final class HeadlessDriver: @unchecked Sendable {
    private let running = Atomic<Bool>(true)
    private var thread: Thread?

    public init(fps: Double, compositor: Compositor) {
        let thread = Thread { [self] in
            var timebase = mach_timebase_info()
            mach_timebase_info(&timebase)
            let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
            let period = UInt64(ticksPerSecond / fps)
            var next = mach_absolute_time() + period
            while running.load(ordering: .relaxed) {
                // a tick at time `next` targets the following period, like a display link does
                let target = Double(next + period) / ticksPerSecond
                autoreleasepool { compositor.tick(target: target, drawable: nil) }
                next += period
                mach_wait_until(next)
            }
        }
        thread.name = "org.lanthorn.compositor.headless"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    public func stop() { running.store(false, ordering: .relaxed) }
}

/// Output driver paced by the engine's own clock with `nextDrawable()` for
/// the surface. Used because CAMetalDisplayLink stops delivering updates after
/// its first drawables are presented on macOS 27.0.1 (measured 2026-10-23 in
/// every configuration tried, bundled app included; see ADR-0006 amendment).
/// `displaySyncEnabled` keeps presentation on vsync; `maximumDrawableCount = 2`
/// bounds latency to one frame.
public final class DrawableLoopDriver: @unchecked Sendable {
    private let running = Atomic<Bool>(true)
    private var thread: Thread?

    public init(layer: CAMetalLayer, fps: Double, compositor: Compositor) {
        layer.maximumDrawableCount = 2
        layer.displaySyncEnabled = true
        let thread = Thread { [self] in
            var timebase = mach_timebase_info()
            mach_timebase_info(&timebase)
            let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
            let period = UInt64(ticksPerSecond / fps)
            var next = mach_absolute_time() + period
            while running.load(ordering: .relaxed) {
                mach_wait_until(next)
                autoreleasepool {
                    // blocks only when both drawables are still in flight (the GPU or display is behind)
                    guard let drawable = layer.nextDrawable() else { return }
                    let target = Double(next + period) / ticksPerSecond
                    compositor.tick(target: target, drawable: drawable)
                }
                next += period
                let now = mach_absolute_time()
                if next < now { next = now + period }  // skip missed periods; the compositor counts them from target deltas
            }
        }
        thread.name = "org.lanthorn.compositor"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    public func stop() { running.store(false, ordering: .relaxed) }
}
