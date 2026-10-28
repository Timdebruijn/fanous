// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

// CITP (Controller Interface Transport Protocol): base layer + PINF. Pure bytes <-> values, no I/O.
// Layouts follow the CITP specification (Specification.md in bitbucket.org/lars_wernlund/citp, rev. 2026-06-15).
// Everything is little endian. `ucs1`/`ucs2` open arrays are NUL terminated. See CITPMSEX.swift for MSEX.

/// PINF peer discovery: `PLoc` datagrams go to this multicast group.
public enum CITPMulticast {
    /// Original group (DESIGN.md §16.1 uses it).
    public static let address = "224.0.0.180"
    /// Group since early 2014; the spec recommends listening on both during the transition.
    public static let addressSince2014 = "239.224.0.180"
    public static let port: UInt16 = 4809
}

public enum CITPError: Error, Equatable, Sendable {
    /// Fewer bytes than the header (or a field inside the message) needs.
    case truncated
    /// First four bytes are not "CITP", or the CITP major version is not 1.
    case badHeader
    /// MessageSize is smaller than the header itself.
    case badSize
    /// MessagePartCount > 1: reassemble CITP fragments before parsing.
    case fragmented
    /// MSEX major version other than 1.
    case unsupportedVersion
}

/// The 20-byte CITP base header. Version is always 1.0.
public struct CITPHeader: Equatable, Sendable {
    public static let size = 20
    public static let cookie = "CITP"

    /// RequestIndex when sending a request, InResponseTo when replying (same 16 bits). 0 = ignored.
    public var requestIndex: UInt16
    public var messagePartCount: UInt16
    public var messagePart: UInt16
    /// Size of the entire message including this header.
    public var messageSize: UInt32
    /// Four-character second-layer name: "PINF", "MSEX", "SDMX", ...
    public var contentType: String

    public init(requestIndex: UInt16 = 0, messagePartCount: UInt16 = 1, messagePart: UInt16 = 0, messageSize: UInt32, contentType: String) {
        self.requestIndex = requestIndex
        self.messagePartCount = messagePartCount
        self.messagePart = messagePart
        self.messageSize = messageSize
        self.contentType = contentType
    }

    public func encode() -> [UInt8] {
        var out: [UInt8] = []
        out.putCookie(Self.cookie)
        out += [1, 0]
        out.put(requestIndex)
        out.put(messageSize)
        out.put(messagePartCount)
        out.put(messagePart)
        out.putCookie(contentType)
        return out
    }

    public static func parse(_ bytes: [UInt8]) throws -> CITPHeader {
        var r = CITPReader(bytes)
        guard try r.cookie() == Self.cookie, try r.u8() == 1 else { throw CITPError.badHeader }
        _ = try r.u8()  // minor: spec says 0, ignored
        let requestIndex = try r.u16()
        let size = try r.u32()
        let count = try r.u16()
        let part = try r.u16()
        return CITPHeader(requestIndex: requestIndex, messagePartCount: count, messagePart: part, messageSize: size, contentType: try r.cookie())
    }
}

/// PINF/PLoc: where a peer listens for TCP, plus what it is.
public struct PeerLocation: Equatable, Sendable {
    /// 0 when the peer is not listening.
    public var listeningTCPPort: UInt16
    /// "LightingConsole", "MediaServer" or "Visualizer".
    public var type: String
    public var name: String
    /// Free-form display state ("Idle", "Running", ...).
    public var state: String

    public init(listeningTCPPort: UInt16, type: String, name: String, state: String) {
        self.listeningTCPPort = listeningTCPPort
        self.type = type
        self.name = name
        self.state = state
    }
}

/// One CITP message. `parse` and `encoded` are inverse for every case, including `.unknown`.
public enum CITPPacket: Equatable, Sendable {
    // PINF
    case peerName(String)
    case peerLocation(PeerLocation)
    // MSEX
    case clientInformation(ClientInformation)
    case serverInformation(ServerInformation)
    case nack(Nack)
    case layerStatus([LayerStatus])
    case getElementLibraryInformation(GetElementLibraryInformation)
    case elementLibraryInformation(ElementLibraryInformation)
    case getElementInformation(GetElementInformation)
    case mediaElementInformation(MediaElementInformation)
    case getElementThumbnail(GetElementThumbnail)
    case elementThumbnail(ElementThumbnail)
    case getVideoSources
    case videoSources([VideoSource])
    case requestStream(RequestStream)
    case streamFrame(StreamFrame)
    /// Any layer or message this codec does not model (SDMX, FPTC, MSEX EEIn/GLEI/ELUp/..., unknown PINF).
    /// `body` is everything after the 20-byte CITP header, so it re-encodes byte for byte; for MSEX messages
    /// it starts with the MSEX version bytes and the 4-byte message cookie, and `contentType` is "MSEX".
    case unknown(contentType: String, body: [UInt8])

    public static func parse(_ bytes: [UInt8]) throws -> CITPPacket {
        let header = try CITPHeader.parse(bytes)
        let size = Int(header.messageSize)
        guard size >= CITPHeader.size else { throw CITPError.badSize }
        guard bytes.count >= size else { throw CITPError.truncated }
        guard header.messagePartCount <= 1 else { throw CITPError.fragmented }
        let body = Array(bytes[CITPHeader.size..<size])
        var r = CITPReader(body)
        switch header.contentType {
        case "PINF":
            switch try r.cookie() {
            case "PNam": return .peerName(try r.ucs1())
            case "PLoc":
                return .peerLocation(PeerLocation(listeningTCPPort: try r.u16(), type: try r.ucs1(), name: try r.ucs1(), state: try r.ucs1()))
            default: return .unknown(contentType: "PINF", body: body)
            }
        case "MSEX":
            return try parseMSEX(&r, body: body)
        default:
            return .unknown(contentType: header.contentType, body: body)
        }
    }

