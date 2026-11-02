// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

extension Array where Element == UInt8 {
    /// Appends `value` least significant byte first (CITP, the sync packet); no allocation within the capacity.
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        for i in 0..<T.bitWidth / 8 { append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
    }

    /// `text` as UTF-8 in exactly `length` bytes, zero-padded and cut so a zero always ends it (Art-Net, sACN).
    static func fixed(_ text: String, _ length: Int) -> [UInt8] {
        let bytes = Array(text.utf8.prefix(length - 1))
        return bytes + [UInt8](repeating: 0, count: length - bytes.count)
    }
}

extension FixedWidthInteger {
    /// Most significant byte first: network order (sACN, OSC).
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: bigEndian) { Array($0) } }
}
