// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// CPU block compressors for the HAP family: BC1 (HAP), BC3 (HAP Alpha),
/// scaled YCoCg-DXT5 (HAP Q) and BC4 (HAP Alpha-only). Range fit per block.
/// ponytail: quality is "good enough for test media and first ingest"; a GPU
/// compute encoder with better endpoint search is the Phase 4 upgrade path.
enum DXTCompressor {
    enum Format {
        case bc1, bc3, ycocgDXT5, bc4

        var bytesPerBlock: Int { self == .bc1 || self == .bc4 ? 8 : 16 }
    }

    static func compressedSize(width: Int, height: Int, format: Format) -> Int {
        (width / 4) * (height / 4) * format.bytesPerBlock
    }

    /// `bgra` is 8-bit BGRA, `width`/`height` multiples of 4. `output` must hold `compressedSize` bytes.
    static func compress(
        bgra: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, format: Format,
        output: UnsafeMutablePointer<UInt8>
    ) {
        var r = [UInt8](repeating: 0, count: 16), g = r, b = r, a = r
        var out = output
        for by in stride(from: 0, to: height, by: 4) {
            for bx in stride(from: 0, to: width, by: 4) {
                for py in 0..<4 {
                    let row = bgra + (by + py) * bytesPerRow + bx * 4
                    for px in 0..<4 {
                        let i = py * 4 + px
                        b[i] = row[px * 4]
                        g[i] = row[px * 4 + 1]
                        r[i] = row[px * 4 + 2]
                        a[i] = row[px * 4 + 3]
                    }
                }
                switch format {
                case .bc1:
                    colourBlock(r: r, g: g, b: b, into: out)
                case .bc3:
                    alphaBlock(a, into: out)
                    colourBlock(r: r, g: g, b: b, into: out + 8)
                case .bc4:
                    alphaBlock(a, into: out)
                case .ycocgDXT5:
                    ycocgBlock(r: r, g: g, b: b, into: out)
                }
                out += format.bytesPerBlock
            }
        }
    }

    // MARK: - Blocks

    static func pack565(_ r: Int, _ g: Int, _ b: Int) -> UInt16 {
        UInt16(r >> 3) << 11 | UInt16(g >> 2) << 5 | UInt16(b >> 3)
    }

    static func unpack565(_ c: UInt16) -> (Int, Int, Int) {
        let r = Int(c >> 11) & 31, g = Int(c >> 5) & 63, b = Int(c) & 31
        return (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2)
    }

    /// BC1 colour block (8 bytes): endpoints are the bounding-box corners (range fit).
    static func colourBlock(r: [UInt8], g: [UInt8], b: [UInt8], into out: UnsafeMutablePointer<UInt8>) {
        let hi = pack565(Int(r.max()!), Int(g.max()!), Int(b.max()!))
        let lo = pack565(Int(r.min()!), Int(g.min()!), Int(b.min()!))
        writeColourBlock(c0: max(hi, lo), c1: min(hi, lo), r: r, g: g, b: b, into: out)
    }

    static func writeColourBlock(c0: UInt16, c1: UInt16, r: [UInt8], g: [UInt8], b: [UInt8], into out: UnsafeMutablePointer<UInt8>) {
        out[0] = UInt8(c0 & 0xFF)
        out[1] = UInt8(c0 >> 8)
        out[2] = UInt8(c1 & 0xFF)
        out[3] = UInt8(c1 >> 8)
        var indices: UInt32 = 0
        if c0 != c1 {
            let (r0, g0, b0) = unpack565(c0), (r1, g1, b1) = unpack565(c1)
            let palette = [
                (r0, g0, b0), (r1, g1, b1), ((2 * r0 + r1) / 3, (2 * g0 + g1) / 3, (2 * b0 + b1) / 3),
                ((r0 + 2 * r1) / 3, (g0 + 2 * g1) / 3, (b0 + 2 * b1) / 3),
            ]
            for i in 0..<16 {
                var best = 0, bestDistance = Int.max
                for (index, p) in palette.enumerated() {
                    let d = (Int(r[i]) - p.0) * (Int(r[i]) - p.0) + (Int(g[i]) - p.1) * (Int(g[i]) - p.1) + (Int(b[i]) - p.2) * (Int(b[i]) - p.2)
                    if d < bestDistance {
                        bestDistance = d
                        best = index
                    }
                }
                indices |= UInt32(best) << (2 * i)
            }
        }
        out[4] = UInt8(indices & 0xFF)
        out[5] = UInt8(indices >> 8 & 0xFF)
        out[6] = UInt8(indices >> 16 & 0xFF)
        out[7] = UInt8(indices >> 24 & 0xFF)
    }

    /// BC3/BC4 alpha block (8 bytes): 8-level mode, a0 > a1.
    static func alphaBlock(_ a: [UInt8], into out: UnsafeMutablePointer<UInt8>) {
        let a0 = Int(a.max()!), a1 = Int(a.min()!)
        out[0] = UInt8(a0)
        out[1] = UInt8(a1)
        var bits: UInt64 = 0
        if a0 != a1 {
            var palette = [a0, a1]
            for i in 1...6 { palette.append(((7 - i) * a0 + i * a1) / 7) }
            for i in 0..<16 {
                var best = 0, bestDistance = Int.max
                for (index, p) in palette.enumerated() {
                    let d = abs(Int(a[i]) - p)
                    if d < bestDistance {
                        bestDistance = d
                        best = index
                    }
                }
                bits |= UInt64(best) << (3 * i)
            }
        }
        for i in 0..<6 { out[2 + i] = UInt8(bits >> (8 * i) & 0xFF) }
    }

    /// HAP Q: Y in the alpha block, scaled Co/Cg in red/green, scale in blue (van Waveren & Castaño).
    static func ycocgBlock(r: [UInt8], g: [UInt8], b: [UInt8], into out: UnsafeMutablePointer<UInt8>) {
        var y = [UInt8](repeating: 0, count: 16), co = [Int](repeating: 0, count: 16), cg = co
        var maxDeviation = 0
        for i in 0..<16 {
            let rr = Int(r[i]), gg = Int(g[i]), bb = Int(b[i])
            y[i] = UInt8((rr + 2 * gg + bb) / 4)
            co[i] = (rr - bb) / 2
            cg[i] = (-rr + 2 * gg - bb) / 4
            maxDeviation = max(maxDeviation, abs(co[i]), abs(cg[i]))
        }
        let scale = maxDeviation < 32 ? 4 : maxDeviation < 64 ? 2 : 1
        let blueBits = scale == 4 ? 3 : scale == 2 ? 1 : 0  // 5-bit blue endpoint: decoder reads (b·255/8)+1 ≈ scale
        var sco = [UInt8](repeating: 0, count: 16), scg = sco
        for i in 0..<16 {
            sco[i] = UInt8(min(255, max(0, 128 + co[i] * scale)))
            scg[i] = UInt8(min(255, max(0, 128 + cg[i] * scale)))
        }
        alphaBlock(y, into: out)
        let c0 = UInt16(Int(sco.max()!) >> 3) << 11 | UInt16(Int(scg.max()!) >> 2) << 5 | UInt16(blueBits)
        let c1 = UInt16(Int(sco.min()!) >> 3) << 11 | UInt16(Int(scg.min()!) >> 2) << 5 | UInt16(blueBits)
        let blue = [UInt8](repeating: UInt8(blueBits << 3), count: 16)
        writeColourBlock(c0: max(c0, c1), c1: min(c0, c1), r: sco, g: scg, b: blue, into: out + 8)
    }
}
