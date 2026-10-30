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

    /// Wraps `compositor.canvasPublished`; the first tick blocks, later ones pass through. `inCompletedHandler`: the
    /// first tick does not block, the completed handler it adds to its command buffer does (as Syphon's own does on
    /// Metal's completion thread).
    func install(on compositor: Compositor, inCompletedHandler: Bool = false) {
        let publish = compositor.canvasPublished
        compositor.canvasPublished = { [self] texture, commandBuffer in
            let first = entered.wrappingAdd(1, ordering: .relaxed).newValue == 1
            if first, inCompletedHandler {
                commandBuffer.addCompletedHandler { [self] _ in hold() }
                publish?(texture, commandBuffer)
            } else if first {
                inside.signal()
                release.wait()
                publish?(texture, commandBuffer)
                done()
            } else {
                publish?(texture, commandBuffer)
            }
        }
    }

    private func hold() {
        inside.signal()
        release.wait()
        done()
    }

    private func done() {
        finished.store(true, ordering: .relaxed)
        out.signal()
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
        // no `entries == 1` here: a release before the stop reached the loop may rightly let a tick more run
        // (stopReportsATickThatDoesNotFinish checks it where the release comes after the stop)
        let ticks = compositor.ticks.load(ordering: .relaxed)
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
    static func service(parameters: TripleBuffer<ParameterSnapshotSlot> = TripleBuffer { ParameterSnapshotSlot(maxLayers: 1) }) throws -> RenderService {
        var scene = SceneConfig()
        scene.canvasWidth = 16
        scene.canvasHeight = 9
        scene.fps = 240
        scene.audio = false
        scene.syphonOutput = true
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

    @Test func syphonStopsAfterTheCompletedHandlersInFlight() async throws {
        let service = try Self.service()
        let held = HeldTick()
        held.install(on: service.compositor, inCompletedHandler: true)
        try await service.start()
        held.waitInside()  // the first tick's completed handler is running and held
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

/// B121: a layer added at runtime (`layers.setCount`) renders at once, and one removed again lets its media go.
@Suite(.serialized) @MainActor
struct RenderServiceLayerTests {
    /// The service holds every layer the snapshot addresses, whatever the scene's count (1 here); a layer whose slot
    /// empties (removed: no fixture, so the DMX store writes the defaults) stops showing its media.
    @Test func aLayerAboveTheStartCountPlaysAndStopsWhenItsSlotEmpties() async throws {
        let parameters = TripleBuffer { ParameterSnapshotSlot(maxLayers: ParameterSnapshotSlot.maxLayers) }
        let service = try RenderServiceStopTests.service(parameters: parameters)
        try #require(service.layers.count == ParameterSnapshotSlot.maxLayers)
        try await service.start()
        defer { service.stop() }
        func show(file: UInt8, sequence: UInt64) {
            // the buffer hands back a slot with an older write in it: every write sets what layer 5 shows
            parameters.write { slot in
                slot.sequence = sequence
                (slot.layers[4].folder, slot.layers[4].file, slot.layers[4].intensity) = (0, file, file == 0 ? 0 : 1)
            }
        }
        let layer5 = service.layers[4]
        show(file: 101, sequence: 1)  // the Grid generator
        #expect(await waitUntil { @Sendable in layer5.mediaStatus.withLock { $0.kind } == "live" })
        show(file: 0, sequence: 2)
        #expect(await waitUntil { @Sendable in layer5.mediaStatus.withLock { $0.kind } == "none" })
    }
}
