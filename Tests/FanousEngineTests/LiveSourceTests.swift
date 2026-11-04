// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Metal
import Testing

@testable import FanousEngine

/// A live source's planes and pixel kind (DESIGN.md §8.2.1): 8-bit camera formats and their 16-bit movie counterparts
/// read through the layer shader's video-range matrix, rendered by the real compositor and read back (`GeneratorTests.render`).
/// `FANOUS_LIVE_READBACK=1` prints the pixels read.
struct LiveSourceTests {
    final class FakeLive: LiveTextureSource, @unchecked Sendable {
        let latestFrame: LiveFrame?
        init(_ frame: LiveFrame) { latestFrame = frame }
        func stop() {}
    }

    /// Runs of four pixels (two chroma samples, so a run's centre is a chroma texel boundary between equal values):
    /// video-range white, black, Rec.709 red, 50 % grey, then white/black alternating (Y0 ≠ Y1 in one pair).
    static let runs: [(y0: UInt8, y1: UInt8, cb: UInt8, cr: UInt8)] = [
        (235, 235, 128, 128), (16, 16, 128, 128), (63, 63, 102, 240), (126, 126, 128, 128), (235, 16, 128, 128),
    ]
    static let width = runs.count * 4, height = 2

    /// Canvas x of a source pixel's centre (stretched 20 → 960: 48 canvas pixels each).
    static func x(pixel: Int) -> Int { pixel * GeneratorTests.width / width + GeneratorTests.width / width / 2 }
    /// Canvas x of run `i`'s centre: the boundary between its second and third pixel.
    static func x(run i: Int) -> Int { (i * 4 + 2) * GeneratorTests.width / width }

