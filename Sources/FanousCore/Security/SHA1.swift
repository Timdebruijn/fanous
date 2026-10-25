// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// SHA-1 (RFC 3174). Only for the WebSocket handshake (RFC 6455 §4.2.2), where it is
/// a protocol constant, not a security primitive. FanousCore is Foundation-only, so no CryptoKit.
public enum SHA1 {
    public static func hash(_ bytes: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]

        // Pad: 0x80, zeros up to 56 mod 64, then the bit length as a big-endian UInt64.
        var message = bytes
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        let bitLength = UInt64(bytes.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var w = [UInt32](repeating: 0, count: 80)
        for block in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = block + i * 4
                let b0 = UInt32(message[j]) << 24
                let b1 = UInt32(message[j + 1]) << 16
                let b2 = UInt32(message[j + 2]) << 8
                let b3 = UInt32(message[j + 3])
                w[i] = b0 | b1 | b2 | b3
            }
            for i in 16..<80 {
                w[i] = rotateLeft(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }

            var a = h[0]
            var b = h[1]
            var c = h[2]
            var d = h[3]
            var e = h[4]
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20:
                    f = (b & c) | (~b & d)
                    k = 0x5A82_7999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9_EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1B_BCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62_C1D6
                }
                let temp = rotateLeft(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = rotateLeft(b, 30)
                b = a
                a = temp
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
        }

        return h.flatMap { word in
            (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - 8 * $0)) }
        }
    }

    private static func rotateLeft(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }
}
