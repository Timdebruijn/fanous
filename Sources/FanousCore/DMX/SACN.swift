// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// Streaming ACN, ANSI E1.31-2025: data, synchronization and discovery packets.
public enum SACN {
    public static let port: UInt16 = 5568
    public static let maxUniverse = 63999
    static let acnIdentifier: [UInt8] = Array("ASC-E1.17\0\0\0".utf8)
    static let rootVectorData: UInt32 = 0x0000_0004
    static let rootVectorExtended: UInt32 = 0x0000_0008
    static let framingVectorData: UInt32 = 0x0000_0002
    static let framingVectorSync: UInt32 = 0x0000_0001
    static let framingVectorDiscovery: UInt32 = 0x0000_0002
    static let discoveryVectorUniverseList: UInt32 = 0x0000_0001

    public static func multicastAddress(universe: Int) -> String { "239.255.\(universe >> 8 & 0xFF).\(universe & 0xFF)" }

    public enum Packet: Equatable, Sendable {
        case data(SACNData)
        case sync(SACNSync)
        case discovery(SACNDiscovery)
    }

    public enum ParseError: Error, Equatable {
        case tooShort, badPreamble, badIdentifier, badVector, badLength, badAddressType
    }

    public static func parse(_ b: [UInt8]) throws -> Packet {
        guard b.count >= 48 else { throw ParseError.tooShort }
        guard b[0] == 0, b[1] == 0x10, b[2] == 0, b[3] == 0 else { throw ParseError.badPreamble }
        guard Array(b[4..<16]) == acnIdentifier else { throw ParseError.badIdentifier }
        let rootLength = try pduLength(b, at: 16)
        guard 16 + rootLength <= b.count else { throw ParseError.badLength }
        let end = 16 + rootLength
        let cid = Array(b[22..<38])
        switch be32(b, 18) {
        case rootVectorData:
            guard end >= 126, be32(b, 40) == framingVectorData else { throw ParseError.badVector }
            _ = try pduLength(b, at: 38)
            _ = try pduLength(b, at: 115)
            guard b[117] == 0x02 else { throw ParseError.badVector }
            guard b[118] == 0xA1, be16(b, 119) == 0, be16(b, 121) == 1 else { throw ParseError.badAddressType }
            let count = Int(be16(b, 123))
            guard count >= 1, count <= 513, 125 + count <= end else { throw ParseError.badLength }
            return .data(
                SACNData(
                    cid: cid, sourceName: cString(b, 44, 64), priority: b[108], syncAddress: be16(b, 109), sequence: b[111],
                    options: b[112], universe: be16(b, 113), startCode: b[125], slots: Array(b[126..<125 + count])))
        case rootVectorExtended:
            switch be32(b, 40) {
            case framingVectorSync:
                guard end >= 49 else { throw ParseError.tooShort }
                return .sync(SACNSync(cid: cid, sequence: b[44], syncAddress: be16(b, 45)))
            case framingVectorDiscovery:
                guard end >= 120 else { throw ParseError.tooShort }
                let discoveryLength = try pduLength(b, at: 112)
                guard be32(b, 114) == discoveryVectorUniverseList else { throw ParseError.badVector }
                let listEnd = min(end, 112 + discoveryLength)
                var universes: [UInt16] = []
                var i = 120
                while i + 1 < listEnd {
                    universes.append(be16(b, i))
                    i += 2
                }
                return .discovery(
                    SACNDiscovery(cid: cid, sourceName: cString(b, 44, 64), page: b[118], lastPage: b[119], universes: universes))
            default:
                throw ParseError.badVector
            }
        default:
            throw ParseError.badVector
        }
    }

    static func pduLength(_ b: [UInt8], at i: Int) throws -> Int {
        guard i + 1 < b.count, b[i] >> 4 == 0x7 else { throw ParseError.badLength }
        return Int(b[i] & 0x0F) << 8 | Int(b[i + 1])
    }

