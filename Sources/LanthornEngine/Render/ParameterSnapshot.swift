// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import LanthornCore
import Synchronization

/// Per-layer render parameters in render units (DESIGN.md §7.3), written by
/// the DMX queue (or cues/OSC through it) and read by the compositor.
public struct LayerParameters: Sendable, Equatable {
    public var intensity: Float = 0  // 0…1
    public var folder: UInt8 = 0
    public var file: UInt8 = 0
    public var playMode: PlayMode = .loopForward
    public var speed: Float = 1  // 1 = 100 %
    public var inPoint: Float = 0  // 0…1 of duration
    public var outPoint: Float = 1
    public var dissolve: Float = 0  // seconds
    public var positionX: Float = 0  // −1…1 = −100…100 % of canvas width
    public var positionY: Float = 0
    public var positionZ: Float = 0  // −1…1, towards the camera positive
    public var scaleX: Float = 1  // 1 = 100 %
    public var scaleY: Float = 1
    public var fitMode: FitMode = .fit
    public var rotationX: Float = 0  // radians
    public var rotationY: Float = 0
    public var rotationZ: Float = 0
    public var red: Float = 1  // multiply
    public var green: Float = 1
    public var blue: Float = 1
    public var brightness: Float = 0  // −1…1 offset
    public var contrast: Float = 1  // 0…2
    public var saturation: Float = 1  // 0…2
    public var hue: Float = 0  // radians
    public var blendMode: BlendMode = .normal
    public var effect1: Effect = .none
    public var effect1A: Float = 0  // 0…1
    public var effect1B: Float = 0
    public var effect2: Effect = .none
    public var effect2A: Float = 0
    public var effect2B: Float = 0
    public var cropLeft: Float = 0  // 0…1
    public var cropRight: Float = 0
    public var cropTop: Float = 0
    public var cropBottom: Float = 0
    public var audioVolume: Float = 0  // 0…1
    public var audioPan: Float = 0  // −1…1
    public var control: LayerControl = .idle

    public init() {}

    public var retrigger: Bool { control == .retrigger }
    public var mediaKey: MediaKey { MediaKey(folder: Int(folder), file: Int(file)) }

    public static func from(_ resolver: FixtureResolver) -> LayerParameters {
        var p = LayerParameters()
        func physical(_ id: LayerParameter) -> Float { Float(resolver.physical(.layer(id))) }
        func band<E: RawRepresentable>(_ id: LayerParameter, _: E.Type) -> E? where E.RawValue == Int { E(rawValue: Int(physical(id))) }
        p.intensity = physical(.intensity) / 100
        p.folder = UInt8(clamping: Int(physical(.folder)))
        p.file = UInt8(clamping: Int(physical(.file)))
        p.playMode = band(.playMode, PlayMode.self) ?? .loopForward
        p.speed = physical(.speed) / 100
        p.inPoint = physical(.inPoint) / 100
        p.outPoint = physical(.outPoint) / 100
        p.dissolve = physical(.dissolve)
        p.positionX = physical(.positionX) / 100
        p.positionY = physical(.positionY) / 100
        p.positionZ = physical(.positionZ) / 100
        p.scaleX = physical(.scaleX) / 100
        p.scaleY = physical(.scaleY) / 100
        p.fitMode = band(.fitMode, FitMode.self) ?? .fit
        p.rotationX = physical(.rotationX) * .pi / 180
        p.rotationY = physical(.rotationY) * .pi / 180
        p.rotationZ = physical(.rotationZ) * .pi / 180
        p.red = physical(.red) / 100
        p.green = physical(.green) / 100
        p.blue = physical(.blue) / 100
        p.brightness = physical(.brightness) / 100
        p.contrast = physical(.contrast) / 100
        p.saturation = physical(.saturation) / 100
        p.hue = physical(.hue) * .pi / 180
        p.blendMode = band(.blendMode, BlendMode.self) ?? .normal
        p.effect1 = band(.effect1, Effect.self) ?? .none
        p.effect1A = physical(.effect1A) / 100
        p.effect1B = physical(.effect1B) / 100
        p.effect2 = band(.effect2, Effect.self) ?? .none
        p.effect2A = physical(.effect2A) / 100
        p.effect2B = physical(.effect2B) / 100
        p.cropLeft = physical(.cropLeft) / 100
        p.cropRight = physical(.cropRight) / 100
        p.cropTop = physical(.cropTop) / 100
        p.cropBottom = physical(.cropBottom) / 100
        p.audioVolume = physical(.audioVolume) / 100
        p.audioPan = physical(.audioPan) / 100
        p.control = band(.control, LayerControl.self) ?? .idle
        return p
    }
}

/// Folder/file pair as addressed from DMX (DESIGN.md §7.4).
public struct MediaKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public var folder: Int
    public var file: Int
    public init(folder: Int, file: Int) {
        self.folder = folder
        self.file = file
    }
    public static let none = MediaKey(folder: 0, file: 0)
    public var isNone: Bool { file == 0 }
    public var description: String { "\(folder)/\(file)" }
    /// Packed form for atomics.
    public var packed: UInt32 { UInt32(folder & 0xFF) << 8 | UInt32(file & 0xFF) }
    public init(packed: UInt32) { self.init(folder: Int(packed >> 8 & 0xFF), file: Int(packed & 0xFF)) }
}

/// One triple-buffer slot: preallocated, mutated in place by the writer.
public final class ParameterSnapshotSlot: @unchecked Sendable {
    public var sequence: UInt64 = 0
    /// Host time (CACurrentMediaTime base) of the DMX packet that produced this snapshot; 0 = not DMX.
    public var receivedAt: Double = 0
    public var master: Float = 1
    public var masterControl: MasterControl = .normal
    public var masterSpeed: Float = 1
    public var testPattern: TestPattern = .off
    public var layers: [LayerParameters]

    public init(maxLayers: Int) { layers = Array(repeating: LayerParameters(), count: maxLayers) }

    public static func from(_ resolver: FixtureResolver, into slot: ParameterSnapshotSlot) {
        slot.master = Float(resolver.physical(.master(.intensity)) / 100)
        slot.masterControl = MasterControl(rawValue: Int(resolver.physical(.master(.control)))) ?? .normal
        slot.masterSpeed = Float(resolver.physical(.master(.speed)) / 100)
        slot.testPattern = TestPattern(rawValue: Int(resolver.physical(.master(.testPattern)))) ?? .off
    }

    func copy(from other: ParameterSnapshotSlot) {
        sequence = other.sequence
        receivedAt = other.receivedAt
        master = other.master
        masterControl = other.masterControl
        masterSpeed = other.masterSpeed
        testPattern = other.testPattern
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
