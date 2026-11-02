// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// OSC 1.0 messages and bundles (plus the 1.1 SLIP framing for TCP).
public enum OSCArgument: Equatable, Sendable {
    case int32(Int32)
    case float32(Float)
    case string(String)
    case blob([UInt8])
    case int64(Int64)
    case double(Double)
    case timetag(UInt64)
    case bool(Bool)
    case null
    case impulse

    public var typeTag: Character {
        switch self {
        case .int32: "i"
        case .float32: "f"
        case .string: "s"
        case .blob: "b"
        case .int64: "h"
        case .double: "d"
        case .timetag: "t"
        case .bool(let value): value ? "T" : "F"
        case .null: "N"
        case .impulse: "I"
        }
    }

    public var asDouble: Double? {
        switch self {
        case .int32(let v): Double(v)
        case .float32(let v): Double(v)
        case .int64(let v): Double(v)
        case .double(let v): v
        case .bool(let v): v ? 1 : 0
        default: nil
        }
    }

    public var asBool: Bool? {
        switch self {
        case .bool(let v): v
        case .int32(let v): v != 0
        case .float32(let v): v != 0
        case .impulse: true
        default: nil
        }
    }
}

public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var arguments: [OSCArgument]

    public init(_ address: String, _ arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }

    public func encoded() -> [UInt8] {
        var out = OSCPacket.paddedString(address)
        out += OSCPacket.paddedString("," + String(arguments.map(\.typeTag)))
        for argument in arguments {
            switch argument {
            case .int32(let v): out += v.bigEndianBytes
            case .float32(let v): out += v.bitPattern.bigEndianBytes
            case .string(let s): out += OSCPacket.paddedString(s)
            case .blob(let b):
                out += UInt32(b.count).bigEndianBytes + b
                out += [UInt8](repeating: 0, count: (4 - b.count % 4) % 4)
            case .int64(let v): out += v.bigEndianBytes
            case .double(let v): out += v.bitPattern.bigEndianBytes
            case .timetag(let v): out += v.bigEndianBytes
            case .bool, .null, .impulse: break
            }
        }
        return out
    }
}

public struct OSCBundle: Equatable, Sendable {
    public var timetag: UInt64
    public var elements: [OSCPacket]

    public init(timetag: UInt64 = OSCPacket.immediately, elements: [OSCPacket]) {
        self.timetag = timetag
        self.elements = elements
    }

    public func encoded() -> [UInt8] {
        var out = OSCPacket.paddedString("#bundle") + timetag.bigEndianBytes
        for element in elements {
            let bytes = element.encoded()
            out += UInt32(bytes.count).bigEndianBytes + bytes
        }
        return out
    }
}

public enum OSCParseError: Error, Equatable {
    case truncated, badAddress, badTypeTags, unsupportedType(Character), badBundle
}

