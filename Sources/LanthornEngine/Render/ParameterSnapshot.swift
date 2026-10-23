// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import LanthornCore
import Synchronization

/// Per-layer render parameters in render units, written by the DMX queue (or
/// cues/OSC through it) and read by the compositor. Plain value type.
public struct LayerParameters: Sendable, Equatable {
    public var intensity: Float = 0  // 0…1
    public var positionX: Float = 0  // −1…1 = −100…100 % of canvas width
    public var positionY: Float = 0
    public var scaleX: Float = 1  // 1 = 100 %
    public var scaleY: Float = 1
    public var rotationZ: Float = 0  // radians
    public var speed: Float = 1  // 1 = 100 %
    public var playMode: PlayMode = .loopForward
    public var inPoint: Float = 0  // 0…1 of duration
    public var outPoint: Float = 1
    public var folder: UInt8 = 0
    public var file: UInt8 = 0
    public var retrigger = false

    public init() {}

    public static func from(_ resolver: FixtureResolver) -> LayerParameters {
        var p = LayerParameters()
        func physical(_ id: LayerParameter) -> Float { Float(resolver.physical(.layer(id))) }
        p.intensity = physical(.intensity) / 100
        p.positionX = physical(.positionX) / 100
        p.positionY = physical(.positionY) / 100
        p.scaleX = physical(.scaleX) / 100
        p.scaleY = physical(.scaleY) / 100
        p.rotationZ = physical(.rotationZ) * .pi / 180
        p.speed = physical(.speed) / 100
        p.playMode = PlayMode(rawValue: Int(physical(.playMode))) ?? .loopForward
        p.inPoint = physical(.inPoint) / 100
        p.outPoint = physical(.outPoint) / 100
        p.folder = UInt8(clamping: Int(physical(.folder)))
        p.file = UInt8(clamping: Int(physical(.file)))
        p.retrigger = Int(physical(.control)) == LayerControl.retrigger.rawValue
        return p
    }
}

/// One triple-buffer slot: preallocated, mutated in place by the writer.
public final class ParameterSnapshotSlot: @unchecked Sendable {
    public var sequence: UInt64 = 0
    /// Host time (CACurrentMediaTime base) of the DMX packet that produced this snapshot; 0 = not DMX.
    public var receivedAt: Double = 0
    public var master: Float = 1
    public var layers: [LayerParameters]

    public init(maxLayers: Int) { layers = Array(repeating: LayerParameters(), count: maxLayers) }

    func copy(from other: ParameterSnapshotSlot) {
        sequence = other.sequence
        receivedAt = other.receivedAt
        master = other.master
        for i in layers.indices { layers[i] = other.layers[i] }
    }
}

/// Lock-free single-writer / single-reader triple buffer (DESIGN.md §2.2).
/// The writer and the reader each own one slot; the third is "published".
/// A single atomic exchange hands slots over, so neither side ever waits.
public final class TripleBuffer<Slot: AnyObject>: @unchecked Sendable {
    private let slots: [Slot]
    private let published = Atomic<Int>(0)  // slot index | (hasNew << 8)
    private var writing = 1
    private var reading = 2

    public init(_ make: () -> Slot) { slots = [make(), make(), make()] }

    /// Writer: fill the slot, then publish it.
    public func write(_ body: (Slot) -> Void) {
        body(slots[writing])
        let old = published.exchange(writing | 0x100, ordering: .acquiringAndReleasing)
        writing = old & 0xFF
    }

    /// Reader: the newest published slot (or the one read last time when nothing new arrived).
    public func read() -> Slot {
        let current = published.load(ordering: .acquiring)
        if current & 0x100 != 0 {
            let old = published.exchange(reading, ordering: .acquiringAndReleasing)
            reading = old & 0xFF
        }
        return slots[reading]
    }
}
