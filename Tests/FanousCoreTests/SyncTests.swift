// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousCore

@Suite struct SyncChannelTests {
    @Test func everyRawValueMapsToItsRoleAndGroup() {
        let spec = ChannelMap.spec(.layer(.sync))
        for raw in 0...255 {
            let expected: LayerSync =
                switch raw {
                case 10...89: .master(group: (raw - 10) / 10 + 1)
                case 90...169: .slave(group: (raw - 90) / 10 + 1)
                default: .off
                }
            #expect(LayerSync(bandValue: Int(spec.physical(fromRaw: UInt16(raw)))) == expected, "raw \(raw)")
        }
        #expect(spec.label(forRaw: 10) == "Master 1" && spec.label(forRaw: 89) == "Master 8")
        #expect(spec.label(forRaw: 90) == "Slave 1" && spec.label(forRaw: 169) == "Slave 8")
        #expect(spec.label(forRaw: 200) == "Off")
    }

    @Test func channel51IsSyncOfSixtyFour() {
        let spec = ChannelMap.spec(.layer(.sync))
        #expect(spec.channel == 51 && spec.name == "Sync" && spec.bits == 8 && spec.defaultRaw == 0)
        #expect(FixtureMode.layer.footprint == 64)
        #expect(ChannelMap.reservedLayerChannels == 52...64)
    }

    @Test func documentAndGDTFCarrySync() {
        #expect(ChannelMapDocument.markdown().contains("| 51 | Sync | 8 | 0 | 0–9 Off · 10–19 Master 1"))
        let xml = GDTFExporter.descriptionXML(version: "test")
        #expect(xml.contains("Offset=\"51\" InitialFunction=\"Base_VideoSync.VideoSync.Sync\""))
        #expect(xml.contains("<ChannelSet Name=\"Slave 8\" DMXFrom=\"160/1\""))
        #expect(ChannelMapDocument.markdown().contains("160–169 Slave 8 · 170–255 Off · rest = Off"))
        var sets: [String] = []
        var inSync = false
        for element in GDTFTests.parsed().elements {
            if element.name == "DMXChannel" {
                inSync = element.attributes["InitialFunction"]?.contains("VideoSync") == true
            }
            if inSync && element.name == "ChannelSet" { sets.append(element.attributes["DMXFrom"]!) }
        }
        #expect(sets.count == 18)  // Off, Master 1–8, Slave 1–8, Off: "Slave 8" ends at 169
        #expect(sets.last == "170/1")
    }
}

@Suite struct SyncPacketTests {
    static let machine = UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!

    static func layer(_ i: Int) -> SyncPacket.Layer {
        SyncPacket.Layer(
            group: UInt8(i % 8 + 1), layer: UInt8(i), mediaKey: UInt16(i) << 8 | 0xFE, fps: 25 + Float(i) / 3,
            position: 1234.5678 + Double(i), direction: i % 2 == 0 ? 1 : -1, finished: i % 3 == 0,
            rate: -24.97 * Float(i))
    }

    @Test(arguments: [0, 1, 32]) func roundTrips(count: Int) throws {
        let packet = SyncPacket(
            machineID: Self.machine, tick: 0xDEAD_BEEF, sendTime: 98765.4321, layers: (0..<count).map(Self.layer))
        var buffer: [UInt8] = []
        buffer.reserveCapacity(SyncPacket.maxSize)
        packet.encode(into: &buffer)
        #expect(buffer.count == SyncPacket.headerSize + count * SyncPacket.layerSize)
        #expect(try SyncPacket.decode(buffer) == packet)
        packet.encode(into: &buffer)  // reuse replaces, never appends
        #expect(buffer.count == SyncPacket.headerSize + count * SyncPacket.layerSize)
    }

    @Test func secondEncodeDoesNotAllocate() {
        let packet = SyncPacket(machineID: Self.machine, tick: 7, sendTime: 1, layers: (0..<32).map(Self.layer))
        var buffer: [UInt8] = []
        buffer.reserveCapacity(SyncPacket.maxSize)
        packet.encode(into: &buffer)
        let capacity = buffer.capacity
        let base = buffer.withUnsafeBufferPointer { $0.baseAddress }
        packet.encode(into: &buffer)
        #expect(buffer.count == SyncPacket.maxSize)
        #expect(buffer.capacity == capacity)
        #expect(buffer.withUnsafeBufferPointer { $0.baseAddress } == base)
    }

    @Test func sizesFollowTheLayout() {
        #expect(SyncPacket.headerSize == 34 && SyncPacket.layerSize == 22)
        #expect(SyncPacket.maxSize == 34 + 32 * 22)
    }