public indirect enum OSCPacket: Equatable, Sendable {
    case message(OSCMessage)
    case bundle(OSCBundle)

    public static let immediately: UInt64 = 1

    public func encoded() -> [UInt8] {
        switch self {
        case .message(let m): m.encoded()
        case .bundle(let b): b.encoded()
        }
    }

    public static func parse(_ bytes: [UInt8]) throws -> OSCPacket {
        var cursor = 0
        return try parse(bytes, &cursor, end: bytes.count)
    }

    static func parse(_ b: [UInt8], _ cursor: inout Int, end: Int) throws -> OSCPacket {
        guard cursor < end else { throw OSCParseError.truncated }
        if b[cursor] == UInt8(ascii: "#") {
            let tag = try readString(b, &cursor, end: end)
            guard tag == "#bundle" else { throw OSCParseError.badBundle }
            let timetag = try read64(b, &cursor, end: end)
            var elements: [OSCPacket] = []
            while cursor < end {
                let size = Int(try read32(b, &cursor, end: end))
                guard size >= 0, cursor + size <= end else { throw OSCParseError.truncated }
                var inner = cursor
                elements.append(try parse(b, &inner, end: cursor + size))
                cursor += size
            }
            return .bundle(OSCBundle(timetag: timetag, elements: elements))
        }
        let address = try readString(b, &cursor, end: end)
        guard address.hasPrefix("/") else { throw OSCParseError.badAddress }
        guard cursor < end else { return .message(OSCMessage(address)) }  // OSC 1.0 allows missing type tags
        let tags = try readString(b, &cursor, end: end)
        guard tags.hasPrefix(",") else { throw OSCParseError.badTypeTags }
        var arguments: [OSCArgument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i": arguments.append(.int32(Int32(bitPattern: try read32(b, &cursor, end: end))))
            case "f": arguments.append(.float32(Float(bitPattern: try read32(b, &cursor, end: end))))
            case "s", "S": arguments.append(.string(try readString(b, &cursor, end: end)))
            case "b":
                let size = Int(try read32(b, &cursor, end: end))
                guard size >= 0, cursor + size <= end else { throw OSCParseError.truncated }
                arguments.append(.blob(Array(b[cursor..<cursor + size])))
                cursor += size + (4 - size % 4) % 4
            case "h": arguments.append(.int64(Int64(bitPattern: try read64(b, &cursor, end: end))))
            case "d": arguments.append(.double(Double(bitPattern: try read64(b, &cursor, end: end))))
            case "t": arguments.append(.timetag(try read64(b, &cursor, end: end)))
            case "T": arguments.append(.bool(true))
            case "F": arguments.append(.bool(false))
            case "N": arguments.append(.null)
            case "I": arguments.append(.impulse)
            default: throw OSCParseError.unsupportedType(tag)
            }
        }
        return .message(OSCMessage(address, arguments))
    }

    static func readString(_ b: [UInt8], _ cursor: inout Int, end: Int) throws -> String {
        guard let terminator = b[cursor..<end].firstIndex(of: 0) else { throw OSCParseError.truncated }
        let text = String(decoding: b[cursor..<terminator], as: UTF8.self)
        cursor = terminator + 1
        cursor += (4 - cursor % 4) % 4
        guard cursor <= end else { throw OSCParseError.truncated }
        return text
    }

    static func read32(_ b: [UInt8], _ cursor: inout Int, end: Int) throws -> UInt32 {
        guard cursor + 4 <= end else { throw OSCParseError.truncated }
        defer { cursor += 4 }
        return UInt32(b[cursor]) << 24 | UInt32(b[cursor + 1]) << 16 | UInt32(b[cursor + 2]) << 8 | UInt32(b[cursor + 3])
    }

    static func read64(_ b: [UInt8], _ cursor: inout Int, end: Int) throws -> UInt64 {
        let high = try read32(b, &cursor, end: end)
        let low = try read32(b, &cursor, end: end)
        return UInt64(high) << 32 | UInt64(low)
    }

    static func paddedString(_ s: String) -> [UInt8] {
        var bytes = Array(s.utf8) + [0]
        bytes += [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4)
        return bytes
    }
}

/// RFC 1055 SLIP framing as used by OSC 1.1 over TCP.
public struct SLIPDecoder: Sendable {
    static let end: UInt8 = 0xC0, esc: UInt8 = 0xDB, escEnd: UInt8 = 0xDC, escEsc: UInt8 = 0xDD
    private var buffer: [UInt8] = []
    private var escaping = false

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
        var packets: [[UInt8]] = []
        for byte in bytes {
            if escaping {
                buffer.append(byte == Self.escEnd ? Self.end : byte == Self.escEsc ? Self.esc : byte)
                escaping = false
            } else if byte == Self.end {
                if !buffer.isEmpty {
                    packets.append(buffer)
                    buffer = []
                }
            } else if byte == Self.esc {
                escaping = true
            } else {
                buffer.append(byte)
            }
        }
        return packets
    }

    public static func encode(_ packet: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [end]
        for byte in packet {
            switch byte {
            case end: out += [esc, escEnd]
            case esc: out += [esc, escEsc]
            default: out.append(byte)
            }
        }
        out.append(end)
        return out
    }
}
