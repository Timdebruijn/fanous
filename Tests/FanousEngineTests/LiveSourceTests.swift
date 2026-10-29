// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore
import Foundation
import Metal
import Testing

@testable import FanousEngine

/// A live source's planes and pixel kind (DESIGN.md §8.2.1): 8-bit camera formats read through the layer shader's
/// video-range matrix, rendered by the real compositor and read back (`GeneratorTests.render`).
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

    static func texture(_ device: MTLDevice, _ format: MTLPixelFormat, _ width: Int, _ height: Int, _ bytes: [UInt8]) throws -> MTLTexture {
        let texture = try MovieSource.makeTexture(device, format, width, height)
        let rowBytes = bytes.count / height
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: rowBytes) }
        return texture
    }

    /// `2vuy`: Cb Y0 Cr Y1 per pixel pair, an `rgba8Unorm` texture at half width.
    static func packed(_ device: MTLDevice) throws -> FakeLive {
        let row = runs.flatMap { r in [r.cb, r.y0, r.cr, r.y1, r.cb, r.y0, r.cr, r.y1] }
        return FakeLive(LiveFrame(texture0: try texture(device, .rgba8Unorm, width / 2, height, row + row), kind: .v216))
    }

    /// `420v`: Y as `r8Unorm`, CbCr as `rg8Unorm` at half width and half height.
    static func planar(_ device: MTLDevice) throws -> FakeLive {
        let y = runs.flatMap { r in [r.y0, r.y1, r.y0, r.y1] }
        let cbcr = runs.flatMap { r in [r.cb, r.cr, r.cb, r.cr] }
        return FakeLive(
            LiveFrame(
                texture0: try texture(device, .r8Unorm, width, height, y + y), texture1: try texture(device, .rg8Unorm, width / 2, height / 2, cbcr),
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

    /// Both 8-bit camera layouts read the same colours through the 16-bit-era matrix: 8-bit black (16/255) is exactly
    /// the shader's black level, so it lands on 0, not one code above.
    @Test(arguments: ["2vuy", "420v"])
    func eightBitCameraFormatsReadVideoRange(format: String) throws {
        let context = try MetalContext()
        let live = format == "2vuy" ? try Self.packed(context.device) : try Self.planar(context.device)
        let image = try Self.render(live, context: context)
        let y = GeneratorTests.height / 2
        func at(run i: Int) -> (r: Int, g: Int, b: Int) { GeneratorTests.pixel(image, Self.x(run: i), y) }
        Self.expect(at(run: 0), (255, 255, 255), "\(format) white")
        Self.expect(at(run: 1), (0, 0, 0), "\(format) black", tolerance: 0)
        Self.expect(at(run: 2), (255, 0, 0), "\(format) red")
        Self.expect(at(run: 3), (128, 128, 128), "\(format) grey")
        // the pair's two lumas land on their own pixels. 2vuy picks them with the nearest sampler: exact. The 420v Y plane
        // is sampled linearly, and the canvas pixel centre is 1/96 source pixel right of the source pixel's centre:
        // Y0 = 235 − 219/96 → (232.72 − 16) × 255/219 = 252.3, Y1 = 16 + 219/96 → 2.65; asserted ±1 around the derived values
        if format == "2vuy" {
            Self.expect(GeneratorTests.pixel(image, Self.x(pixel: 16), y), (255, 255, 255), "2vuy Y0", tolerance: 0)
            Self.expect(GeneratorTests.pixel(image, Self.x(pixel: 17), y), (0, 0, 0), "2vuy Y1", tolerance: 0)
        } else {
            Self.expect(GeneratorTests.pixel(image, Self.x(pixel: 16), y), (252, 252, 252), "420v Y0", tolerance: 1)
            Self.expect(GeneratorTests.pixel(image, Self.x(pixel: 17), y), (3, 3, 3), "420v Y1", tolerance: 1)
        }
        if ProcessInfo.processInfo.environment["FANOUS_LIVE_READBACK"] != nil {
            print("\(format):", (0..<4).map { at(run: $0) }, GeneratorTests.pixel(image, Self.x(pixel: 16), y), GeneratorTests.pixel(image, Self.x(pixel: 17), y))
        }
    }

    /// A packed 4:2:2 frame is twice as wide as its texture: 64×32 pixels (a 32×32 texture), red left and white right,
    /// fits the 16:9 canvas as 2:1 (960×480, black bars of 30 rows) with the split at the canvas's middle column.
    @Test func packedFrameKeepsItsFullWidthAspect() throws {
        let context = try MetalContext()
        let red: [UInt8] = [102, 63, 240, 63], white: [UInt8] = [128, 235, 128, 235]
        let row = Array(repeating: red, count: 16).flatMap { $0 } + Array(repeating: white, count: 16).flatMap { $0 }
        let bytes = Array(repeating: row, count: 32).flatMap { $0 }
        let live = FakeLive(LiveFrame(texture0: try Self.texture(context.device, .rgba8Unorm, 32, 32, bytes), kind: .v216))
        let image = try Self.render(live, fitMode: .fit, context: context)
        let middle = GeneratorTests.height / 2
        Self.expect(GeneratorTests.pixel(image, 20, middle), (255, 0, 0), "left edge")
        Self.expect(GeneratorTests.pixel(image, 470, middle), (255, 0, 0), "left of the split")
        Self.expect(GeneratorTests.pixel(image, 490, middle), (255, 255, 255), "right of the split")
        Self.expect(GeneratorTests.pixel(image, 940, middle), (255, 255, 255), "right edge")
        Self.expect(GeneratorTests.pixel(image, 240, 35), (255, 0, 0), "top row of the picture")
        Self.expect(GeneratorTests.pixel(image, 240, 20), (0, 0, 0), "bar above", tolerance: 0)
        Self.expect(GeneratorTests.pixel(image, 720, 520), (0, 0, 0), "bar below", tolerance: 0)
    }

    /// The tick's one read of a live source (`LayerPlayback.frame`) allocates nothing: `LiveFrame` is returned by value,
    /// from a stored property (the fake) and from a computed one (a generator).
    @Test(.enabled(if: MallocCounter.availableOrRequired, "malloc_logger not exported by libsystem_malloc on this macOS"))
    func mallocCounterLiveFrameReadAllocatesNothing() throws {
        try #require(MallocCounter.available, "malloc_logger not exported by libsystem_malloc on this macOS")
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
