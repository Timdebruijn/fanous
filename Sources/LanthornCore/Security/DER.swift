// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// Minimal DER encoder: exactly the subset a self-signed TLS certificate needs.
public enum DER {
    public static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func length(_ count: Int) -> [UInt8] {
        precondition(count >= 0)
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    public static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    public static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
    public static func boolean(_ value: Bool) -> [UInt8] { tlv(0x01, [value ? 0xFF : 0x00]) }
    public static func octetString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }
    public static func utf8String(_ string: String) -> [UInt8] { tlv(0x0C, Array(string.utf8)) }
    public static func explicit(_ tagNumber: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | tagNumber, content) }
    public static func implicitPrimitive(_ tagNumber: UInt8, _ content: [UInt8]) -> [UInt8] {
        tlv(0x80 | tagNumber, content)
    }

    public static func bitString(_ bytes: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] {
        tlv(0x03, [unusedBits] + bytes)
    }

    /// Non-negative INTEGER from a big-endian magnitude.
    public static func integer(unsignedBytes: [UInt8]) -> [UInt8] {
        var magnitude = Array(unsignedBytes.drop(while: { $0 == 0 }))
        if magnitude.isEmpty { magnitude = [0] }
        if magnitude[0] & 0x80 != 0 { magnitude.insert(0, at: 0) }
        return tlv(0x02, magnitude)
    }

    public static func integer(_ value: Int) -> [UInt8] {
        precondition(value >= 0, "only non-negative integers are needed")
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        return integer(unsignedBytes: bytes)
    }

    public static func objectIdentifier(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").map { UInt64($0)! }
        precondition(arcs.count >= 2)
        var body: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var encoded: [UInt8] = [UInt8(arc & 0x7F)]
            var rest = arc >> 7
            while rest > 0 {
                encoded.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
                rest >>= 7
            }
            body += encoded
        }
        return tlv(0x06, body)
    }

    /// UTCTime before 2050, GeneralizedTime from 2050 on (RFC 5280 §4.1.2.5).
    public static func time(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year!
        let body = String(
            format: "%02d%02d%02d%02d%02dZ", c.month!, c.day!, c.hour!, c.minute!, c.second!)
        if year < 2050 {
            return tlv(0x17, Array((String(format: "%02d", year % 100) + body).utf8))
        }
        return tlv(0x18, Array((String(format: "%04d", year) + body).utf8))
    }
}
