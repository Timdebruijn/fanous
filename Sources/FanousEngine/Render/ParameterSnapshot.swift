// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import simd
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
    public var sync: LayerSync = .off

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
        p.sync = LayerSync(bandValue: Int(physical(.sync)))
        return p
    }
}

/// Output fixture parameters (DESIGN.md §6.4) in render units.
public struct OutputParameters: Sendable, Equatable {
    public var intensity: Float = 1
    public var control: OutputControl = .normal
    public var testPattern: TestPattern = .off
    /// Blend switch "raw": bypass blend, warp and mask for alignment.
    public var raw = false
    public init() {}

    public static func from(_ resolver: FixtureResolver) -> OutputParameters {
        var p = OutputParameters()
        p.intensity = Float(resolver.physical(.output(.intensity)) / 100)
        p.control = OutputControl(rawValue: Int(resolver.physical(.output(.control)))) ?? .normal
        p.testPattern = TestPattern(rawValue: Int(resolver.physical(.output(.testPattern)))) ?? .off
        p.raw = BlendSwitch(rawValue: Int(resolver.physical(.output(.blend)))) == .raw
        return p
    }
}

extension simd_float3x3 {
    /// From a row-major 3×3 (`WarpMath.homography`, `WarpMath.keystone`).
    init(rowMajor m: [Double]) {
        let f = m.map(Float.init)
        self.init(rows: [SIMD3(f[0], f[1], f[2]), SIMD3(f[3], f[4], f[5]), SIMD3(f[6], f[7], f[8])])
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
    public static let maxOutputs = 8
    /// The layers the DMX store's snapshot holds: layers above it never render and have no fixture.
    public static let maxLayers = 32
    public var outputs: [OutputParameters] = Array(repeating: OutputParameters(), count: ParameterSnapshotSlot.maxOutputs)
    /// Per output, the Keystone fixture's homography (DESIGN.md §9.10 item 2, `WarpMath.keystone`) in normalized output
    /// coordinates: the identity while nothing sets it (no DMX, no internal value) or centred. Its own array, written by
    /// the Keystone fixture: the Output fixture rebuilds `outputs` on every publish.
    public var keystones: [simd_float3x3] = Array(repeating: matrix_identity_float3x3, count: ParameterSnapshotSlot.maxOutputs)
    /// The console's keystone values were refused (not a strictly convex quad): `keystones` keeps the last valid matrix.
    public var keystoneInvalid: [Bool] = Array(repeating: false, count: ParameterSnapshotSlot.maxOutputs)

    public init(maxLayers: Int) { layers = Array(repeating: LayerParameters(), count: maxLayers) }

    public static func from(_ resolver: FixtureResolver, into slot: ParameterSnapshotSlot) {
        slot.master = Float(resolver.physical(.master(.intensity)) / 100)
        slot.masterControl = MasterControl(rawValue: Int(resolver.physical(.master(.control)))) ?? .normal
        slot.masterSpeed = Float(resolver.physical(.master(.speed)) / 100)
        slot.testPattern = TestPattern(rawValue: Int(resolver.physical(.master(.testPattern)))) ?? .off
    }

    /// No Master fixture: the defaults above, as before any console.
    func resetMaster() { (master, masterControl, masterSpeed, testPattern) = (1, .normal, 1, .off) }

    func copy(from other: ParameterSnapshotSlot) {
        sequence = other.sequence
        receivedAt = other.receivedAt
        master = other.master
        masterControl = other.masterControl
        masterSpeed = other.masterSpeed
        testPattern = other.testPattern
        for i in layers.indices { layers[i] = other.layers[i] }
        for i in outputs.indices { outputs[i] = other.outputs[i] }
        for i in keystones.indices { (keystones[i], keystoneInvalid[i]) = (other.keystones[i], other.keystoneInvalid[i]) }
    }
}

/// Lock-free single-writer / single-reader triple buffer (DESIGN.md §2.2).
/// The writer and the reader each own one slot; the third is "published".
/// A single atomic exchange hands slots over, so neither side ever waits.
/// Readers on other threads use `withLatest` (B71), never `read()`.
public final class TripleBuffer<Slot: AnyObject>: @unchecked Sendable {
    private let slots: [Slot]
    private let published = Atomic<Int>(0)  // slot index | (hasNew << 8)
    private var writing = 1
    private var reading = 2
    /// B71: the writer copies each slot it publishes into `latest` (only with `copy`); `latest` is only touched
    /// under `latestLock`, which is the invariant behind `@unchecked Sendable` for it.
    private let copy: ((_ into: Slot, _ from: Slot) -> Void)?
    private let latest: Slot
    private let latestLock = Mutex(())

    public init(_ make: () -> Slot, copy: ((_ into: Slot, _ from: Slot) -> Void)? = nil) {
        slots = [make(), make(), make()]
        latest = make()
        self.copy = copy
    }

    /// Writer: fill the slot, then publish it.
    public func write(_ body: (Slot) -> Void) {
        body(slots[writing])
        if let copy { latestLock.withLock { _ in copy(latest, slots[writing]) } }
        let old = published.exchange(writing | 0x100, ordering: .acquiringAndReleasing)
        writing = old & 0xFF
    }

    /// Any thread but the reader's (CITP, secondary displays): `body` on the copy of the last published slot, under a
    /// lock the writer takes once per write (ADR-0002 amendment 2026-10-28). `body` only copies, into storage reserved
    /// before the call: no allocation under the lock, and the writer's copy stays unshared (no copy on write).
    /// Never on the compositor thread: no locks there.
    public func withLatest<R>(_ body: (Slot) -> R) -> R {
        precondition(copy != nil, "withLatest needs a copy: closure")
        return latestLock.withLock { _ in body(latest) }
    }

    /// Reader (the compositor thread only): the newest published slot (or the one read last time when nothing new arrived).
    public func read() -> Slot {
        let current = published.load(ordering: .acquiring)
        if current & 0x100 != 0 {
            let old = published.exchange(reading, ordering: .acquiringAndReleasing)
            reading = old & 0xFF
        }
        return slots[reading]
    }

    /// Reader, later in the same tick (preview tap): the slot the last `read()` returned, without taking a newer one,
    /// which would hand the tick's own slot back to the writer while the tick still reads it (B71).
    public func current() -> Slot { slots[reading] }
}
