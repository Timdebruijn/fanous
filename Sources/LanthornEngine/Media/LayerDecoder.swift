// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Logging
import Synchronization

/// One decode thread per layer (DESIGN.md §4.2). The compositor asks for a
/// frame index each tick; the thread fills the ring ahead in play direction
/// and restarts from the requested index on a seek.
public final class LayerDecoder: @unchecked Sendable {
    public let ring: FrameRing
    public let source: MovieSource
    private let wanted = Atomic<Int>(0)
    private let direction = Atomic<Int>(1)
    private let running = Atomic<Bool>(true)
    private let wake = DispatchSemaphore(value: 0)
    private let logger: Logger
    private var thread: Thread?
    private var lastProduced = -1
    public let errors = Atomic<Int>(0)
    public let decoded = Atomic<Int>(0)

    public init(source: MovieSource, ring: FrameRing, logger: Logger) {
        self.source = source
        self.ring = ring
        self.logger = logger
    }

    public func start(name: String) {
        let thread = Thread { [self] in loop() }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
        self.thread = thread
    }

    public func stop() {
        running.store(false, ordering: .relaxed)
        wake.signal()
    }

    /// Called by the compositor every tick (never blocks).
    public func request(frame: Int, direction: Int) {
        wanted.store(frame, ordering: .relaxed)
        self.direction.store(direction >= 0 ? 1 : -1, ordering: .relaxed)
        wake.signal()
    }

    private func loop() {
        let count = source.info.frameCount
        while running.load(ordering: .relaxed) {
            guard let slot = ring.slotForWriting() else {
                wake.wait()
                continue
            }
            let want = ((wanted.load(ordering: .relaxed) % count) + count) % count
            let dir = direction.load(ordering: .relaxed)
            var next = want
            if lastProduced >= 0, !ring.isEmpty {
                let ahead = dir > 0 ? (want - lastProduced + count) % count : (lastProduced - want + count) % count
                next = ahead <= ring.capacity ? (lastProduced + dir + count) % count : want
            }
            do {
                try autoreleasepool { try source.decode(frame: next, into: slot) }
                ring.commit()
                lastProduced = next
                decoded.wrappingAdd(1, ordering: .relaxed)
            } catch {
                errors.wrappingAdd(1, ordering: .relaxed)
                logger.error("decode failed", metadata: ["file": "\(source.url.lastPathComponent)", "frame": "\(next)", "error": "\(error)"])
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}