    static func flagsLength(_ length: Int) -> [UInt8] { [0x70 | UInt8(length >> 8 & 0x0F), UInt8(length & 0xFF)] }
    static func be16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
    static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    static func cString(_ b: [UInt8], _ start: Int, _ length: Int) -> String {
        let field = b[start..<start + length]
        let end = field.firstIndex(of: 0) ?? field.endIndex
        return String(decoding: field[field.startIndex..<end], as: UTF8.self)
    }
    static func root(cid: [UInt8], vector: UInt32, bodyLength: Int) -> [UInt8] {
        [0, 0x10, 0, 0] + acnIdentifier + flagsLength(22 + bodyLength) + vector.bigEndianBytes + cid
    }
}

public struct SACNData: Equatable, Sendable {
    public var cid: [UInt8]
    public var sourceName: String
    public var priority: UInt8
    public var syncAddress: UInt16
    public var sequence: UInt8
    public var options: UInt8
    public var universe: UInt16
    public var startCode: UInt8
    public var slots: [UInt8]

    public init(
        cid: [UInt8], sourceName: String, priority: UInt8 = 100, syncAddress: UInt16 = 0, sequence: UInt8 = 0,
        options: UInt8 = 0, universe: UInt16, startCode: UInt8 = 0, slots: [UInt8]
    ) {
        precondition(cid.count == 16)
        self.cid = cid
        self.sourceName = sourceName
        self.priority = priority
        self.syncAddress = syncAddress
        self.sequence = sequence
        self.options = options
        self.universe = universe
        self.startCode = startCode
        self.slots = Array(slots.prefix(512))
    }

    public var isPreview: Bool { options & 0x80 != 0 }
    public var isTerminated: Bool { options & 0x40 != 0 }
    public var universeID: UniverseID { UniverseID(.sacn, Int(universe)) }

    public func encoded() -> [UInt8] {
        let dmp = SACN.flagsLength(10 + 1 + slots.count) + [0x02, 0xA1, 0, 0, 0, 1] + UInt16(1 + slots.count).bigEndianBytes + [startCode] + slots
        let framing = SACN.flagsLength(77 + dmp.count) + SACN.framingVectorData.bigEndianBytes + [UInt8].fixed(sourceName, 64)
            + [priority] + syncAddress.bigEndianBytes + [sequence, options] + universe.bigEndianBytes
        return SACN.root(cid: cid, vector: SACN.rootVectorData, bodyLength: framing.count + dmp.count) + framing + dmp
    }
}

public struct SACNSync: Equatable, Sendable {
    public var cid: [UInt8]
    public var sequence: UInt8
    public var syncAddress: UInt16

    public init(cid: [UInt8], sequence: UInt8, syncAddress: UInt16) {
        self.cid = cid
        self.sequence = sequence
        self.syncAddress = syncAddress
    }

    public func encoded() -> [UInt8] {
        let framing = SACN.flagsLength(11) + SACN.framingVectorSync.bigEndianBytes + [sequence] + syncAddress.bigEndianBytes + [0, 0]
        return SACN.root(cid: cid, vector: SACN.rootVectorExtended, bodyLength: framing.count) + framing
    }
}

public struct SACNDiscovery: Equatable, Sendable {
    public var cid: [UInt8]
    public var sourceName: String
    public var page: UInt8
    public var lastPage: UInt8
    public var universes: [UInt16]

    public init(cid: [UInt8], sourceName: String, page: UInt8, lastPage: UInt8, universes: [UInt16]) {
        self.cid = cid
        self.sourceName = sourceName
        self.page = page
        self.lastPage = lastPage
        self.universes = universes
    }

    public func encoded() -> [UInt8] {
        let list = universes.flatMap(\.bigEndianBytes)
        let discovery = SACN.flagsLength(8 + list.count) + SACN.discoveryVectorUniverseList.bigEndianBytes + [page, lastPage] + list
        let framing = SACN.flagsLength(74 + discovery.count) + SACN.framingVectorDiscovery.bigEndianBytes + [UInt8].fixed(sourceName, 64) + [0, 0, 0, 0]
        return SACN.root(cid: cid, vector: SACN.rootVectorExtended, bodyLength: framing.count + discovery.count) + framing + discovery
    }
}
