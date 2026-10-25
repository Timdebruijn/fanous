// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CHap
import Foundation

/// Encodes BGRA frames into HAP frames (DXT via `DXTCompressor`, Snappy via hap.c).
public struct HAPEncoder {
    public enum Variant: String, CaseIterable, Sendable {
        case hap, hapAlpha, hapQ, hapAlphaOnly

        /// QuickTime codec type.
        public var fourCC: FourCharCode {
            switch self {
            case .hap: makeFourCC("Hap1")
            case .hapAlpha: makeFourCC("Hap5")
            case .hapQ: makeFourCC("HapY")
            case .hapAlphaOnly: makeFourCC("HapA")
            }
        }

        var dxt: DXTCompressor.Format {
            switch self {
            case .hap: .bc1
            case .hapAlpha: .bc3
            case .hapQ: .ycocgDXT5
            case .hapAlphaOnly: .bc4
            }
        }

        var hapFormat: UInt32 {
            switch self {
            case .hap: UInt32(HapTextureFormat_RGB_DXT1.rawValue)
            case .hapAlpha: UInt32(HapTextureFormat_RGBA_DXT5.rawValue)
            case .hapQ: UInt32(HapTextureFormat_YCoCg_DXT5.rawValue)
            case .hapAlphaOnly: UInt32(HapTextureFormat_A_RGTC1.rawValue)
            }
        }
    }

    public let variant: Variant
    public let width: Int
    public let height: Int
    public let chunkCount: UInt32
    private var dxt: [UInt8]
    private var encoded: [UInt8]

    public init(variant: Variant, width: Int, height: Int, chunkCount: UInt32 = 4) {
        precondition(width % 4 == 0 && height % 4 == 0, "HAP needs dimensions that are multiples of 4")
        self.variant = variant
        self.width = width
        self.height = height
        self.chunkCount = chunkCount
        let dxtBytes = DXTCompressor.compressedSize(width: width, height: height, format: variant.dxt)
        dxt = [UInt8](repeating: 0, count: dxtBytes)
        var lengths: [UInt] = [UInt(dxtBytes)]
        var formats: [UInt32] = [variant.hapFormat]
        var chunks: [UInt32] = [chunkCount]
        encoded = [UInt8](repeating: 0, count: Int(HapMaxEncodedLength(1, &lengths, &formats, &chunks)))
    }

    /// Returns the HAP frame bytes (valid until the next call).
    public mutating func encode(bgra: UnsafePointer<UInt8>, bytesPerRow: Int) throws -> ArraySlice<UInt8> {
        let format = variant
        dxt.withUnsafeMutableBufferPointer { out in
            DXTCompressor.compress(bgra: bgra, width: width, height: height, bytesPerRow: bytesPerRow, format: format.dxt, output: out.baseAddress!)
        }
        var used: UInt = 0
        let result: UInt32 = dxt.withUnsafeBufferPointer { input in
            encoded.withUnsafeMutableBufferPointer { out in
                var inputs: [UnsafeRawPointer?] = [UnsafeRawPointer(input.baseAddress!)]
                var lengths: [UInt] = [UInt(input.count)]
                var formats: [UInt32] = [format.hapFormat]
                var compressors: [UInt32] = [UInt32(HapCompressorSnappy.rawValue)]
                var chunks: [UInt32] = [chunkCount]
                return HapEncode(1, &inputs, &lengths, &formats, &compressors, &chunks, out.baseAddress!, UInt(out.count), &used)
            }
        }
        guard result == HapResult_No_Error.rawValue else { throw HAPError.encode(result) }
        return encoded[0..<Int(used)]
    }
}

public enum HAPError: Error, CustomStringConvertible {
    case encode(UInt32)
    case decode(UInt32)
    case unsupportedTexture(UInt32)

    public var description: String {
        switch self {
        case .encode(let code): "HapEncode failed (\(code))"
        case .decode(let code): "HapDecode failed (\(code))"
        case .unsupportedTexture(let format): "unsupported HAP texture format 0x\(String(format, radix: 16))"
        }
    }
}

public func makeFourCC(_ text: String) -> FourCharCode {
    text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}

public func fourCCString(_ code: FourCharCode) -> String {
    String(bytes: [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)], encoding: .macOSRoman) ?? "????"
}
