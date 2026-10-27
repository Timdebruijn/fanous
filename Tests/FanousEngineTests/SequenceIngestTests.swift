// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers

@testable import FanousEngine

struct SequenceIngestTests {
    /// Ten PNG frames with alpha → ProRes 4444 → the engine opens it with ten frames and decodes with alpha.
    @Test func sequenceBecomesPlayableMovie() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "fanous-seq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let w = 320, h = 176
        for i in 0..<10 {
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let p = (y * w + x) * 4
                    pixels[p] = UInt8(x * 255 / (w - 1))
                    pixels[p + 1] = UInt8(i * 25)
                    pixels[p + 2] = UInt8(y * 255 / (h - 1))
                    pixels[p + 3] = x < w / 2 ? 255 : 0
                }
            }
            let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            let image = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: CGDataProvider(data: data as CFData)!, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)!
            let url = directory.appending(path: String(format: "frame_%03d.png", i))
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        let frames = try SequenceIngest.frames(in: directory)
        #expect(frames.count == 10)
        #expect(frames.first?.lastPathComponent == "frame_000.png")
        let output = directory.appending(path: "out.mov")
        let written = try await IngestQueueTests.offPool { try SequenceIngest.convert(frames: frames, to: output, fps: 25, codec: .proRes4444) }
        #expect(written == 10)

        guard let device = MTLCreateSystemDefaultDevice() else { return }
        // the same PNGs are stills for the engine: straight alpha, sRGB, 8-bit
        let still = try StillSource.load(url: frames[3], device: device)
        let texture = try #require(still.texture0)
        #expect(still.kind == .rgba && texture.width == w && texture.height == h)
        var row = [UInt8](repeating: 0, count: w * 4)
        texture.getBytes(&row, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 10, w, 1), mipmapLevel: 0)
        #expect(row[3] == 255 && row[(w - 1) * 4 + 3] == 0)  // left opaque, right transparent
        #expect(abs(Int(row[1]) - 75) <= 1 && abs(Int(row[2]) - Int(10 * 255 / (h - 1))) <= 1)  // frame 3 → green 75; blue from the row

        let source = try await MovieSource.open(url: output, device: device, poolSize: 2)
        #expect(source.info.frameCount == 10)
        #expect(source.info.width == w && source.info.height == h)
        let slot = DecodedFrame(poolIndex: 0)
        try source.decode(frame: 5, into: slot)
        #expect(slot.kind == .y416 || slot.kind == .planarYCbCrA)  // an alpha-carrying layout
    }
}
