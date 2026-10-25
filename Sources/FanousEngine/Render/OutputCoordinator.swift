// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import Foundation
import FanousCore
import Logging
import Metal
import QuartzCore
import Synchronization

/// Where an output stands right now, for `live.outputs`.
public struct OutputStatus: Sendable, Equatable {
    public enum State: String, Sendable { case unassigned, bound, lost }
    public var id: Int
    public var state: State
    public var display: String?
    public var width: Int
    public var height: Int
    public var hz: Double
    public var isMaster: Bool
}

/// Pure part of the binding: which outputs land on which connected display (by identity).
public enum OutputBinding {
    public struct Result: Sendable, Equatable {
        public var byDisplay: [CGDirectDisplayID: [Int]]  // output ids per display, in project order
        public var lost: [Int]  // outputs whose display is not connected
        public var unassigned: [Int]
    }

    public static func resolve(outputs: [OutputConfig], displays: [DisplayInfo]) -> Result {
        var byDisplay: [CGDirectDisplayID: [Int]] = [:]
        var lost: [Int] = [], unassigned: [Int] = []
        for output in outputs {
            guard let identity = output.display else {
                unassigned.append(output.id)
                continue
            }
            if let display = displays.first(where: { $0.uuid == identity.uuid }) {
                byDisplay[display.id, default: []].append(output.id)
            } else {
                lost.append(output.id)
            }
        }
        return Result(byDisplay: byDisplay, lost: lost, unassigned: unassigned)
    }

    /// The display that drives the compositor: the clock-master output's, else the first bound one in project order.
    public static func master(outputs: [OutputConfig], binding: Result, clockMaster: Int?) -> CGDirectDisplayID? {
        if let clockMaster, let entry = binding.byDisplay.first(where: { $0.value.contains(clockMaster) }) { return entry.key }
        for output in outputs {
            if let entry = binding.byDisplay.first(where: { $0.value.contains(output.id) }) { return entry.key }
        }
        return nil
    }
}

/// Presents another display from the latest completed canvas (DESIGN.md §4.5), paced like the drawable loop.
final class SecondaryDriver: @unchecked Sendable {
    private let running = Atomic<Bool>(true)
    private var thread: Thread?
    nonisolated(unsafe) var set: OutputSet
    private let uniforms: MTLBuffer

    init(layer: CAMetalLayer, hz: Double, compositor: Compositor, set: OutputSet, uniforms: MTLBuffer) {
        self.set = set
        self.uniforms = uniforms
        layer.maximumDrawableCount = 2
        layer.displaySyncEnabled = true
        let thread = Thread { [self] in
            var timebase = mach_timebase_info()
            mach_timebase_info(&timebase)
            let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
            let period = UInt64(ticksPerSecond / max(1, hz))
            var next = mach_absolute_time() + period
            while running.load(ordering: .relaxed) {
                mach_wait_until(next)
                autoreleasepool {
                    guard let drawable = layer.nextDrawable() else { return }
                    compositor.present(self.set, to: drawable, uniforms: uniforms)
                }
                next += period
                let now = mach_absolute_time()
                if next < now { next = now + period }
            }
        }
        thread.name = "org.fanous.output.secondary"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    func stop() {
        running.store(false, ordering: .relaxed)
        thread.map { Self.join($0) }
    }

    static func join(_ thread: Thread) {
        let deadline = Date().addingTimeInterval(1)
        while !thread.isFinished && Date() < deadline { usleep(2000) }
    }
}

/// Binds project outputs to displays, owns their windows and drivers, elects the clock master and survives
/// hot-plug (DESIGN.md §9.6). Everything on the main actor; the compositor only ever sees swapped `OutputSet`s.
@MainActor
public final class OutputCoordinator {
    private struct Bound {
        var window: OutputWindow
        var display: DisplayInfo
        var set: OutputSet
        var secondary: SecondaryDriver?
    }

    private let compositor: Compositor
    private let context: MetalContext
    private let compiler: OutputCompiler
    private let fps: Double
    private let logger: Logger
    private var outputs: [OutputConfig] = []
    private var clockMaster: Int?
    private var displays: [DisplayInfo]
    private var bound: [CGDirectDisplayID: Bound] = [:]
    private var cursorHidden = false
    private var masterDriver: DrawableLoopDriver?
    private var headless: HeadlessDriver?
    private var masterDisplay: CGDirectDisplayID?
    public private(set) var status: [OutputStatus] = []
    /// Called after every rebind with the new statuses (feeds `live.outputs`).
    public var onStatus: (@MainActor ([OutputStatus]) -> Void)?

    public init(compositor: Compositor, context: MetalContext, fps: Double, displays: [DisplayInfo], logger: Logger) throws {
        self.compositor = compositor
        self.context = context
        self.compiler = try OutputCompiler(device: context.device)
        self.fps = fps
        self.displays = displays
        self.logger = logger
    }

    public var connectedDisplays: [DisplayInfo] { displays }

