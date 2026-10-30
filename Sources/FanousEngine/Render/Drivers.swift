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
    private let done = DispatchSemaphore(value: 0)

    public init(layer: CAMetalLayer, fps: Double, compositor: Compositor, frameLatency: Int = 1) {
        self.compositor = compositor
        link = CAMetalDisplayLink(metalLayer: layer)
        link.preferredFrameLatency = Float(frameLatency)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
        let link = self.link
        let box = RunLoopBox()
        let onMain = ProcessInfo.processInfo.environment["FANOUS_LINK_MAIN"] == "1"  // diagnostic switch
        let done = self.done
        thread = Thread {
            defer { done.signal() }
            box.runLoop = CFRunLoopGetCurrent()
            if !onMain { link.add(to: RunLoop.current, forMode: .default) }
            box.ready.signal()
            if onMain { return }
            CFRunLoopRun()
        }
        super.init()
        link.delegate = self
        if onMain { link.add(to: RunLoop.main, forMode: .common) }
        thread.name = "org.fanous.compositor"
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

    /// Stops and waits (≤ 1 s) for the thread to leave its run loop, which returns only between callouts, so the tick
    /// in flight has finished (B113); false = still ticking. With `FANOUS_LINK_MAIN` the ticks run on the caller's
    /// (main) thread, so none is in flight here. Safe to call again.
    @discardableResult public func stop() -> Bool {
        link.invalidate()
        thread.cancel()
        if let runLoop { CFRunLoopStop(runLoop) }
        return done.join()
    }
}

/// A `.userInteractive` thread that runs `body` once per period of the mach clock at `hz` (ADR-0006), each call in
/// its own autorelease pool. `body` gets the target presentation time (host seconds) of the period after the one it
/// runs in, like a display link. Paced (the drawable loops): wait for the period, run, and skip periods that were
/// missed, so the compositor counts them from target deltas. `catchUp` (headless): run, then wait, and run late
/// periods back to back, so every target is one period after the last.
final class PacedThread: @unchecked Sendable {
    static let ticksPerSecond: Double = {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        return 1e9 * Double(timebase.denom) / Double(timebase.numer)
    }()

    private let running = Atomic<Bool>(true)
    private let done = DispatchSemaphore(value: 0)

    init(name: String, hz: Double, catchUp: Bool = false, body: @escaping (_ target: Double) -> Void) {
        let thread = Thread { [self] in
            let ticksPerSecond = Self.ticksPerSecond
            let period = UInt64(ticksPerSecond / hz)
            var next = mach_absolute_time() + period
            while running.load(ordering: .relaxed) {
                if catchUp {
                    autoreleasepool { body(Double(next + period) / ticksPerSecond) }
                    next += period
                    mach_wait_until(next)
                } else {
                    mach_wait_until(next)
                    autoreleasepool { body(Double(next + period) / ticksPerSecond) }
                    next += period
                    let now = mach_absolute_time()
                    if next < now { next = now + period }  // skip missed periods; the compositor counts them from target deltas
                }
            }
            done.signal()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops and waits (≤ 1 s) for the last run of `body`; false = still running. Safe to call again.
    @discardableResult func stop() -> Bool {
        running.store(false, ordering: .relaxed)
        return done.join()
    }
}

extension DispatchSemaphore {
    /// Waits ≤ 1 s for a thread's exit signal and passes it on, so a later join returns at once; false = still running.
    fileprivate func join() -> Bool {
        guard wait(timeout: .now() + 1) == .success else { return false }
        signal()
        return true
    }
}

/// No display: a mach_wait_until clock at the canvas rate (previews, benchmark).
public final class HeadlessDriver: @unchecked Sendable {
    private let thread: PacedThread

    public init(fps: Double, compositor: Compositor) {
        thread = PacedThread(name: "org.fanous.compositor.headless", hz: fps, catchUp: true) { target in
            compositor.tick(target: target, drawable: nil)
        }
    }

    /// Stops and waits (≤ 1 s) for the last tick, so another driver can take the compositor; false = still ticking.
    @discardableResult public func stop() -> Bool { thread.stop() }
}

/// Output driver paced by the engine's own clock with `nextDrawable()` for
/// the surface. Used because CAMetalDisplayLink stops delivering updates after
/// its first drawables are presented on macOS 27.0.1 (measured 2026-10-23 in
/// every configuration tried, bundled app included; see ADR-0006 amendment).
/// `displaySyncEnabled` keeps presentation on vsync. Three drawables, not two: this clock and the display's drift
/// against each other (a 120 Hz ProMotion panel most of all), and with two drawables both were periodically still in
/// flight, so `nextDrawable()` blocked and 15–25 frames were missed in a 2–3 s burst every 15–20 s (measured
/// 2026-10-26; 0 missed in 6 min with three). The loop still produces at the canvas rate, so the queue stays short and
/// the third drawable only absorbs the phase drift.
public final class DrawableLoopDriver: @unchecked Sendable {
    private let thread: PacedThread

    public init(layer: CAMetalLayer, fps: Double, compositor: Compositor) {
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        thread = PacedThread(name: "org.fanous.compositor", hz: fps) { target in
            // blocks only when every drawable is still in flight (the GPU or display is behind)
            guard let drawable = layer.nextDrawable() else { return }
            compositor.tick(target: target, drawable: drawable)
        }
    }

    /// Stops and waits (≤ 1 s) for the last tick, so another driver can take the compositor; false = still ticking.
    @discardableResult public func stop() -> Bool { thread.stop() }
}