    /// `deep` widens each 8-bit code to the 16-bit code with the same video-range meaning (code × 256, little-endian)
    /// in the 16-bit sibling format (`rgba16Unorm`, `r16Unorm`, `rg16Unorm`).
    static func texture(_ device: MTLDevice, _ format: MTLPixelFormat, _ width: Int, _ height: Int, _ bytes: [UInt8], deep: Bool = false) throws -> MTLTexture {
        let (format, bytes) = deep ? ([.rgba8Unorm: MTLPixelFormat.rgba16Unorm, .r8Unorm: .r16Unorm, .rg8Unorm: .rg16Unorm][format]!, bytes.flatMap { [0, $0] }) : (format, bytes)
        let texture = try MovieSource.makeTexture(device, format, width, height)
        let rowBytes = bytes.count / height
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: rowBytes) }
        return texture
    }

    /// `2vuy`: Cb Y0 Cr Y1 per pixel pair, an `rgba8Unorm` texture at half width; `deep` makes it `v216` (`rgba16Unorm`).
    static func packed(_ device: MTLDevice, deep: Bool = false) throws -> FakeLive {
        let row = runs.flatMap { r in [r.cb, r.y0, r.cr, r.y1, r.cb, r.y0, r.cr, r.y1] }
        return FakeLive(LiveFrame(texture0: try texture(device, .rgba8Unorm, width / 2, height, row + row, deep: deep), kind: .v216))
    }

    /// `420v`: Y as `r8Unorm`, CbCr as `rg8Unorm` at half width and half height; `deep` makes it a 16-bit bi-planar
    /// movie frame (`sv22`: `r16Unorm` + `rg16Unorm`).
    static func planar(_ device: MTLDevice, deep: Bool = false) throws -> FakeLive {
        let y = runs.flatMap { r in [r.y0, r.y1, r.y0, r.y1] }
        let cbcr = runs.flatMap { r in [r.cb, r.cr, r.cb, r.cr] }
        return FakeLive(
            LiveFrame(
                texture0: try texture(device, .r8Unorm, width, height, y + y, deep: deep),
                texture1: try texture(device, .rg8Unorm, width / 2, height / 2, cbcr, deep: deep),
                kind: .planarYCbCr))
    }

    static func render(_ live: any LiveTextureSource, fitMode: FitMode = .stretch, context: MetalContext) throws -> [UInt8] {
        try GeneratorTests.render(LayerPlayback(key: MediaKey(folder: 0, file: 1), live: live), fitMode: fitMode, context: context).1
    }

    static func expect(_ got: (r: Int, g: Int, b: Int), _ want: (Int, Int, Int), _ what: String, tolerance: Int = 2) {
        #expect(
            abs(got.r - want.0) <= tolerance && abs(got.g - want.1) <= tolerance && abs(got.b - want.2) <= tolerance,
            "\(what): got \(got.r),\(got.g),\(got.b), want \(want.0),\(want.1),\(want.2)")
    }

    /// Both 8-bit camera layouts and their 16-bit movie siblings read the same colours: black (16/255, 4096/65535) is
    /// exactly the shader's black level for that depth, so it lands on 0, white on 255 and neutral grey on equal
    /// channels, not one code off (B119: the 16-bit frames read with 8-bit ratios gave 254 and a green cast).
    @Test(arguments: ["2vuy", "420v", "v216", "sv22"])
    func videoRangeFormatsReadExactLevels(format: String) throws {
        let context = try MetalContext()
        let deep = format == "v216" || format == "sv22"
        let live = format == "2vuy" || format == "v216" ? try Self.packed(context.device, deep: deep) : try Self.planar(context.device, deep: deep)
        let image = try Self.render(live, context: context)
        let y = GeneratorTests.height / 2
        func at(run i: Int) -> (r: Int, g: Int, b: Int) { GeneratorTests.pixel(image, Self.x(run: i), y) }
        Self.expect(at(run: 0), (255, 255, 255), "\(format) white", tolerance: 0)
        Self.expect(at(run: 1), (0, 0, 0), "\(format) black", tolerance: 0)
        Self.expect(at(run: 2), (255, 0, 0), "\(format) red")
        // grey sits 0.08 code above 128 before the output dither, so ±1; the neutral-chroma check is what catches B119
        Self.expect(at(run: 3), (128, 128, 128), "\(format) grey", tolerance: 1)
        #expect(at(run: 3).r == at(run: 3).g && at(run: 3).g == at(run: 3).b, "\(format) grey is neutral: \(at(run: 3))")
        // the pair's two lumas land on their own pixels. 2vuy picks them with the nearest sampler: exact. The 420v Y plane
        // is sampled linearly, and the canvas pixel centre is 1/96 source pixel right of the source pixel's centre:
        // Y0 = 235 − 219/96 → (232.72 − 16) × 255/219 = 252.3, Y1 = 16 + 219/96 → 2.65; asserted ±1 around the derived values
        if format == "2vuy" || format == "v216" {
            Self.expect(GeneratorTests.pixel(image, Self.x(pixel: 16), y), (255, 255, 255), "\(format) Y0", tolerance: 0)
            Self.expect(GeneratorTests.pixel(image, Self.x(pixel: 17), y), (0, 0, 0), "\(format) Y1", tolerance: 0)
        } else {
            Self.expect(GeneratorTests.pixel(image, Self.x(pixel: 16), y), (252, 252, 252), "\(format) Y0", tolerance: 1)
            Self.expect(GeneratorTests.pixel(image, Self.x(pixel: 17), y), (3, 3, 3), "\(format) Y1", tolerance: 1)
        }
        if ProcessInfo.processInfo.environment["FANOUS_LIVE_READBACK"] != nil {
            print("\(format):", (0..<4).map { at(run: $0) }, GeneratorTests.pixel(image, Self.x(pixel: 16), y), GeneratorTests.pixel(image, Self.x(pixel: 17), y))
        }
    }

    /// The tick's one read of a live source (`LayerPlayback.frame`) allocates nothing: `LiveFrame` is returned by value,
    /// from a stored property (the fake) and from a computed one (a generator).
    @Test(.mallocCounter)
    func mallocCounterLiveFrameReadAllocatesNothing() throws {
        try requireMallocCounter()
        let context = try MetalContext()
        let generator = try #require(GeneratorSource(context: context, file: 100, width: 64, height: 64))
        for live: any LiveTextureSource in [try Self.planar(context.device), generator] {
            let playback = LayerPlayback(key: MediaKey(folder: 0, file: 1), live: live)
            var mallocs = 0
            for _ in 0..<3 {
                mallocs = MallocCounter.count {
                    for _ in 0..<100 { _ = playback.frame(at: 0, direction: 1) }
                }
            }
            #if !DEBUG
                #expect(mallocs == 0, "100 live frame reads of \(type(of: live)): \(mallocs) allocations on the calling thread")
            #endif
            print("live frame read × 100 (\(type(of: live))): \(mallocs) allocations")
        }
    }

    /// An RGBA frame of one texture (what Syphon and the generators hand over) comes through untouched.
    @Test func oneTextureFrameIsStraightRGBA() throws {
        let context = try MetalContext()
        let colours: [[UInt8]] = [[255, 255, 255, 255], [0, 0, 0, 255], [255, 0, 0, 255], [128, 128, 128, 255], [10, 200, 90, 255]]
        let row = colours.flatMap { c in Array(repeating: c, count: 4).flatMap { $0 } }
        let live = FakeLive(LiveFrame(texture0: try Self.texture(context.device, .rgba8Unorm, Self.width, Self.height, row + row)))
        let playback = LayerPlayback(key: MediaKey(folder: 0, file: 1), live: live)
        let frame = try #require(playback.frame(at: 0, direction: 1))
        #expect(frame.kind == .rgba && frame.texture1 == nil && !frame.bottomUp)
        let image = try Self.render(live, context: context)
        for (i, c) in colours.enumerated() {
            Self.expect(
                GeneratorTests.pixel(image, Self.x(run: i), GeneratorTests.height / 2), (Int(c[0]), Int(c[1]), Int(c[2])), "rgba run \(i)", tolerance: 0)
        }
    }
}
