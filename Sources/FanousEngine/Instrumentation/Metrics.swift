// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Synchronization

/// One compositor tick. Written on the render thread, GPU fields patched by a later
/// tick once its command buffer finished (B105); readers copy.
public struct FrameRecord: Sendable {
    public var target: Double = 0  // target presentation time (host seconds)
    public var cpuMicros: UInt32 = 0
    public var gpuMicros: UInt32 = 0
    public var late = false
    public var missed: UInt16 = 0  // display-link ticks skipped before this one
    public var textureMisses: UInt16 = 0  // layers that had no decoded frame ready
    public var dmxToPhotonMicros: UInt32 = 0  // 0 = no new DMX this tick
    public var complete = false
    /// No GPU work was encoded because nothing consumed the canvas; not a drop.
    public var idle = false
}

public struct MetricsSummary: Sendable, CustomStringConvertible {
    public var frames = 0
    public var missed = 0
    public var late = 0
    public var textureMisses = 0
    public var idle = 0
    public var cpuP50 = 0.0, cpuP99 = 0.0, cpuMax = 0.0
    public var gpuP50 = 0.0, gpuP99 = 0.0, gpuMax = 0.0
    public var dmxP50 = 0.0, dmxP99 = 0.0, dmxSamples = 0
    public var seconds = 0.0

    public var description: String {
        String(
            format: "frames %d  missed %d  late %d  textureMisses %d | cpu ms p50 %.2f p99 %.2f max %.2f | gpu ms p50 %.2f p99 %.2f max %.2f | dmx→photon ms p50 %.1f p99 %.1f (n=%d) | %.1f s",
            frames, missed, late, textureMisses, cpuP50, cpuP99, cpuMax, gpuP50, gpuP99, gpuMax, dmxP50, dmxP99, dmxSamples, seconds)
    }
}

public final class MetricsRing: @unchecked Sendable {
    public let capacity: Int
    private var records: [FrameRecord]
    private let writeIndex = Atomic<Int>(0)

    /// Since start, for soak tests (`/metrics`): frames presented, display-link ticks missed, late presents.
    public let totalFrames = Atomic<Int>(0)
    public let totalMissed = Atomic<Int>(0)
    public let totalLate = Atomic<Int>(0)

    public init(capacity: Int = 16_384) {
        self.capacity = capacity
        records = Array(repeating: FrameRecord(), count: capacity)
    }

    /// Render thread: stores the record, returns its slot for later GPU patching.
    public func write(_ record: FrameRecord) -> Int {
        let index = writeIndex.wrappingAdd(1, ordering: .relaxed).oldValue
        records[index % capacity] = record
        totalFrames.wrappingAdd(1, ordering: .relaxed)
        if record.missed > 0 { totalMissed.wrappingAdd(Int(record.missed), ordering: .relaxed) }
        return index % capacity
    }

    /// Render thread, a few ticks after `write`: fills in GPU timing.
    public func complete(slot: Int, gpuMicros: UInt32, late: Bool) {
        records[slot].gpuMicros = gpuMicros
        records[slot].late = late
        records[slot].complete = true
        if late { totalLate.wrappingAdd(1, ordering: .relaxed) }
    }


    /// Records written in the last `seconds` (by target time), oldest first.
    public func recent(seconds: Double, now: Double) -> [FrameRecord] {
        let written = writeIndex.load(ordering: .relaxed)
        let n = min(capacity, written)
        var out: [FrameRecord] = []
        out.reserveCapacity(n)
        for i in (written - n)..<written {
            let r = records[i % capacity]
            if r.target >= now - seconds { out.append(r) }
        }
        return out
    }

    public func summary(seconds: Double, now: Double) -> MetricsSummary {
        let frames = recent(seconds: seconds, now: now)
        var s = MetricsSummary()
        s.frames = frames.count
        s.missed = frames.reduce(0) { $0 + Int($1.missed) }
        s.late = frames.filter(\.late).count
        s.idle = frames.filter(\.idle).count
        s.textureMisses = frames.reduce(0) { $0 + Int($1.textureMisses) }
        func percentiles(_ values: [Double]) -> (Double, Double, Double) {
            guard !values.isEmpty else { return (0, 0, 0) }
            let sorted = values.sorted()
            return (sorted[sorted.count / 2], sorted[Int(Double(sorted.count - 1) * 0.99)], sorted.last!)
        }
        (s.cpuP50, s.cpuP99, s.cpuMax) = percentiles(frames.map { Double($0.cpuMicros) / 1000 })
        (s.gpuP50, s.gpuP99, s.gpuMax) = percentiles(frames.filter(\.complete).map { Double($0.gpuMicros) / 1000 })
        let dmx = frames.filter { $0.dmxToPhotonMicros > 0 }.map { Double($0.dmxToPhotonMicros) / 1000 }
        (s.dmxP50, s.dmxP99, _) = percentiles(dmx)
        s.dmxSamples = dmx.count
        if let first = frames.first, let last = frames.last { s.seconds = last.target - first.target }
        return s
    }
}
