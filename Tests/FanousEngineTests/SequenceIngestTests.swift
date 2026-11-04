// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers

@testable import FanousEngine

@Suite(.cleansTempFiles)
struct SequenceIngestTests {
    /// A semi-transparent sequence pixel keeps its colour: ProRes 4444 and the layer shader take straight alpha, so a PNG
    /// pixel (200, 100, 50) at alpha 128 must come back as that, not darkened by its own alpha (100, 50, 25 before, measured).
    @Test func semiTransparentPixelKeepsItsColour() async throws {
        let directory = try tempDir("fanous-seq")
        let (w, h) = (64, 32)
        let data = Data(Array([[UInt8]](repeating: [200, 100, 50, 128], count: w * h).joined()))
        let image = try #require(CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: CGDataProvider(data: data as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        for i in 0..<2 {
            let destination = try #require(CGImageDestinationCreateWithURL(
                directory.appending(path: "half_\(i).png") as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        let output = directory.appending(path: "half.mov")
        let frames = try SequenceIngest.frames(in: directory)
        _ = try await offPool { try SequenceIngest.convert(frames: frames, to: output, fps: 25, codec: .proRes4444) }
        let buffer = try await firstFrame(of: output)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let pixel = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: 16 * CVPixelBufferGetBytesPerRow(buffer) + 32 * 4).assumingMemoryBound(to: UInt8.self)
        let rgba = [Int(pixel[2]), Int(pixel[1]), Int(pixel[0]), Int(pixel[3])]
        #expect(zip(rgba, [200, 100, 50, 128]).allSatisfy { abs($0 - $1) <= 3 }, "read back \(rgba)")

        // the 8-bit path (HAP Alpha's input): the drawn BGRA pixel itself is straight
        var bgra: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &bgra)
        let drawn = try #require(bgra)
        try SequenceIngest.draw(image, from: frames[0], into: drawn, deep: false, straight: true, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        CVPixelBufferLockBaseAddress(drawn, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(drawn, .readOnly) }
        let eight = CVPixelBufferGetBaseAddress(drawn)!.advanced(by: 16 * CVPixelBufferGetBytesPerRow(drawn) + 32 * 4).assumingMemoryBound(to: UInt8.self)
        let straight = [Int(eight[2]), Int(eight[1]), Int(eight[0]), Int(eight[3])]
        #expect(zip(straight, [200, 100, 50, 128]).allSatisfy { abs($0 - $1) <= 2 }, "BGRA \(straight)")

        // an opaque codec keeps the premultiplied colour: the half-transparent pixel over black, not at full colour
        let opaque = directory.appending(path: "opaque.mov")
        _ = try await offPool { try SequenceIngest.convert(frames: frames, to: opaque, fps: 25, codec: .proRes422HQ) }
        let opaqueBuffer = try await firstFrame(of: opaque)
        CVPixelBufferLockBaseAddress(opaqueBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(opaqueBuffer, .readOnly) }
        let o = CVPixelBufferGetBaseAddress(opaqueBuffer)!.advanced(by: 16 * CVPixelBufferGetBytesPerRow(opaqueBuffer) + 32 * 4).assumingMemoryBound(to: UInt8.self)
        let overBlack = [Int(o[2]), Int(o[1]), Int(o[0])]
        #expect(zip(overBlack, [100, 50, 25]).allSatisfy { abs($0 - $1) <= 3 }, "ProRes 422 HQ \(overBlack)")
    }

    /// A 16-bit image sequence keeps more than 8 bits in ProRes: a 16-bit grey PNG ramp (1024 wide, full range) comes out
    /// of ProRes 422 HQ on the 10-bit video-range ramp `IngestQueueTests.rampError` expects.
    @Test func sixteenBitSequenceKeepsItsPrecisionInProRes() async throws {
        let directory = try tempDir("fanous-seq")
        let (w, h) = (1024, 16)
        let row = (0..<w).flatMap { x in [UInt16](repeating: UInt16(x * 65535 / (w - 1)), count: 3) }
        let data = (0..<h).flatMap { _ in row }.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = try #require(CGImage(
            width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        for i in 0..<3 {
            let destination = try #require(CGImageDestinationCreateWithURL(
                directory.appending(path: "ramp_\(i).png") as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        let output = directory.appending(path: "ramp.mov")
        let frames = try SequenceIngest.frames(in: directory)
        _ = try await offPool { try SequenceIngest.convert(frames: frames, to: output, fps: 25, codec: .proRes422HQ) }
        let error = try await IngestQueueTests.rampError(output)
        #expect(error.mean < 0.5 && error.max <= 2, "ProRes: \(error)")
    }

    /// Ten PNG frames with alpha → ProRes 4444 → the engine opens it with ten frames and decodes with alpha.
    @Test func sequenceBecomesPlayableMovie() async throws {
        let directory = try tempDir("fanous-seq")
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
        let written = try await offPool { try SequenceIngest.convert(frames: frames, to: output, fps: 25, codec: .proRes4444) }
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

        // the movie's own alpha and colour (the 16-bit RGBA path): left half opaque with the red ramp, right half transparent
        let buffer = try await firstFrame(of: output)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let pixel = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: 80 * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
        #expect(pixel[100 * 4 + 3] == 255 && abs(Int(pixel[100 * 4 + 2]) - 100 * 255 / (w - 1)) <= 3, "opaque: \((0..<4).map { pixel[100 * 4 + $0] })")
        #expect(pixel[250 * 4 + 3] == 0, "transparent: \((0..<4).map { pixel[250 * 4 + $0] })")
    }
}
