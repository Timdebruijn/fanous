// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Logging
import Metal
import Synchronization
import Testing

@testable import FanousEngine

/// Holds the first compositor tick inside `canvasPublished` (where the Syphon server publishes) until released.
final class HeldTick: @unchecked Sendable {
    let entered = Atomic<Int>(0)
    let finished = Atomic<Bool>(false)
    let inside = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var entries: Int { entered.load(ordering: .relaxed) }
    var isFinished: Bool { finished.load(ordering: .relaxed) }
    private let out = DispatchSemaphore(value: 0)
    /// Blocks until the first tick is held.
    func waitInside() { inside.wait() }
    /// Blocks until the held tick has published.
    func waitFinished() { out.wait() }

    /// Wraps `compositor.canvasPublished`; the first tick blocks, later ones pass through.
    func install(on compositor: Compositor) {
        let publish = compositor.canvasPublished
        compositor.canvasPublished = { [self] texture, commandBuffer in
            let first = entered.wrappingAdd(1, ordering: .relaxed).newValue == 1
            if first {
                inside.signal()
                release.wait()
            }
            publish?(texture, commandBuffer)
            if first {
                finished.store(true, ordering: .relaxed)
                out.signal()
            }
        }
    }

    /// Releases the held tick 0.1 s later from a thread of its own (not a global queue, B63), while the caller is
    /// meant to be inside `stop()`. A late release only makes a broken stop pass; a joining stop passes either way.
    func releaseSoon() {
        Thread.detachNewThread { [self] in
            usleep(100_000)
            release.signal()
        }
    }
}

/// B113: a driver's `stop()` joins the tick in flight, so the Syphon server is never stopped under a publish.
/// `DisplayLinkDriver` needs a CAMetalLayer on a display (not available headless); its join is the same semaphore at
/// thread exit, after its run loop returns, which happens only between callouts.
@Suite(.serialized)
struct DriverStopTests {
    static func compositor() throws -> Compositor {
        try Compositor(
            context: try MetalContext(), canvasWidth: 16, canvasHeight: 9, fps: 240, maxLayers: 1,
            metrics: MetricsRing(capacity: 64), parameters: TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) },
            logger: Logger(label: "driver-stop-test"))
    }

    @Test func stopReturnsOnlyAfterTheTickInFlight() throws {
        let compositor = try Self.compositor()
        let held = HeldTick()
        held.install(on: compositor)
        let driver = HeadlessDriver(fps: 240, compositor: compositor)
        held.waitInside()
        held.releaseSoon()
        #expect(driver.stop())
        // a stop that does not join returns before the release, with the tick still held
        #expect(held.isFinished)
        let ticks = compositor.ticks.load(ordering: .relaxed)
        #expect(held.entries == 1)  // the loop saw the stop before another tick
        #expect(driver.stop())  // again: returns at once
        let ticksAfter = compositor.ticks.load(ordering: .relaxed)
        #expect(ticksAfter == ticks)
    }

    @Test func stopReportsATickThatDoesNotFinish() throws {
        let compositor = try Self.compositor()
        let held = HeldTick()
        held.install(on: compositor)
        let driver = HeadlessDriver(fps: 240, compositor: compositor)
        held.waitInside()
        #expect(!driver.stop())  // the tick is held past the 1 s join
        #expect(!held.isFinished)
        held.release.signal()
        #expect(driver.stop())
        #expect(held.isFinished)
        #expect(held.entries == 1)
    }
}

@Suite(.serialized) @MainActor
struct RenderServiceStopTests {
    static func service() throws -> RenderService {
        var scene = SceneConfig()
        scene.canvasWidth = 16
        scene.canvasHeight = 9
        scene.fps = 240
        scene.audio = false
        scene.syphonOutput = true
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) }
        return try RenderService(
            scene: scene, context: try MetalContext(), parameters: parameters, metrics: MetricsRing(capacity: 64),
            logger: Logger(label: "render-stop-test"))
    }

    @Test func syphonStopsAfterTheTickInFlight() async throws {
        let service = try Self.service()
        let held = HeldTick()
        held.install(on: service.compositor)
        try await service.start()
        held.waitInside()
        held.releaseSoon()
        service.stop()
        #expect(held.isFinished)
        #expect(service.syphon == nil)
    }

    @Test func aTickThatDoesNotFinishLeavesSyphonRunning() async throws {
        let service = try Self.service()
        let held = HeldTick()
        held.install(on: service.compositor)
        try await service.start()
        held.waitInside()
        service.stop()  // waits 1 s for the held tick
        #expect(service.syphon != nil)
        #expect(service.compositor.canvasPublished != nil)
        held.release.signal()
        held.waitFinished()
        service.syphon?.stop()
    }
}
