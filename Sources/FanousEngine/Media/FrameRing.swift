// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Synchronization

/// Single-producer (decode thread) / single-consumer (compositor) ring of
/// preallocated frame slots. Indices only grow; slots are reused modulo capacity.
public final class FrameRing: @unchecked Sendable {
    public let capacity: Int
    public let slots: [DecodedFrame]
    private let head = Atomic<Int>(0)  // consumer position
    private let tail = Atomic<Int>(0)  // producer position

    public init(capacity: Int) {
        self.capacity = capacity
        slots = (0..<capacity).map { DecodedFrame(poolIndex: $0) }
    }

    public var count: Int { tail.load(ordering: .acquiring) - head.load(ordering: .relaxed) }
    public var isEmpty: Bool { count == 0 }

    // Producer side

    public func slotForWriting() -> DecodedFrame? {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        return t - h < capacity ? slots[t % capacity] : nil
    }

    public func commit() { tail.wrappingAdd(1, ordering: .releasing) }

    // Consumer side

    public func peek(_ offset: Int = 0) -> DecodedFrame? {
        guard offset < count else { return nil }
        return slots[(head.load(ordering: .relaxed) + offset) % capacity]
    }

    public func pop() { head.wrappingAdd(1, ordering: .releasing) }

    public func drain() { while !isEmpty { pop() } }
}