    /// Wire bytes. `version` is the MSEX version to write (ignored for PINF and `.unknown`);
    /// `requestIndex` goes into the CITP header (use the request's index when answering).
    /// Lists and buffers longer than their wire count field allows are truncated to fit.
    public func encoded(version: MSEXVersion = .v1_2, requestIndex: UInt16 = 0) -> [UInt8] {
        var layer = "MSEX"
        var body: [UInt8] = []
        switch self {
        case .peerName(let name):
            layer = "PINF"
            body.putCookie("PNam")
            body.putUCS1(name)
        case .peerLocation(let p):
            layer = "PINF"
            body.putCookie("PLoc")
            body.put(p.listeningTCPPort)
            body.putUCS1(p.type)
            body.putUCS1(p.name)
            body.putUCS1(p.state)
        case .unknown(let contentType, let raw):
            layer = contentType
            body = raw
        // CInf and Nack only exist from 1.2; the others use the layout of `version`.
        case .clientInformation(let m): body = Self.msex("CInf", max(version, .v1_2), m.write)
        case .serverInformation(let m): body = Self.msex("SInf", version, m.write)
        case .nack(let m): body = Self.msex("Nack", max(version, .v1_2), m.write)
        case .layerStatus(let layers): body = Self.msex("LSta", version) { LayerStatus.write(layers, to: &$0, as: $1) }
        case .getElementLibraryInformation(let m): body = Self.msex("GELI", version, m.write)
        case .elementLibraryInformation(let m): body = Self.msex("ELIn", version, m.write)
        case .getElementInformation(let m): body = Self.msex("GEIn", version, m.write)
        case .mediaElementInformation(let m): body = Self.msex("MEIn", version, m.write)
        case .getElementThumbnail(let m): body = Self.msex("GETh", version, m.write)
        case .elementThumbnail(let m): body = Self.msex("EThn", version, m.write)
        case .getVideoSources: body = Self.msex("GVSr", version) { _, _ in }
        case .videoSources(let sources): body = Self.msex("VSrc", version) { out, _ in VideoSource.write(sources, to: &out) }
        case .requestStream(let m): body = Self.msex("RqSt", version, m.write)
        case .streamFrame(let m): body = Self.msex("StFr", version, m.write)
        }
        let header = CITPHeader(requestIndex: requestIndex, messageSize: UInt32(truncatingIfNeeded: CITPHeader.size + body.count), contentType: layer)
        return header.encode() + body
    }
}

// MARK: - Byte helpers (internal: shared with CITPMSEX.swift)

struct CITPReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard remaining >= n else { throw CITPError.truncated }
        defer { offset += n }
        return bytes[offset..<offset + n]
    }

    private mutating func uint(_ n: Int) throws -> UInt64 {
        try take(n).reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func u8() throws -> UInt8 { try UInt8(uint(1)) }
    mutating func u16() throws -> UInt16 { try UInt16(uint(2)) }
    mutating func u32() throws -> UInt32 { try UInt32(uint(4)) }
    mutating func u64() throws -> UInt64 { try uint(8) }

    /// 4-byte content-type cookie, bytes mapped 1:1 to characters so any value round-trips.
    mutating func cookie() throws -> String {
        try String(String.UnicodeScalarView(take(4).map { Unicode.Scalar($0) }))
    }

    /// NUL-terminated 8-bit string (ucs1), decoded as UTF-8.
    mutating func ucs1() throws -> String {
        guard let end = bytes[offset...].firstIndex(of: 0) else { throw CITPError.truncated }
        defer { offset = end + 1 }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }

    /// NUL-terminated little-endian 16-bit string (ucs2; surrogate pairs decode as UTF-16).
    mutating func ucs2() throws -> String {
        var units: [UInt16] = []
        var unit = try u16()
        while unit != 0 {
            units.append(unit)
            unit = try u16()
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Fixed-width ucs1 field (the 36-character UUID); trailing NULs are dropped.
    mutating func fixedString(_ n: Int) throws -> String {
        try String(decoding: take(n).prefix { $0 != 0 }, as: UTF8.self)
    }
}

extension Array where Element == UInt8 {
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        for i in 0..<T.bitWidth / 8 { append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
    }

    /// Exactly four bytes: characters map 1:1 (Latin-1); shorter input is padded with spaces.
    mutating func putCookie(_ text: String) {
        let bytes = text.unicodeScalars.prefix(4).map { UInt8(truncatingIfNeeded: $0.value) }
        append(contentsOf: bytes + repeatElement(0x20, count: 4 - bytes.count))
    }

    mutating func putUCS1(_ text: String) {
        append(contentsOf: text.utf8.filter { $0 != 0 })
        append(0)
    }

    mutating func putUCS2(_ text: String) {
        for unit in text.utf16 where unit != 0 { put(unit) }
        put(UInt16(0))
    }

    mutating func putFixedString(_ text: String, _ n: Int) {
        let bytes = Array(text.utf8.prefix(n))
        append(contentsOf: bytes + repeatElement(0, count: n - bytes.count))
    }
}