    /// New project outputs (any edit): recompiles what changed, re-elects the master when needed.
    public func apply(outputs: [OutputConfig], clockMaster: Int?) {
        self.outputs = outputs
        self.clockMaster = clockMaster
        rebind()
    }

    /// Hot-plug or mode change.
    /// Show mode (DESIGN.md §14): no cursor over any bound output; shown again on leaving.
    public func setCursorHidden(_ hidden: Bool) {
        cursorHidden = hidden
        for displayID in bound.keys {
            if hidden { CGDisplayHideCursor(displayID) } else { CGDisplayShowCursor(displayID) }
        }
    }

    public func displaysChanged(_ displays: [DisplayInfo]) {
        self.displays = displays
        rebind()
    }

    public func stop() {
        masterDriver?.stop()
        masterDriver = nil
        headless?.stop()
        headless = nil
        for (_, b) in bound {
            b.secondary?.stop()
            b.window.close()
        }
        bound.removeAll()
        compositor.outputSet = nil
    }

    private func rebind() {
        let binding = OutputBinding.resolve(outputs: outputs, displays: displays)
        let newMaster = OutputBinding.master(outputs: outputs, binding: binding, clockMaster: clockMaster)

        // tear down displays that lost every output or went away
        for (id, b) in bound where binding.byDisplay[id] == nil || !displays.contains(where: { $0.id == id }) {
            logger.info("output display released", metadata: ["display": "\(b.display.name)"])
            if id == masterDisplay { stopMaster() }
            b.secondary?.stop()
            b.window.close()
            bound.removeValue(forKey: id)
        }
        // the master changes: stop its driver before another display's driver may take the compositor
        if masterDisplay != newMaster { stopMaster() }

        var statuses: [OutputStatus] = []
        for (displayID, ids) in binding.byDisplay {
            guard let display = displays.first(where: { $0.id == displayID }) else { continue }
            let window: OutputWindow
            if let existing = bound[displayID], existing.display == display {
                window = existing.window
            } else {
                bound[displayID]?.secondary?.stop()
                bound[displayID]?.window.close()
                guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID })
                else {
                    logger.warning("display has no screen", metadata: ["display": "\(display.name)"])
                    continue
                }
                window = OutputWindow(screen: screen, device: context.device)
                if cursorHidden { CGDisplayHideCursor(displayID) }
                logger.info("output window", metadata: ["display": "\(display.name)", "size": "\(window.metalLayer.drawableSize)"])
            }
            let size = window.metalLayer.drawableSize
            var plans: [OutputPlan] = []
            for id in ids {
                guard let config = outputs.first(where: { $0.id == id }), let index = outputs.firstIndex(where: { $0.id == id }) else { continue }
                do {
                    plans.append(try compiler.compile(config, index: index + 1, drawable: (Int(size.width), Int(size.height))))
                    statuses.append(OutputStatus(id: id, state: .bound, display: display.name, width: Int(size.width), height: Int(size.height), hz: display.hz, isMaster: displayID == newMaster))
                } catch {
                    logger.error("output compile failed", metadata: ["output": "\(id)", "error": "\(error)"])
                }
            }
            let set = OutputSet(plans: plans)
            if displayID == newMaster {
                bound[displayID]?.secondary?.stop()
                compositor.outputSet = set
                if masterDriver == nil {
                    headless?.stop()
                    headless = nil
                    masterDriver = DrawableLoopDriver(layer: window.metalLayer, fps: fps, compositor: compositor)
                    masterDisplay = displayID
                    logger.info("clock master", metadata: ["display": "\(display.name)"])
                }
                bound[displayID] = Bound(window: window, display: display, set: set, secondary: nil)
            } else if let existing = bound[displayID], let secondary = existing.secondary {
                secondary.set = set
                bound[displayID] = Bound(window: window, display: display, set: set, secondary: secondary)
            } else {
                guard let uniforms = context.device.makeBuffer(length: Compositor.mappedUniformsLength, options: .storageModeShared) else { continue }
                let secondary = SecondaryDriver(layer: window.metalLayer, hz: display.hz, compositor: compositor, set: set, uniforms: uniforms)
                bound[displayID] = Bound(window: window, display: display, set: set, secondary: secondary)
            }
        }
        if newMaster == nil, headless == nil {
            compositor.outputSet = nil
            headless = HeadlessDriver(fps: fps, compositor: compositor)
            logger.info("no bound output: headless compositor")
        }
        for id in binding.lost {
            let config = outputs.first { $0.id == id }
            statuses.append(OutputStatus(id: id, state: .lost, display: config?.display?.name, width: 0, height: 0, hz: 0, isMaster: false))
        }
        for id in binding.unassigned { statuses.append(OutputStatus(id: id, state: .unassigned, display: nil, width: 0, height: 0, hz: 0, isMaster: false)) }
        status = statuses.sorted { $0.id < $1.id }
        onStatus?(status)
    }

    private func stopMaster() {
        masterDriver?.stop()
        masterDriver = nil
        masterDisplay = nil
        compositor.outputSet = nil
    }
}