    @Test func layoutIsLittleEndian() {
        var buffer: [UInt8] = []
        SyncPacket(machineID: Self.machine, tick: 0x0102_0304, sendTime: 0, layers: [Self.layer(1)]).encode(
            into: &buffer)
        #expect(Array(buffer[0..<5]) == Array("FSYN".utf8) + [1])
        #expect(Array(buffer[5..<7]) == [0x0F, 0x1E])
        #expect(Array(buffer[21..<25]) == [4, 3, 2, 1])
        var timed: [UInt8] = []
        SyncPacket(machineID: Self.machine, tick: 0, sendTime: Double(bitPattern: 0x0102_0304_0506_0708), layers: [])
            .encode(into: &timed)
        #expect(Array(timed[25..<33]) == [8, 7, 6, 5, 4, 3, 2, 1])
        #expect(buffer[33] == 1)
        #expect(Array(buffer[34..<38]) == [2, 1, 0xFE, 1])  // group, layer, mediaKey 0x01FE
    }

    @Test func rejectsGarbage() {
        var buffer: [UInt8] = []
        SyncPacket(machineID: Self.machine, tick: 1, sendTime: 2, layers: [Self.layer(0), Self.layer(1)]).encode(
            into: &buffer)
        #expect(throws: SyncPacket.ParseError.tooShort) { try SyncPacket.decode([]) }
        #expect(throws: SyncPacket.ParseError.tooShort) {
            try SyncPacket.decode(Array(buffer.prefix(SyncPacket.headerSize - 1)))
        }
        #expect(throws: SyncPacket.ParseError.badLength) { try SyncPacket.decode(Array(buffer.dropLast())) }
        var bad = buffer
        bad[0] = UInt8(ascii: "X")
        #expect(throws: SyncPacket.ParseError.badMagic) { try SyncPacket.decode(bad) }
        bad = buffer
        bad[4] = 2
        #expect(throws: SyncPacket.ParseError.badVersion) { try SyncPacket.decode(bad) }
        bad = buffer
        bad[SyncPacket.headerSize - 1] = 3  // count larger than the payload
        #expect(throws: SyncPacket.ParseError.badLength) { try SyncPacket.decode(bad) }
        bad[SyncPacket.headerSize - 1] = 255
        #expect(throws: SyncPacket.ParseError.badLength) { try SyncPacket.decode(bad) }
        for length in 0..<buffer.count { _ = try? SyncPacket.decode(Array(buffer.prefix(length))) }
    }

    @Test func acceptsAndIgnoresATrailer() throws {
        var buffer: [UInt8] = []
        SyncPacket(machineID: Self.machine, tick: 1, sendTime: 2, layers: [Self.layer(3)]).encode(into: &buffer)
        #expect(try SyncPacket.decode(buffer + [0xAA]) == SyncPacket.decode(buffer))
    }

    @Test func rejectsMoreThanMaxLayers() {
        var buffer: [UInt8] = []
        SyncPacket(machineID: Self.machine, tick: 1, sendTime: 2, layers: (0..<32).map(Self.layer)).encode(
            into: &buffer)
        buffer[SyncPacket.headerSize - 1] = UInt8(SyncPacket.maxLayers + 1)
        buffer += buffer[SyncPacket.headerSize..<SyncPacket.headerSize + SyncPacket.layerSize]  // payload fits 33
        #expect(throws: SyncPacket.ParseError.badLength) { try SyncPacket.decode(buffer) }
    }

    static let badLayers: [(String, @Sendable (inout SyncPacket.Layer) -> Void)] = [
        ("fps NaN", { $0.fps = .nan }), ("fps infinite", { $0.fps = .infinity }), ("fps 0", { $0.fps = 0 }),
        ("fps negative", { $0.fps = -25 }), ("position NaN", { $0.position = .nan }),
        ("position infinite", { $0.position = -.infinity }), ("rate NaN", { $0.rate = .nan }),
        ("rate infinite", { $0.rate = .infinity }), ("group 0", { $0.group = 0 }), ("group 9", { $0.group = 9 }),
        ("direction 2", { $0.direction = 2 }), ("direction -2", { $0.direction = -2 }),
    ]

    @Test(arguments: badLayers.map(\.0)) func rejectsUnusableValues(_ name: String) {
        var layer = Self.layer(2)
        Self.badLayers.first { $0.0 == name }!.1(&layer)
        var buffer: [UInt8] = []
        SyncPacket(machineID: Self.machine, tick: 1, sendTime: 2, layers: [Self.layer(1), layer]).encode(into: &buffer)
        #expect(throws: SyncPacket.ParseError.badValue) { try SyncPacket.decode(buffer) }
    }

    @Test func reencodingAnythingDecodedNeverTraps() {
        var buffer: [UInt8] = []
        SyncPacket(machineID: Self.machine, tick: 1, sendTime: 2, layers: (0..<3).map(Self.layer)).encode(into: &buffer)
        var out: [UInt8] = []
        for i in buffer.indices {
            for value: UInt8 in [0, 1, 0x7F, 0x80, 0xFF] {
                var mutated = buffer
                mutated[i] = value
                if let packet = try? SyncPacket.decode(mutated) { packet.encode(into: &out) }
            }
        }
    }
}
