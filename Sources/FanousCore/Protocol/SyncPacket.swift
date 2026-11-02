// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// The multi-server clock packet "FanousSync v1" (DESIGN.md §23.2, ADR-0021), little-endian.
public struct SyncPacket: Equatable, Sendable {
    public struct Layer: Equatable, Sendable {
        public var group: UInt8
        /// Source layer on the master (informational).
        public var layer: UInt8
        /// `MediaKey.packed` (folder << 8 | file).
        public var mediaKey: UInt16
        public var fps: Float
        /// Media frames.
        public var position: Double
        public var direction: Int8
        public var finished: Bool
        /// Media frames per second as the clock really advances; 0 when frozen, finished or paused.
        public var rate: Float

        public init(
            group: UInt8, layer: UInt8, mediaKey: UInt16, fps: Float, position: Double, direction: Int8, finished: Bool,
            rate: Float
        ) {
            self.group = group
            self.layer = layer
            self.mediaKey = mediaKey
            self.fps = fps
            self.position = position
            self.direction = direction
            self.finished = finished
            self.rate = rate
        }
    }

    public static let magic: [UInt8] = Array("FSYN".utf8)
    public static let version: UInt8 = 1
    /// magic, version, machine id, tick, sendTime, count.
    public static let headerSize = 4 + 1 + 16 + 4 + 8 + 1
    /// group, layer, mediaKey, fps, position, direction, finished, rate.
    public static let layerSize = 1 + 1 + 2 + 4 + 8 + 1 + 1 + 4
    /// The engine's layer cap (DESIGN.md §6.1).
    public static let maxLayers = 32
    public static let maxSize = headerSize + maxLayers * layerSize

    /// `badValue`: a layer field the slave clock cannot use (fps not finite and > 0, non-finite position or rate,
    /// group outside 1–8, direction outside −1…1).
    public enum ParseError: Error, Equatable { case tooShort, badMagic, badVersion, badLength, badValue }

    /// Install UUID of the sending machine.
    public var machineID: UUID
    public var tick: UInt32
    /// Sender's host time (informational).
    public var sendTime: Double
    public var layers: [Layer]

    public init(machineID: UUID, tick: UInt32, sendTime: Double, layers: [Layer]) {
        self.machineID = machineID
        self.tick = tick
        self.sendTime = sendTime
        self.layers = layers
    }

    /// Writes the packet into `buffer`, replacing its contents; no allocation once its capacity is `maxSize`.
    public func encode(into buffer: inout [UInt8]) {
        precondition(layers.count <= Self.maxLayers)
        buffer.removeAll(keepingCapacity: true)
        buffer.append(contentsOf: Self.magic)
        buffer.append(Self.version)
        withUnsafeBytes(of: machineID.uuid) { buffer.append(contentsOf: $0) }
        buffer.put(tick)
        buffer.put(sendTime.bitPattern)
        buffer.append(UInt8(layers.count))
        for layer in layers {
            buffer.append(layer.group)
            buffer.append(layer.layer)
            buffer.put(layer.mediaKey)
            buffer.put(layer.fps.bitPattern)
            buffer.put(layer.position.bitPattern)
            buffer.append(UInt8(bitPattern: layer.direction))
            buffer.append(layer.finished ? 1 : 0)
            buffer.put(layer.rate.bitPattern)
        }
    }

    public static func decode(_ bytes: [UInt8]) throws -> SyncPacket {
        guard bytes.count >= headerSize else { throw ParseError.tooShort }
        guard Array(bytes[0..<4]) == magic else { throw ParseError.badMagic }
        guard bytes[4] == version else { throw ParseError.badVersion }
        let count = Int(bytes[headerSize - 1])
        // Trailing bytes are ignored (as in `ArtNet.parse`); incompatible changes bump `version`.
        guard count <= maxLayers, bytes.count >= headerSize + count * layerSize else { throw ParseError.badLength }
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &uuid) { $0.copyBytes(from: bytes[5..<21]) }
        var layers: [Layer] = []
        layers.reserveCapacity(count)
        for i in 0..<count {
            let o = headerSize + i * layerSize
            let l = Layer(
                group: bytes[o], layer: bytes[o + 1], mediaKey: read(bytes, o + 2),
                fps: Float(bitPattern: read(bytes, o + 4)),
                position: Double(bitPattern: read(bytes, o + 8)), direction: Int8(bitPattern: bytes[o + 16]),
                finished: bytes[o + 17] != 0, rate: Float(bitPattern: read(bytes, o + 18)))
            guard l.fps.isFinite, l.fps > 0, l.position.isFinite, l.rate.isFinite,
                (1...LayerSync.groups).contains(Int(l.group)), (-1...1).contains(l.direction)
            else { throw ParseError.badValue }
            layers.append(l)
        }
        return SyncPacket(
            machineID: UUID(uuid: uuid), tick: read(bytes, 21), sendTime: Double(bitPattern: read(bytes, 25)),
            layers: layers)
    }

    static func read<T: FixedWidthInteger>(_ bytes: [UInt8], _ offset: Int) -> T {
        (0..<MemoryLayout<T>.size).reduce(T.zero) { $0 | T(bytes[offset + $1]) << ($1 * 8) }
    }
}
