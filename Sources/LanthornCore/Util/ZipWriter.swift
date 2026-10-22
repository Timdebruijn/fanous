// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// Minimal ZIP writer (stored entries, no compression): enough for a .gdtf file.
public enum ZipWriter {
    public struct Entry: Sendable {
        public let name: String
        public let data: [UInt8]
        public init(_ name: String, _ data: [UInt8]) {
            self.name = name
            self.data = data
        }
    }

    public static func archive(_ entries: [Entry], date: Date = Date()) -> [UInt8] {
        var out: [UInt8] = []
        var central: [UInt8] = []
        let (dosTime, dosDate) = dosDateTime(date)
        for entry in entries {
            let name = Array(entry.name.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(out.count)
            let common = le16(20) + le16(0x0800) + le16(0) + le16(dosTime) + le16(dosDate) + le32(crc)
                + le32(UInt32(entry.data.count)) + le32(UInt32(entry.data.count)) + le16(UInt16(name.count))
            out += le32(0x0403_4B50) + common + le16(0) + name + entry.data
            central += le32(0x0201_4B50) + le16(20) + common + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name
        }
        let centralOffset = UInt32(out.count)
        out += central
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
            + le32(UInt32(central.count)) + le32(centralOffset) + le16(0)
        return out
    }

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }

    static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16(c.hour! << 11 | c.minute! << 5 | c.second! / 2)
        let day = UInt16(max(0, c.year! - 1980) << 9 | c.month! << 5 | c.day!)
        return (time, day)
    }

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
