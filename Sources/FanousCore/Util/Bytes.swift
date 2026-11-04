// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

extension Array where Element == UInt8 {
    /// Appends `value` least significant byte first (CITP, the sync packet); no allocation within the capacity.
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        for i in 0..<T.bitWidth / 8 { append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
    }

    /// The `T` at `offset`, most significant byte first (sACN, OSC, WebSocket). The caller checks the length;
    /// reading past the end traps, as a subscript does.
    func bigEndian<T: FixedWidthInteger>(at offset: Int, as _: T.Type = T.self) -> T { T(bigEndian: load(at: offset)) }

    /// The `T` at `offset`, least significant byte first (the sync packet); bounds as `bigEndian(at:)`.
    func littleEndian<T: FixedWidthInteger>(at offset: Int, as _: T.Type = T.self) -> T { T(littleEndian: load(at: offset)) }

    /// The `T` at `offset` as it lies in memory; traps when it does not fit.
    func load<T>(at offset: Int, as _: T.Type = T.self) -> T {
        precondition(offset >= 0 && offset + MemoryLayout<T>.size <= count, "read past the end")
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
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
