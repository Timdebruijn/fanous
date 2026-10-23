// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import QuartzCore
import Synchronization

/// Runs the compositor from a CAMetalDisplayLink on a dedicated high-QoS thread (ADR-0006).
public final class DisplayLinkDriver: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
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
        thread = Thread {
            box.runLoop = CFRunLoopGetCurrent()
            link.add(to: RunLoop.current, forMode: .default)
            box.ready.signal()
            while !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        super.init()
        link.delegate = self
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
        compositor.tick(target: update.targetPresentationTimestamp, drawable: update.drawable)
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
                let target = Double(next) / ticksPerSecond
                compositor.tick(target: target, drawable: nil)
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
